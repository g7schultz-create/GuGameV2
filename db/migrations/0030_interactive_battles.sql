-- 0030_interactive_battles
--
-- A fight becomes something you play instead of something you read.
--
-- 0007 built the battle engine's state for exactly this: `battles.status =
-- 'active'`, a `turn_number`, per-combatant `current_hp` and `current_qi`, a
-- `player_active_battle` claim enforcing one fight at a time, and an
-- append-only `battle_actions` log. 0017's `hunt()` then bypassed all of it,
-- resolving fifty turns in one call and marking the battle complete before
-- anybody could look at it. Every one of those columns has been sitting here
-- waiting for a turn to end.
--
-- WHAT A ROUND IS. The player acts, the creature answers, the turn number goes
-- up. The creature's next move is ROLLED AND SHOWN before the player chooses,
-- which is the whole reason there are four actions instead of one: guarding a
-- telegraphed heavy hit is a decision, guarding a coin flip is not.
--
-- QI FINALLY COSTS SOMETHING. `techniques.qi_cost_pct` has been on every
-- technique since 0004 with nothing reading it, and `battle_combatants.
-- current_qi` has defaulted to 0 since 0007 for want of a spender. A battle
-- pool, filled from the realm's `qi_capacity` at the start of each fight: it
-- is what stops the best move in your book being the only move you ever
-- throw, and it refills between fights because a qi REGENERATION system is a
-- different feature and inventing half of one here would be worse than
-- inventing none.
--
-- hunt() IS DROPPED. Two engines that resolve the same fight drift, and this
-- schema has already paid for that once: the auto-resolver went on calling a
-- function 0025 had deleted, and only the winning branch touched it, so the
-- command was broken in Discord while the tests passed.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- creature_moves
-- ---------------------------------------------------------------------------
-- What a creature is about to do, by name.
--
-- Per PATH rather than per species: 46 species times three moves is 138 rows
-- of authored content to maintain, while a Fire creature reaching for a Fire
-- move covers all of them and covers the 47th for free. `path_code` NULL is a
-- move any creature can make, because teeth do not have a Path.

CREATE TABLE creature_moves (
    move_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    code        TEXT NOT NULL UNIQUE,
    name        TEXT NOT NULL,

    -- NULL: available to anything with a body.
    path_code   TEXT REFERENCES paths (code) ON DELETE CASCADE,

    -- Applied through compute_creature_damage's external multiplier, so a
    -- telegraphed heavy hit lands on the same pipeline an ordinary one does.
    power_multiplier NUMERIC(6, 4) NOT NULL DEFAULT 1
                     CHECK (power_multiplier > 0),

    -- Shown to the player before they choose. This is the tactical
    -- information the whole round structure exists to deliver.
    telegraph   TEXT NOT NULL DEFAULT '',

    roll_weight NUMERIC(6, 2) NOT NULL DEFAULT 10 CHECK (roll_weight >= 0)
);

CREATE INDEX creature_moves_path_idx ON creature_moves (path_code);

COMMENT ON TABLE creature_moves IS
    'Named creature attacks, keyed by Path so a new species arrives already able to telegraph. NULL path = anything can do it.';

INSERT INTO creature_moves (code, name, path_code, power_multiplier, telegraph, roll_weight) VALUES
    -- Pathless. Every creature can bite, and a fight where the enemy only ever
    -- reaches for its element reads like a spell list, not an animal.
    ('bite',        'Undying Fang',      NULL, 1.00, 'A relentless bite that does not stop for being hurt.', 22),
    ('claw',        'Rending Claw',      NULL, 1.00, 'Three lines across whatever is nearest.', 20),
    ('charge',      'Headlong Charge',   NULL, 1.35, 'It stops circling and commits.', 10),
    ('thrash',      'Wild Thrash',       NULL, 0.80, 'Untargeted, and hard to be near.', 14),
    ('crush',       'Bearing Down',      NULL, 1.50, 'Its whole weight, slowly, deliberately.',  6),

    ('fire_breath',   'Cinder Breath',    'fire',      1.30, 'The air in front of it goes dry.', 10),
    ('water_surge',   'Undertow',         'water',     1.15, 'The ground underfoot stops being reliable.', 10),
    ('ice_shard',     'Rime Lance',       'ice',       1.25, 'Something is condensing to a point.', 10),
    ('wood_lash',     'Strangling Growth','wood',      1.10, 'Roots move where roots should not.', 10),
    ('lightning_arc', 'Levin Arc',        'lightning', 1.35, 'The hair on your arms lifts.', 10),
    ('earth_slam',    'Sundering Stamp',  'earth',     1.30, 'It plants itself. The ground answers.', 10),
    ('metal_spines',  'Filings Volley',   'metal',     1.20, 'Something bright is being spun up.', 10),
    ('sword_intent',  'Edge of Intent',   'sword',     1.40, 'It has found the line it means to cut along.', 10),
    ('strength_blow', 'Ox-Felling Blow',  'strength',  1.35, 'No technique. Just everything it has.', 10),
    ('blood_drain',   'Crimson Draw',     'blood',     1.15, 'It is looking at where you are already bleeding.', 10),
    ('poison_spit',   'Blighting Spit',   'poison',    1.10, 'Its mouth is producing more than it needs.', 10),
    ('soul_wail',     'Hollowing Cry',    'soul',      1.20, 'The sound arrives before it makes it.', 10),
    ('wisdom_read',   'Reading the Gap',  'wisdom',    1.25, 'It has been watching how you stand.', 10),
    ('wind_cut',      'Shearing Gust',    'wind',      1.20, 'The air narrows.', 10),
    ('light_flare',   'Blinding Halo',    'light',     1.25, 'It is getting harder to look at.', 10),
    ('shadow_lunge',  'Out of the Dark',  'shadow',    1.30, 'You lose track of where it is.', 10),
    ('bone_spur',     'Marrow Spur',      'bone',      1.25, 'Something is growing out of it that should be inside.', 10),
    ('star_fall',     'Falling Light',    'star',      1.35, 'It looks up. Nothing good follows that.', 10),
    ('illusion_split','Two of It',        'illusion',  1.10, 'There is more of it than there was.', 10),
    ('space_fold',    'Shortening',       'space',     1.30, 'The distance between you is a suggestion.', 10),
    ('time_drag',     'Long Second',      'time',      1.25, 'This is taking longer than it should.', 10),
    ('heaven_press',  'Weight of Heaven', 'heaven',    1.45, 'Something much larger is paying attention.', 8),
    ('human_guile',   'Cheap Trick',      'human',     1.05, 'It does something a person would do.', 10),
    ('food_gorge',    'Swallowing Whole', 'food',      1.30, 'It has decided you are food.', 10),
    ('rule_decree',   'By Right',         'rule',      1.25, 'It behaves as though it is allowed to win.', 10),
    ('theft_snatch',  'Light Fingers',    'theft',     1.00, 'It is not aiming at you. It is aiming at what you carry.', 10),
    ('transform_shift','Changing Shape',  'transformation', 1.20, 'The shape it had is not the shape it keeps.', 10),
    ('refine_burn',   'Crucible Heat',    'refinement',1.20, 'The air tastes of a furnace.', 10);


-- ---------------------------------------------------------------------------
-- What a combatant is about to do, and whether it braced
-- ---------------------------------------------------------------------------
-- On battle_combatants rather than on battles, because intent is a fact about
-- a combatant and a duel has two of them. `guarding` is cleared by the round
-- it applies to, so it can never silently persist into the next one.

ALTER TABLE battle_combatants
    ADD COLUMN intent_move_id BIGINT REFERENCES creature_moves (move_id) ON DELETE SET NULL,
    ADD COLUMN guarding BOOLEAN NOT NULL DEFAULT FALSE;

CREATE INDEX battle_combatants_intent_idx ON battle_combatants (intent_move_id);


-- ---------------------------------------------------------------------------
-- Tunables
-- ---------------------------------------------------------------------------

INSERT INTO game_config (key, value, description) VALUES
    ('flee_base_chance', 0.45,
     'PLACEHOLDER - chance of escaping something of your own rank.'),
    ('flee_rank_step', 0.18,
     'PLACEHOLDER - how much each rank of difference moves the flee chance.'),
    ('flee_min_chance', 0.05,
     'Nothing is inescapable.'),
    ('flee_max_chance', 0.95,
     'Nothing is a formality either.'),
    ('guard_damage_reduction', 0.50,
     'PLACEHOLDER - fraction of a blow a guard turns aside.'),
    ('guard_qi_restore', 0.20,
     'Fraction of the qi pool a guarded round returns. Guarding is how qi comes back mid-fight.'),
    ('battle_turn_cap', 50,
     'A fight nobody can win ends in a draw rather than running forever.');


-- ---------------------------------------------------------------------------
-- roll_creature_intent
-- ---------------------------------------------------------------------------
-- The move a creature is winding up. Its own Paths first; the pathless moves
-- are always in the pool so nothing is ever stuck without an option.

CREATE FUNCTION roll_creature_intent(p_species_id BIGINT)
RETURNS BIGINT
LANGUAGE sql
AS $$
    SELECT cm.move_id
    FROM creature_moves cm
    WHERE cm.roll_weight > 0
      AND (cm.path_code IS NULL
           OR EXISTS (SELECT 1 FROM creature_paths cp
                      WHERE cp.species_id = p_species_id
                        AND cp.path_code = cm.path_code))
    ORDER BY -ln(random()) / cm.roll_weight
    LIMIT 1;
$$;


-- ---------------------------------------------------------------------------
-- battle_overview
-- ---------------------------------------------------------------------------
-- Everything a battle card needs, in one row. A view rather than a function
-- returning the same join, so the bot can filter on it and the tests can read
-- it without calling anything.

CREATE VIEW battle_overview AS
SELECT
    b.battle_id,
    b.status,
    b.turn_number,
    b.winner_side,
    me.player_id,
    me.current_hp                    AS player_hp,
    me.max_hp                        AS player_max_hp,
    me.current_qi                    AS player_qi,
    (me.snapshot ->> 'max_qi')::bigint AS player_max_qi,
    me.guarding,
    it.species_id,
    s.name                           AS creature_name,
    s.rank                           AS creature_rank,
    s.description                    AS creature_description,
    it.current_hp                    AS creature_hp,
    it.max_hp                        AS creature_max_hp,
    (SELECT r.name FROM realms r WHERE r.rank = s.rank ORDER BY r.realm_id LIMIT 1)
                                     AS creature_realm,
    mv.name                          AS intent_name,
    mv.telegraph                     AS intent_text,
    mv.power_multiplier              AS intent_power
FROM battles b
JOIN battle_combatants me ON me.battle_id = b.battle_id AND me.combatant_no = 0
JOIN battle_combatants it ON it.battle_id = b.battle_id AND it.combatant_no = 1
JOIN creature_species s   ON s.species_id = it.species_id
LEFT JOIN creature_moves mv ON mv.move_id = it.intent_move_id;

COMMENT ON VIEW battle_overview IS
    'One row per PvE battle with both sides and the telegraphed move, for rendering and for tests.';


-- ---------------------------------------------------------------------------
-- battle_open
-- ---------------------------------------------------------------------------
-- Meeting a thing is what puts it in your bestiary, so the encounter is
-- recorded here rather than at the end - a fight you flee still happened, and
-- observing a creature needs the bestiary row to hang its findings on.

CREATE FUNCTION battle_open(p_player_id BIGINT, p_species_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    species  creature_species%ROWTYPE;
    body     player_physique%ROWTYPE;
    max_qi   BIGINT;
    b_id     BIGINT;
BEGIN
    SELECT * INTO STRICT species FROM creature_species WHERE species_id = p_species_id;
    SELECT * INTO STRICT body FROM player_physique WHERE player_id = p_player_id;

    IF body.current_hp <= 0 THEN
        RAISE EXCEPTION 'no strength left to fight' USING ERRCODE = 'check_violation';
    END IF;

    IF EXISTS (SELECT 1 FROM player_active_battle WHERE player_id = p_player_id) THEN
        RAISE EXCEPTION 'already in a battle' USING ERRCODE = 'check_violation';
    END IF;

    SELECT r.qi_capacity INTO max_qi
    FROM player_cultivation pc
    JOIN realms r ON r.realm_id = pc.realm_id
    WHERE pc.player_id = p_player_id;
    max_qi := GREATEST(1, COALESCE(max_qi, 1));

    INSERT INTO battles (kind, status, rng_seed)
    VALUES ('pve', 'active', floor(random() * 9223372036854775806)::bigint)
    RETURNING battles.battle_id INTO b_id;

    INSERT INTO battle_combatants
        (battle_id, combatant_no, side, player_id, snapshot, max_hp, current_hp, current_qi)
    VALUES (b_id, 0, 0, p_player_id,
            jsonb_build_object('max_hp', body.max_hp, 'defense', body.defense,
                               'strength', body.strength, 'max_qi', max_qi),
            body.max_hp, body.current_hp, max_qi);

    INSERT INTO battle_combatants
        (battle_id, combatant_no, side, species_id, snapshot, max_hp, current_hp,
         intent_move_id)
    VALUES (b_id, 1, 1, p_species_id,
            jsonb_build_object('base_attack', species.base_attack,
                               'base_defense', species.base_defense,
                               'rank', species.rank),
            species.base_hp, species.base_hp,
            roll_creature_intent(p_species_id));

    INSERT INTO player_active_battle (player_id, battle_id) VALUES (p_player_id, b_id);

    INSERT INTO player_bestiary (player_id, species_id, times_encountered)
    VALUES (p_player_id, p_species_id, 1)
    ON CONFLICT (player_id, species_id) DO UPDATE
        SET times_encountered = player_bestiary.times_encountered + 1,
            last_seen_at      = now();

    RETURN b_id;
END;
$$;

COMMENT ON FUNCTION battle_open(BIGINT, BIGINT) IS
    'Starts an interactive PvE battle: combatants, the qi pool, the first telegraphed move, and the bestiary encounter.';


-- ---------------------------------------------------------------------------
-- battle_conclude
-- ---------------------------------------------------------------------------
-- Everything that happens once, at the end: the verdict, the HP written back
-- to the body, the claim released, and the drops. Lifted out of hunt() rather
-- than rewritten, so a kill yields exactly what it used to.

CREATE FUNCTION battle_conclude(p_battle_id BIGINT, p_status TEXT)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    me         battle_combatants%ROWTYPE;
    it         battle_combatants%ROWTYPE;
    victory    BOOLEAN := (p_status = 'complete');
    drop_list  JSONB := '[]'::jsonb;
    d          RECORD;
    qty        BIGINT;
BEGIN
    SELECT * INTO me FROM battle_combatants
    WHERE battle_id = p_battle_id AND combatant_no = 0;
    SELECT * INTO it FROM battle_combatants
    WHERE battle_id = p_battle_id AND combatant_no = 1;

    victory := victory AND it.current_hp <= 0;

    UPDATE battles b
    SET status      = p_status,
        winner_side = CASE
                          WHEN p_status <> 'complete' THEN NULL
                          WHEN it.current_hp <= 0 THEN 0
                          ELSE 1
                      END,
        ended_at    = now()
    WHERE b.battle_id = p_battle_id;

    UPDATE player_physique SET current_hp = me.current_hp WHERE player_id = me.player_id;
    DELETE FROM player_active_battle WHERE battle_id = p_battle_id;

    IF victory THEN
        UPDATE player_bestiary
        SET times_defeated = times_defeated + 1
        WHERE player_id = me.player_id AND species_id = it.species_id;

        FOR d IN
            SELECT cd.material_code, cd.chance, cd.min_quantity, cd.max_quantity, m.name
            FROM creature_drops cd
            JOIN materials m ON m.code = cd.material_code
            WHERE cd.species_id = it.species_id
        LOOP
            IF random() < d.chance THEN
                qty := d.min_quantity
                       + floor(random() * (d.max_quantity - d.min_quantity + 1));
                PERFORM grant_material(me.player_id, d.material_code, qty);
                drop_list := drop_list || jsonb_build_object(
                    'code', d.material_code, 'name', d.name, 'quantity', qty);
            END IF;
        END LOOP;
    END IF;

    RETURN drop_list;
END;
$$;


-- ---------------------------------------------------------------------------
-- battle_act
-- ---------------------------------------------------------------------------
-- One round: the player's action, then the creature's answer, then the next
-- telegraph. Everything that resolves is logged as it resolved.
--
-- Observe and a failed flee both COST THE ROUND - the creature still swings.
-- That is what makes them decisions rather than free information and free
-- retries.

CREATE FUNCTION battle_act(
    p_battle_id    BIGINT,
    p_action       TEXT,
    p_technique_id BIGINT DEFAULT NULL
)
RETURNS TABLE (
    finished        BOOLEAN,
    outcome         TEXT,
    dealt           BIGINT,
    taken           BIGINT,
    player_hp       BIGINT,
    creature_hp     BIGINT,
    qi_after        BIGINT,
    qi_spent        BIGINT,
    move_name       TEXT,
    enemy_move      TEXT,
    revealed_path   TEXT,
    revealed_effect TEXT,
    note            TEXT,
    drops           JSONB
)
LANGUAGE plpgsql
AS $$
DECLARE
    fight      battles%ROWTYPE;
    me         battle_combatants%ROWTYPE;
    it         battle_combatants%ROWTYPE;
    species    creature_species%ROWTYPE;
    tech       techniques%ROWTYPE;
    move       creature_moves%ROWTYPE;
    hit        RECORD;
    external   NUMERIC;
    cost       BIGINT := 0;
    p_hp       BIGINT;
    c_hp       BIGINT;
    qi         BIGINT;
    dmg_out    BIGINT := 0;
    dmg_in     BIGINT := 0;
    my_move    TEXT;
    escaped    BOOLEAN := FALSE;
    chance     NUMERIC;
    my_rank    SMALLINT;
    reveal     RECORD;
    said       TEXT := '';
    ends_as    TEXT;
    loot       JSONB := '[]'::jsonb;
    guarded    BOOLEAN;
BEGIN
    SELECT * INTO fight FROM battles WHERE battle_id = p_battle_id FOR UPDATE;
    IF NOT FOUND OR fight.status <> 'active' THEN
        RAISE EXCEPTION 'that fight is over' USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO me FROM battle_combatants
    WHERE battle_id = p_battle_id AND combatant_no = 0 FOR UPDATE;
    SELECT * INTO it FROM battle_combatants
    WHERE battle_id = p_battle_id AND combatant_no = 1 FOR UPDATE;

    SELECT * INTO species FROM creature_species WHERE species_id = it.species_id;

    p_hp := me.current_hp;
    c_hp := it.current_hp;
    qi   := me.current_qi;

    -- ---- the player's half -------------------------------------------------
    IF p_action = 'attack' THEN
        SELECT * INTO tech FROM techniques WHERE technique_id = p_technique_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'no such technique' USING ERRCODE = 'check_violation';
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM player_usable_techniques u
            WHERE u.player_id = me.player_id AND u.technique_id = p_technique_id
        ) THEN
            RAISE EXCEPTION 'you cannot use %', tech.name USING ERRCODE = 'check_violation';
        END IF;

        cost := ceil(tech.qi_cost_pct * (me.snapshot ->> 'max_qi')::bigint);
        IF qi < cost THEN
            RAISE EXCEPTION 'not enough qi for %', tech.name USING ERRCODE = 'check_violation';
        END IF;
        qi := qi - cost;

        external := player_external_multiplier(me.player_id, p_technique_id);
        SELECT * INTO hit FROM compute_technique_damage(
            me.player_id, p_technique_id, it.species_id, external,
            (it.snapshot ->> 'base_defense')::bigint);

        c_hp    := GREATEST(0, c_hp - hit.final_damage);
        dmg_out := hit.final_damage;
        my_move := tech.name;

        INSERT INTO battle_actions
            (battle_id, actor_no, turn_number, action, technique_id, technique_name,
             target_no, base_power, attainment_bonus, matchup_modifier, damage, detail)
        VALUES (p_battle_id, 0, fight.turn_number, 'technique', p_technique_id, tech.name, 1,
                hit.base_power, hit.attainment_bonus, hit.matchup_modifier, hit.final_damage,
                jsonb_build_object('external', external, 'qi_spent', cost,
                                   'target_hp_after', c_hp));

        -- Swinging a Path at something teaches you what that Path does to it.
        INSERT INTO player_bestiary_paths (player_id, species_id, path_code, discovered_via)
        SELECT me.player_id, it.species_id, cip.path_code, 'combat'
        FROM creature_incoming_paths cip
        JOIN technique_paths tp ON tp.path_code = cip.path_code
        WHERE cip.species_id = it.species_id AND tp.technique_id = p_technique_id
        ON CONFLICT DO NOTHING;

    ELSIF p_action = 'guard' THEN
        my_move := 'Guard';
        qi := LEAST((me.snapshot ->> 'max_qi')::bigint,
                    qi + ceil(game_config_value('guard_qi_restore')
                              * (me.snapshot ->> 'max_qi')::bigint));
        said := 'You brace. The next blow lands on your terms.';

        INSERT INTO battle_actions
            (battle_id, actor_no, turn_number, action, target_no, detail)
        VALUES (p_battle_id, 0, fight.turn_number, 'pass', 1,
                jsonb_build_object('guard', TRUE, 'qi_after', qi));

    ELSIF p_action = 'observe' THEN
        my_move := 'Observe';

        SELECT cip.path_code, cip.interaction, cip.flavour_text, p.name
        INTO reveal
        FROM creature_incoming_paths cip
        JOIN paths p ON p.code = cip.path_code
        WHERE cip.species_id = it.species_id
          AND NOT EXISTS (
              SELECT 1 FROM player_bestiary_paths bp
              WHERE bp.player_id = me.player_id
                AND bp.species_id = it.species_id
                AND bp.path_code = cip.path_code
          )
        ORDER BY CASE cip.interaction
                     WHEN 'weakness' THEN 0 WHEN 'immunity' THEN 1 ELSE 2 END,
                 random()
        LIMIT 1;

        IF reveal.path_code IS NULL THEN
            said := 'You watch it move. There is nothing left about it you do not know.';
        ELSE
            INSERT INTO player_bestiary_paths
                (player_id, species_id, path_code, discovered_via)
            VALUES (me.player_id, it.species_id, reveal.path_code, 'combat')
            ON CONFLICT DO NOTHING;
            said := COALESCE(NULLIF(reveal.flavour_text, ''),
                             'You see how it takes ' || reveal.name || '.');
        END IF;

        INSERT INTO battle_actions
            (battle_id, actor_no, turn_number, action, target_no, discovered_path, detail)
        VALUES (p_battle_id, 0, fight.turn_number, 'system', 1, reveal.path_code,
                jsonb_build_object('observed', TRUE));

    ELSIF p_action = 'flee' THEN
        my_move := 'Flee';

        SELECT r.rank INTO my_rank
        FROM player_cultivation pc JOIN realms r ON r.realm_id = pc.realm_id
        WHERE pc.player_id = me.player_id;

        chance := game_config_value('flee_base_chance')
                  + game_config_value('flee_rank_step')
                    * (COALESCE(my_rank, 1) - species.rank);
        chance := GREATEST(game_config_value('flee_min_chance'),
                           LEAST(game_config_value('flee_max_chance'), chance));
        escaped := random() < chance;

        INSERT INTO battle_actions
            (battle_id, actor_no, turn_number, action, target_no, detail)
        VALUES (p_battle_id, 0, fight.turn_number, 'flee', 1,
                jsonb_build_object('chance', round(chance, 4), 'escaped', escaped));

        IF escaped THEN
            UPDATE battle_combatants bc SET current_hp = p_hp, current_qi = qi, guarding = FALSE
            WHERE bc.battle_id = p_battle_id AND bc.combatant_no = 0;

            loot := battle_conclude(p_battle_id, 'fled');
            RETURN QUERY SELECT TRUE, 'fled', 0::bigint, 0::bigint, p_hp, c_hp, qi, 0::bigint,
                                my_move, NULL::text, NULL::text, NULL::text,
                                'You break away. Nothing follows you far.', loot;
            RETURN;
        END IF;
        said := 'It cuts you off.';
    ELSE
        RAISE EXCEPTION 'no such action: %', p_action USING ERRCODE = 'check_violation';
    END IF;

    -- ---- did that finish it? ----------------------------------------------
    IF c_hp <= 0 THEN
        UPDATE battle_combatants bc SET current_hp = c_hp
        WHERE bc.battle_id = p_battle_id AND bc.combatant_no = 1;
        UPDATE battle_combatants bc SET current_hp = p_hp, current_qi = qi, guarding = FALSE
        WHERE bc.battle_id = p_battle_id AND bc.combatant_no = 0;

        loot := battle_conclude(p_battle_id, 'complete');
        RETURN QUERY SELECT TRUE, 'won', dmg_out, 0::bigint, p_hp, c_hp, qi, cost,
                            my_move, NULL::text, reveal.path_code, reveal.interaction,
                            said, loot;
        RETURN;
    END IF;

    -- ---- the creature answers ----------------------------------------------
    SELECT * INTO move FROM creature_moves WHERE move_id = it.intent_move_id;
    guarded := (p_action = 'guard');

    SELECT * INTO hit FROM compute_creature_damage(
        it.species_id, me.player_id,
        COALESCE(move.power_multiplier, 1),
        (me.snapshot ->> 'defense')::bigint);

    dmg_in := hit.final_damage;
    IF guarded THEN
        dmg_in := GREATEST(0, floor(dmg_in * (1 - game_config_value('guard_damage_reduction'))));
    END IF;

    p_hp := GREATEST(0, p_hp - dmg_in);

    INSERT INTO battle_actions
        (battle_id, actor_no, turn_number, action, technique_name, target_no,
         base_power, attainment_bonus, matchup_modifier, damage, detail)
    VALUES (p_battle_id, 1, fight.turn_number, 'technique',
            COALESCE(move.name, species.name), 0,
            hit.base_power, hit.attainment_bonus, hit.matchup_modifier, dmg_in,
            jsonb_build_object('guarded', guarded, 'target_hp_after', p_hp));

    -- ---- next round --------------------------------------------------------
    UPDATE battle_combatants bc
    SET current_hp = p_hp, current_qi = qi, guarding = FALSE
    WHERE bc.battle_id = p_battle_id AND bc.combatant_no = 0;

    UPDATE battle_combatants bc
    SET current_hp = c_hp, intent_move_id = roll_creature_intent(bc.species_id)
    WHERE bc.battle_id = p_battle_id AND bc.combatant_no = 1;

    UPDATE battles b SET turn_number = b.turn_number + 1 WHERE b.battle_id = p_battle_id;

    IF p_hp <= 0 THEN
        ends_as := 'lost';
    ELSIF fight.turn_number + 1 > game_config_value('battle_turn_cap') THEN
        ends_as := 'drawn';
    END IF;

    IF ends_as IS NOT NULL THEN
        loot := battle_conclude(p_battle_id,
                                CASE WHEN ends_as = 'lost' THEN 'complete' ELSE 'expired' END);
        RETURN QUERY SELECT TRUE, ends_as, dmg_out, dmg_in, p_hp, c_hp, qi, cost,
                            my_move, COALESCE(move.name, species.name),
                            reveal.path_code, reveal.interaction, said, loot;
        RETURN;
    END IF;

    RETURN QUERY SELECT FALSE, 'ongoing', dmg_out, dmg_in, p_hp, c_hp, qi, cost,
                        my_move, COALESCE(move.name, species.name),
                        reveal.path_code, reveal.interaction, said, loot;
END;
$$;

COMMENT ON FUNCTION battle_act(BIGINT, TEXT, BIGINT) IS
    'One round of an interactive battle: the player acts, the creature answers, the next move is telegraphed. Observing and failing to flee both cost the round.';


-- ---------------------------------------------------------------------------
-- battle_abandon
-- ---------------------------------------------------------------------------
-- A fight nobody came back to. Called by /battle when the player walks away
-- from one, so a forgotten battle cannot lock the claim forever.

CREATE FUNCTION battle_abandon(p_battle_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM battle_conclude(p_battle_id, 'expired');
END;
$$;


-- ---------------------------------------------------------------------------
-- hunt() retires
-- ---------------------------------------------------------------------------
-- Its bestiary, discovery and drop logic now lives in battle_open and
-- battle_conclude, called a round at a time. Keeping the auto-resolver beside
-- them would be keeping two engines for one fight, and this schema has already
-- paid the bill for that once.

DROP FUNCTION hunt(BIGINT, BIGINT, BIGINT);
