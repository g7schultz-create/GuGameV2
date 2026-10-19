-- 0254_a_breakthrough_rewrites_your_fate
--
-- Two cultivators at the same realm are the same cultivator.
--
-- Everything that separates them today is equipment: which Gu they fitted,
-- which manual they refined, what they forged. All of it is tradeable,
-- replaceable and eventually optimal - two people who have played the same
-- number of hours converge on the same aperture. Nothing about a cultivator is
-- theirs.
--
-- SO A GREAT REALM REWRITES YOUR FATE. Crossing into a new rank offers three
-- Destinies drawn at random from the ones that realm allows, and one is
-- chosen, permanently. By the Ancient Realm a cultivator carries seven of
-- them, drawn from a pool of thirty, and the odds of two people carrying the
-- same seven are remote. That is a build nobody can buy.
--
-- IT IS BUILT ON THE VOCABULARY THAT ALREADY EXISTS. A Destiny grants
-- `gu_effects` - the same thirty-two words a Gu speaks - so `player_stat`
-- gains one more source and every fight in the game reads them without another
-- line being written. `player_swing` and `player_take` do not know Destinies
-- exist and never need to.
--
-- THE THREE ARE ROLLED ONCE AND KEPT. A player who could re-roll by walking
-- away and coming back is a player choosing from all thirty, and the choice is
-- meant to be between what fate offered - so the offer is written down the
-- moment it is made.
--
-- Forward-only. Do not edit once applied.


CREATE TABLE destinies (
    code        TEXT PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE,
    description TEXT NOT NULL,
    min_rank    SMALLINT NOT NULL DEFAULT 2 CHECK (min_rank BETWEEN 2 AND 9),
    roll_weight NUMERIC(6,3) NOT NULL DEFAULT 1 CHECK (roll_weight >= 0)
);

COMMENT ON TABLE destinies IS
    'Permanent traits offered at a great realm. `min_rank` keeps the heavier ones out of the early realms, where they would decide a cultivator before they had one.';

CREATE TABLE destiny_effects (
    code        TEXT NOT NULL REFERENCES destinies (code) ON DELETE CASCADE,
    effect_code TEXT NOT NULL REFERENCES gu_effects (code) ON DELETE RESTRICT,
    magnitude   NUMERIC(6,4) NOT NULL,
    PRIMARY KEY (code, effect_code)
);

CREATE INDEX destiny_effects_effect_idx ON destiny_effects (effect_code);

COMMENT ON TABLE destiny_effects IS
    'What a Destiny grants, in the vocabulary a Gu already speaks - so `player_stat` gains a source and every fight reads it with no further change.';

CREATE TABLE player_destinies (
    player_id  BIGINT NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,
    rank       SMALLINT NOT NULL CHECK (rank BETWEEN 2 AND 9),
    code       TEXT REFERENCES destinies (code) ON DELETE RESTRICT,
    offered    TEXT[] NOT NULL,
    offered_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    chosen_at  TIMESTAMPTZ,
    PRIMARY KEY (player_id, rank),
    CONSTRAINT destiny_chosen_has_a_time CHECK ((code IS NULL) = (chosen_at IS NULL))
);

CREATE INDEX player_destinies_code_idx ON player_destinies (code);

COMMENT ON COLUMN player_destinies.offered IS
    'The three fate put in front of them, written down when the offer was made. Rolling on read would let somebody walk away and come back until they liked the choice.';


-- ---------------------------------------------------------------------------
-- Thirty fates
-- ---------------------------------------------------------------------------

INSERT INTO destinies (code, name, description, min_rank, roll_weight) VALUES
 ('scorched_meridian',  'Scorched Meridian',  'Your channels ran too hot once and never cooled. Blows land heavier and open guards wider.', 2, 1),
 ('blood_nourishes',    'Blood Nourishes Blood', 'What you spill, you take back. The wound feeds the one who made it.', 2, 1),
 ('beast_kings_presence','Beast King''s Presence', 'Beasts know what you are before you speak. They fight worse for it.', 2, 1),
 ('iron_skin',          'Iron Skin',          'Something struck you hard enough that the body decided never again.', 2, 1),
 ('swift_shadow',       'Swift Shadow',       'You have not been where a blow landed for a long time.', 2, 1),
 ('vast_sea',           'Vast Sea',           'The dantian widened past what the realm should allow.', 2, 1),
 ('unbroken_will',      'Unbroken Will',      'A body that refuses is harder to finish than a body that resists.', 2, 1),
 ('sharpened_intent',   'Sharpened Intent',   'You have stopped swinging at where a thing is.', 2, 1),
 ('deep_roots',         'Deep Roots',         'Cultivation settles into you faster than it leaves.', 2, 1),
 ('herbalists_eye',     'Herbalist''s Eye',   'What grows here has stopped hiding from you.', 2, 1),

 ('twin_strike',        'Twin Strike',        'The second blow arrives before the first is finished.', 3, 0.8),
 ('armour_render',      'Armour Render',      'You have learned where the plates do not meet.', 3, 0.9),
 ('cornered_beast',     'Cornered Beast',     'You have always been most dangerous with a wall behind you.', 3, 0.9),
 ('gathering_storm',    'Gathering Storm',    'The longer it lasts, the worse it goes for them.', 3, 0.9),
 ('jade_body',          'Jade Body',          'The flesh took the tempering better than it had any right to.', 3, 0.9),
 ('quiet_step',         'Quiet Step',         'Fortune finds those who are not making noise.', 3, 0.9),
 ('furnace_heart',      'Furnace Heart',      'Pills work on you the way they are supposed to work on everyone.', 3, 0.9),
 ('smiths_hand',        'Smith''s Hand',      'The metal does what you meant rather than what you did.', 3, 0.9),

 ('heavens_scorn',      'Heaven''s Scorn',    'Something above took an interest, and it was not kind.', 5, 0.6),
 ('sea_of_bitterness',  'Sea of Bitterness',  'You have carried so much that carrying more costs nothing.', 5, 0.7),
 ('killing_intent',     'Killing Intent',     'The strike that ends it comes harder than the ones before.', 5, 0.7),
 ('demon_heart',        'Demon Heart',        'You stopped flinching some realms ago.', 5, 0.7),
 ('hundred_refinements','Hundred Refinements','Every conflicting thing in you has been argued into agreement.', 5, 0.7),
 ('mountain_root',      'Mountain Root',      'Moving you is a project rather than an attack.', 5, 0.7),

 ('immortal_bones',     'Immortal Bones',     'The skeleton has begun to refuse ordinary death.', 7, 0.4),
 ('nine_lives',         'Nine Lives',         'The blow that should have ended it lands somewhere you have already left.', 7, 0.4),
 ('dao_of_slaughter',   'Dao of Slaughter',   'You have killed enough that the act itself has become a technique.', 7, 0.4),
 ('worm_sovereign',     'Worm Sovereign',     'The Gu do not resent being worn by you.', 7, 0.4),
 ('heaven_defying',     'Heaven Defying',     'Every rule you have been given, you have found the edge of.', 8, 0.3),
 ('primordial_origin',  'Primordial Origin',  'Whatever you were before the first realm, some of it came with you.', 8, 0.3);


INSERT INTO destiny_effects (code, effect_code, magnitude) VALUES
 ('scorched_meridian',   'attack_power',    0.10),
 ('scorched_meridian',   'armor_pen',       0.05),
 ('blood_nourishes',     'lifesteal',       0.06),
 ('beast_kings_presence','beast_damage',    0.12),
 ('iron_skin',           'damage_reduction',0.07),
 ('swift_shadow',        'dodge',           0.05),
 ('vast_sea',            'max_qi',          0.15),
 ('unbroken_will',       'braced',          0.08),
 ('sharpened_intent',    'crit_rate',       0.06),
 ('deep_roots',          'cultivation_rate',0.12),
 ('herbalists_eye',      'gathering_yield', 0.15),

 ('twin_strike',         'multi_hit',       0.15),
 ('armour_render',       'armor_pen',       0.12),
 ('cornered_beast',      'wounded_power',   0.20),
 ('gathering_storm',     'momentum',        0.05),
 ('jade_body',           'max_hp',          0.15),
 ('quiet_step',          'resource_find',   0.15),
 ('furnace_heart',       'pill_potency',    0.20),
 ('smiths_hand',         'forge_power',     0.15),

 ('heavens_scorn',       'attack_power',    0.20),
 ('heavens_scorn',       'damage_reduction',-0.05),
 ('sea_of_bitterness',   'max_hp',          0.25),
 ('killing_intent',      'crit_damage',     0.25),
 ('demon_heart',         'suppression',     0.15),
 ('hundred_refinements', 'refine_conflict_relief', 0.20),
 ('mountain_root',       'damage_reduction',0.10),
 ('mountain_root',       'dodge',          -0.03),

 ('immortal_bones',      'death_ward',      0.15),
 ('nine_lives',          'dodge',           0.10),
 ('dao_of_slaughter',    'attack_power',    0.25),
 ('worm_sovereign',      'gu_potency',      0.20),
 ('heaven_defying',      'matchup_relief',  0.25),
 ('primordial_origin',   'realm_tempering', 0.30);


-- ---------------------------------------------------------------------------
-- A seventh source for every stat in the game
-- ---------------------------------------------------------------------------

CREATE FUNCTION destiny_stat(p_player_id BIGINT, p_effect TEXT)
RETURNS NUMERIC
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(sum(de.magnitude), 0)
    FROM player_destinies pd
    JOIN destiny_effects de ON de.code = pd.code
    WHERE pd.player_id = p_player_id AND de.effect_code = p_effect;
$$;

COMMENT ON FUNCTION destiny_stat(BIGINT, TEXT) IS
    'What a cultivator''s fates grant. Added to `player_stat` like every other source, so a Destiny reaches every fight without any of them being told.';


CREATE OR REPLACE FUNCTION player_stat(p_player_id BIGINT, p_effect TEXT)
RETURNS NUMERIC
LANGUAGE sql STABLE
AS $$
    SELECT LEAST(
        (SELECT ef.cap FROM gu_effects ef WHERE ef.code = p_effect),
        gu_stat(p_player_id, p_effect)
        + equipment_stat(p_player_id, p_effect)
        + physique_stat(p_player_id, p_effect)
        + root_stat(p_player_id, p_effect)
        + dwelling_stat(p_player_id, p_effect)
        + manual_stat(p_player_id, p_effect)
        + destiny_stat(p_player_id, p_effect)
    );
$$;


-- ---------------------------------------------------------------------------
-- The offer, and the choice
-- ---------------------------------------------------------------------------

CREATE FUNCTION destiny_offer(p_player_id BIGINT, p_rank SMALLINT)
RETURNS TEXT[]
LANGUAGE plpgsql
AS $$
DECLARE
    said TEXT[];
BEGIN
    -- Already offered: the same three, forever. Rolling on read would let a
    -- cultivator walk away and come back until fate suggested what they wanted.
    SELECT pd.offered INTO said FROM player_destinies pd
    WHERE pd.player_id = p_player_id AND pd.rank = p_rank;

    IF said IS NOT NULL THEN
        RETURN said;
    END IF;

    SELECT array_agg(d.code) INTO said FROM (
        SELECT d.code FROM destinies d
        WHERE d.min_rank <= p_rank
          AND d.roll_weight > 0
          -- Nothing twice. A fate is a thing you are, not a stack.
          AND NOT EXISTS (SELECT 1 FROM player_destinies p
                          WHERE p.player_id = p_player_id AND p.code = d.code)
        ORDER BY -ln(random()) / d.roll_weight
        LIMIT 3
    ) d;

    IF said IS NULL OR array_length(said, 1) < 1 THEN
        RETURN NULL;
    END IF;

    INSERT INTO player_destinies (player_id, rank, offered)
    VALUES (p_player_id, p_rank, said)
    ON CONFLICT (player_id, rank) DO NOTHING;

    RETURN said;
END;
$$;

COMMENT ON FUNCTION destiny_offer(BIGINT, SMALLINT) IS
    'The three fate put in front of this cultivator at this realm, rolled once and remembered.';


CREATE FUNCTION destiny_take(p_player_id BIGINT, p_rank SMALLINT, p_code TEXT)
RETURNS TABLE (name TEXT, description TEXT, grants TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    row_now player_destinies%ROWTYPE;
BEGIN
    SELECT * INTO row_now FROM player_destinies
    WHERE player_id = p_player_id AND rank = p_rank
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'fate has not offered you anything at that realm'
            USING ERRCODE = 'check_violation';
    END IF;
    IF row_now.code IS NOT NULL THEN
        RAISE EXCEPTION 'that fate is already written'
            USING ERRCODE = 'check_violation';
    END IF;
    IF NOT (p_code = ANY (row_now.offered)) THEN
        RAISE EXCEPTION 'that was not one of the three put in front of you'
            USING ERRCODE = 'check_violation';
    END IF;

    UPDATE player_destinies
    SET code = p_code, chosen_at = now()
    WHERE player_id = p_player_id AND rank = p_rank;

    RETURN QUERY
    SELECT d.name, d.description,
           (SELECT string_agg(ef.emoji || ' ' || ef.name || ' '
                              || CASE WHEN de.magnitude < 0 THEN '' ELSE '+' END
                              || round(100 * de.magnitude) || '%',
                              ', ' ORDER BY ef.sort_order)
            FROM destiny_effects de
            JOIN gu_effects ef ON ef.code = de.effect_code
            WHERE de.code = d.code)
    FROM destinies d WHERE d.code = p_code;
END;
$$;


-- What a cultivator is still owed, so no screen has to work it out.
CREATE VIEW destiny_pending AS
SELECT pd.player_id, pd.rank, pd.offered
FROM player_destinies pd
WHERE pd.code IS NULL;

COMMENT ON VIEW destiny_pending IS
    'Offers made and not yet taken. A cultivator who broke through and closed the screen still has their three waiting.';


-- ---------------------------------------------------------------------------
-- The door makes the offer
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc WHERE proname = 'breakthrough';

    old := '    -- The tribulation goes here: a roll before this line, and an outcome
    -- column on the way out. Everything below is what surviving one is worth.';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'breakthrough no longer marks where the tribulation goes';
    END IF;

    src := replace(src, old,
'    -- A great realm rewrites your fate. The offer is made here and taken
    -- later, so somebody who broke through and closed the screen still finds
    -- their three waiting.
    IF becomes.rank > was.rank THEN
        PERFORM destiny_offer(p_player_id, becomes.rank);
    END IF;

    -- The tribulation goes here: a roll before this line, and an outcome
    -- column on the way out. Everything below is what surviving one is worth.');

    EXECUTE src;
END;
$$;


DO $$
DECLARE
    who   BIGINT;
    three TEXT[];
    took  RECORD;
    said  TEXT;
BEGIN
    SELECT p.player_id INTO who FROM players p
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0 LIMIT 1;
    IF who IS NULL THEN
        RAISE NOTICE 'nobody to offer a fate to; the tests carry it';
        RETURN;
    END IF;

    BEGIN
        DELETE FROM player_destinies WHERE player_id = who;

        three := destiny_offer(who, 3::smallint);
        IF three IS NULL OR array_length(three, 1) <> 3 THEN
            RAISE EXCEPTION 'fate offered % rather than three',
                COALESCE(array_length(three, 1), 0);
        END IF;

        -- The same three however often it is asked.
        IF destiny_offer(who, 3::smallint) <> three THEN
            RAISE EXCEPTION 'the offer changed when it was looked at again';
        END IF;

        -- Something outside the three is refused.
        BEGIN
            PERFORM destiny_take(who, 3::smallint, (
                SELECT d.code FROM destinies d
                WHERE NOT (d.code = ANY (three)) LIMIT 1));
            RAISE EXCEPTION 'a fate nobody offered was taken';
        EXCEPTION
            WHEN check_violation THEN NULL;
        END;

        SELECT * INTO took FROM destiny_take(who, 3::smallint, three[1]);
        IF took.name IS NULL THEN
            RAISE EXCEPTION 'taking a fate said nothing about it';
        END IF;

        -- And it reaches every fight, because it reaches player_stat.
        IF NOT EXISTS (
            SELECT 1 FROM destiny_effects de
            WHERE de.code = three[1]
              AND player_stat(who, de.effect_code) >= de.magnitude) THEN
            RAISE EXCEPTION 'the fate was written and changed nothing';
        END IF;

        -- Only once.
        BEGIN
            PERFORM destiny_take(who, 3::smallint, three[2]);
            RAISE EXCEPTION 'a realm handed out two fates';
        EXCEPTION
            WHEN check_violation THEN NULL;
        END;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
