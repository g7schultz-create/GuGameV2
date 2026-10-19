-- 0021_manuals
--
-- Cultivation manuals: equippable techniques-as-books that speed cultivation
-- and unlock the combat moves written in them. Two may be carried at once.
--
-- WHAT THIS IS AND IS NOT. The design has manuals being *refined* from Manual
-- Pages, with harmony, fusion Paths, a Refinement skill and procedural naming.
-- None of that is here, because pages do not drop yet and a refinement system
-- with no ingredients is a system nobody can use. What is here is the half a
-- player can touch today - owning, equipping and benefiting from a manual -
-- built so refinement writes into the same tables rather than beside them.
--
-- The shape that makes that work is taken from `techniques`, which has held
-- canonical and player-created moves in one table since 0004 for exactly this
-- reason: `created_by` NULL means the game wrote it, set means a player did.
-- A refined manual is therefore an ordinary row with `created_by` set and its
-- harmony and page history filled in. The columns for that are here and NULL
-- until refinement exists, rather than a second table to migrate into later.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- manuals
-- ---------------------------------------------------------------------------
-- INSTANCE rows, not templates. The design is explicit that two manuals with
-- the same name can have different stats and histories, so there is no
-- "manual type" to point at - each row IS a manual, and a player owning one is
-- a row in player_manuals pointing here.

CREATE TABLE manuals (
    manual_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    -- Stable handle for the seeded ones, exactly as techniques.code works.
    -- NULL for anything a player refines, which has no meaning outside itself.
    code        TEXT UNIQUE,

    name        TEXT NOT NULL,

    tier        SMALLINT NOT NULL DEFAULT 1 CHECK (tier BETWEEN 1 AND 10),

    -- Gates use behind cultivation realm, the same way techniques.rank does.
    required_rank SMALLINT NOT NULL DEFAULT 1 CHECK (required_rank BETWEEN 1 AND 9),

    archetype   TEXT NOT NULL DEFAULT 'hybrid'
                CHECK (archetype IN ('cultivation', 'offensive', 'defensive',
                                     'movement', 'body', 'gathering',
                                     'refinement', 'essence', 'breakthrough',
                                     'hybrid')),

    -- Additive fractions, matching races/roots/physiques so every bonus in the
    -- game sums the same way. 0.06 is +6%.
    cultivation_rate_bonus NUMERIC(6, 4) NOT NULL DEFAULT 0,
    physique_rate_bonus    NUMERIC(6, 4) NOT NULL DEFAULT 0,
    attainment_rate_bonus  NUMERIC(6, 4) NOT NULL DEFAULT 0,
    hp_bonus               NUMERIC(6, 4) NOT NULL DEFAULT 0,
    defense_bonus          NUMERIC(6, 4) NOT NULL DEFAULT 0,
    strength_bonus         NUMERIC(6, 4) NOT NULL DEFAULT 0,

    special_name TEXT,
    special_text TEXT,
    description  TEXT NOT NULL DEFAULT '',

    -- Refinement's half of the table. NULL until pages exist.
    --
    -- `harmony` is the design's central variable: how well the pages became one
    -- technique. It is nullable rather than defaulted to 0 because a seeded
    -- manual was never refined, and 0 would read as "refined terribly".
    harmony     SMALLINT CHECK (harmony IS NULL OR harmony BETWEEN 0 AND 150),
    created_by  BIGINT REFERENCES players (player_id) ON DELETE CASCADE,
    refined_at  TIMESTAMPTZ,

    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- A refined manual has a refiner and a harmony; a seeded one has neither.
    -- Half-set rows are how a "player-made" manual ends up with no maker.
    CONSTRAINT manuals_refinement_is_whole CHECK (
        (created_by IS NULL AND refined_at IS NULL AND harmony IS NULL)
        OR
        (created_by IS NOT NULL AND refined_at IS NOT NULL AND harmony IS NOT NULL)
    ),
    -- A refined manual is unique to its refiner, so it gets no stable handle.
    CONSTRAINT manuals_refined_manuals_have_no_code CHECK (
        created_by IS NULL OR code IS NULL
    )
);

CREATE INDEX manuals_creator_idx ON manuals (created_by);
CREATE INDEX manuals_tier_idx ON manuals (tier, required_rank);

COMMENT ON TABLE manuals IS
    'One row per manual that exists. created_by NULL = seeded content; set = refined by that player.';
COMMENT ON COLUMN manuals.harmony IS
    'Refinement quality, 0-150. NULL for a seeded manual - it was never refined, and 0 would read as refined badly.';


-- ---------------------------------------------------------------------------
-- manual_paths
-- ---------------------------------------------------------------------------
-- Dominant and secondary Paths, weighted. Same shape as technique_paths, and
-- the design's "Fire 65% / Wind 25% / Wisdom 10%" drops straight in.
--
-- Deliberately NOT constrained to sum to 1. technique_paths is, because the
-- damage pipeline weight-averages over it and weights that do not sum to 1
-- silently change a technique's power. Nothing multiplies through these yet,
-- and a refined manual's Path split is descriptive.

CREATE TABLE manual_paths (
    manual_id BIGINT NOT NULL REFERENCES manuals (manual_id) ON DELETE CASCADE,
    path_code TEXT   NOT NULL REFERENCES paths (code) ON DELETE RESTRICT,

    weight    NUMERIC(6, 4) NOT NULL DEFAULT 1 CHECK (weight > 0 AND weight <= 1),

    PRIMARY KEY (manual_id, path_code)
);

CREATE INDEX manual_paths_path_idx ON manual_paths (path_code);


-- ---------------------------------------------------------------------------
-- manual_techniques
-- ---------------------------------------------------------------------------
-- The moves written in the book. Equipping the manual is what makes them
-- usable - this is the "unlock combat moves" half.
--
-- RESTRICT on the technique: a manual that unlocks a move which no longer
-- exists is a manual that silently got worse, and deleting canonical content
-- should have to reckon with what depends on it.

CREATE TABLE manual_techniques (
    manual_id    BIGINT NOT NULL REFERENCES manuals (manual_id) ON DELETE CASCADE,
    technique_id BIGINT NOT NULL REFERENCES techniques (technique_id) ON DELETE RESTRICT,

    PRIMARY KEY (manual_id, technique_id)
);

CREATE INDEX manual_techniques_technique_idx ON manual_techniques (technique_id);


-- ---------------------------------------------------------------------------
-- player_manuals
-- ---------------------------------------------------------------------------

CREATE TABLE player_manuals (
    player_id  BIGINT NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,
    manual_id  BIGINT NOT NULL REFERENCES manuals (manual_id) ON DELETE CASCADE,

    got_at     TIMESTAMPTZ NOT NULL DEFAULT now(),

    PRIMARY KEY (player_id, manual_id)
);

CREATE INDEX player_manuals_manual_idx ON player_manuals (manual_id);


-- ---------------------------------------------------------------------------
-- player_manual_slots
-- ---------------------------------------------------------------------------
-- Two slots, and the limit is the primary key's CHECK rather than something
-- the bot counts before inserting - two commands racing would both pass a
-- count and both equip.
--
-- The composite FK into player_manuals is the same trick player_loadout uses
-- for techniques: equipping a manual you do not own is impossible rather than
-- merely validated, and losing one clears the slot automatically.

CREATE TABLE player_manual_slots (
    player_id   BIGINT   NOT NULL,
    slot_index  SMALLINT NOT NULL CHECK (slot_index IN (0, 1)),
    manual_id   BIGINT   NOT NULL,

    equipped_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    PRIMARY KEY (player_id, slot_index),

    -- The same manual cannot be in both slots.
    UNIQUE (player_id, manual_id),

    FOREIGN KEY (player_id, manual_id)
        REFERENCES player_manuals (player_id, manual_id) ON DELETE CASCADE
);

CREATE INDEX player_manual_slots_manual_idx ON player_manual_slots (manual_id);

COMMENT ON TABLE player_manual_slots IS
    'Two equipped manuals. The two-slot limit is a CHECK, not a count the caller performs.';


-- ---------------------------------------------------------------------------
-- player_manual_bonuses
-- ---------------------------------------------------------------------------
-- What the equipped manuals are worth, summed. Kept separate from
-- player_trait_rates because that view is about what a character IS - race,
-- root, body - and this is about what they are carrying. They combine at the
-- point of use, additively, like every other bonus in this game.

CREATE VIEW player_manual_bonuses AS
SELECT
    s.player_id,
    COALESCE(sum(m.cultivation_rate_bonus), 0) AS cultivation_rate_bonus,
    COALESCE(sum(m.physique_rate_bonus), 0)    AS physique_rate_bonus,
    COALESCE(sum(m.attainment_rate_bonus), 0)  AS attainment_rate_bonus,
    COALESCE(sum(m.hp_bonus), 0)               AS hp_bonus,
    COALESCE(sum(m.defense_bonus), 0)          AS defense_bonus,
    COALESCE(sum(m.strength_bonus), 0)         AS strength_bonus,
    count(*)                                   AS equipped
FROM player_manual_slots s
JOIN manuals m ON m.manual_id = s.manual_id
GROUP BY s.player_id;

COMMENT ON VIEW player_manual_bonuses IS
    'Equipped manuals summed. A player with none has no row - callers COALESCE, as they do for a missing physique.';


-- ---------------------------------------------------------------------------
-- player_usable_techniques
-- ---------------------------------------------------------------------------
-- What a player may actually throw: what they have learned, plus what their
-- equipped manuals unlock.
--
-- A view rather than copying manual techniques into player_techniques on
-- equip, because unequipping would then have to work out which rows to take
-- back - and a learned technique and a borrowed one would be indistinguishable
-- the moment that went wrong once.

CREATE VIEW player_usable_techniques AS
SELECT pt.player_id, pt.technique_id, 'learned'::text AS source, NULL::bigint AS manual_id
FROM player_techniques pt

UNION

SELECT s.player_id, mt.technique_id, 'manual'::text, m.manual_id
FROM player_manual_slots s
JOIN manuals m ON m.manual_id = s.manual_id
JOIN manual_techniques mt ON mt.manual_id = m.manual_id;

COMMENT ON VIEW player_usable_techniques IS
    'Learned techniques plus those unlocked by equipped manuals. Unequipping withdraws access with no bookkeeping.';


-- ---------------------------------------------------------------------------
-- Passive cultivation reads the manuals
-- ---------------------------------------------------------------------------
-- Same function as 0015, with the equipped manuals' cultivation and physique
-- bonuses folded in. Additive with the trait multipliers, so a +5% root and a
-- +6% manual make +11%, not +11.3%.

CREATE OR REPLACE FUNCTION settle_passive_cultivation(p_player_id BIGINT)
RETURNS TABLE (
    hours              NUMERIC,
    capped             BOOLEAN,
    cultivation_gained BIGINT,
    physique_gained    BIGINT,
    insight_gained     BIGINT,
    hp_restored        BIGINT,
    focus_path         TEXT,
    realm_before       SMALLINT,
    realm_after        SMALLINT,
    level_before       SMALLINT,
    level_after        SMALLINT,
    tier_before        SMALLINT,
    tier_after         SMALLINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    cult          player_cultivation%ROWTYPE;
    rates         player_trait_rates%ROWTYPE;
    baseline      NUMERIC := game_config_value('training_aptitude_baseline');
    cap_hours     NUMERIC := game_config_value('passive_cap_hours');
    manual_cult   NUMERIC := 0;
    manual_phys   NUMERIC := 0;
    elapsed       NUMERIC;
    paid          NUMERIC;
    was_capped    BOOLEAN;
    cult_gain     BIGINT;
    phys_gain     BIGINT;
    insight_gain  BIGINT := 0;
    hp_gain       BIGINT := 0;
    hp_before     BIGINT;
    hp_after      BIGINT;
    r_before      SMALLINT;
    r_after       SMALLINT;
    l_before      SMALLINT;
    l_after       SMALLINT;
    t_before      SMALLINT;
    t_after       SMALLINT;
BEGIN
    SELECT * INTO cult FROM player_cultivation
    WHERE player_id = p_player_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'player % has no cultivation row', p_player_id;
    END IF;

    elapsed    := EXTRACT(EPOCH FROM (now() - cult.last_tick_at)) / 3600.0;
    was_capped := elapsed > cap_hours;
    paid       := LEAST(elapsed, cap_hours);

    SELECT * INTO rates FROM player_trait_rates WHERE player_id = p_player_id;

    SELECT b.cultivation_rate_bonus, b.physique_rate_bonus
    INTO manual_cult, manual_phys
    FROM player_manual_bonuses b WHERE b.player_id = p_player_id;
    manual_cult := COALESCE(manual_cult, 0);
    manual_phys := COALESCE(manual_phys, 0);

    SELECT pc.realm_id INTO r_before FROM player_cultivation pc WHERE pc.player_id = p_player_id;
    SELECT pp.body_level INTO l_before FROM player_physique pp WHERE pp.player_id = p_player_id;
    SELECT COALESCE(a.tier, 0) INTO t_before
    FROM (SELECT 1) _
    LEFT JOIN player_path_attainment a
        ON a.player_id = p_player_id AND a.path_code = cult.focus_path;

    cult_gain := round(
        paid
        * game_config_value('passive_cultivation_per_hour')
        * (COALESCE(rates.cultivation_multiplier, 1) + manual_cult)
        * (cult.aptitude / baseline)
        * CASE WHEN cult.focus_path IS NULL THEN 1
               ELSE game_config_value('path_cultivation_xp_rate') END
    );

    phys_gain := round(
        paid
        * game_config_value('passive_physique_per_hour')
        * (COALESCE(rates.physique_multiplier, 1) + manual_phys)
    );

    IF cult.focus_path IS NOT NULL THEN
        insight_gain := round(
            paid
            * game_config_value('passive_insight_per_hour')
            * player_attainment_rate(p_player_id, cult.focus_path)
        );
    END IF;

    r_after := apply_cultivation_xp(p_player_id, cult_gain);
    l_after := apply_physique_xp(p_player_id, phys_gain);

    SELECT pp.current_hp INTO hp_before
    FROM player_physique pp WHERE pp.player_id = p_player_id;

    UPDATE player_physique pp
    SET current_hp = least(pp.max_hp,
                           pp.current_hp + floor(paid * 60 * pp.regeneration)::bigint)
    WHERE pp.player_id = p_player_id
    RETURNING pp.current_hp INTO hp_after;

    hp_gain := GREATEST(0, COALESCE(hp_after, 0) - COALESCE(hp_before, 0));

    IF cult.focus_path IS NOT NULL THEN
        t_after := grant_path_insight(
            p_player_id, cult.focus_path, insight_gain, round(paid * 3600)::bigint, 0
        );
    ELSE
        t_after := t_before;
    END IF;

    UPDATE player_cultivation
    SET last_tick_at = last_tick_at + make_interval(secs => paid * 3600)
    WHERE player_id = p_player_id;

    RETURN QUERY SELECT
        round(paid, 4), was_capped,
        cult_gain, phys_gain, insight_gain, COALESCE(hp_gain, 0), cult.focus_path,
        r_before, r_after, l_before, l_after, t_before, t_after;
END;
$$;


-- ---------------------------------------------------------------------------
-- The starter library
-- ---------------------------------------------------------------------------
-- Seeded manuals, one per canonical technique, so that every move in the game
-- has a book it can be learned from once pages and refinement arrive. Tier and
-- required_rank track the technique they teach.
--
-- Cultivation bonuses rise with tier: a Tier 1 book is +3%, a Tier 6 is +15%.
-- These are PLACEHOLDER like every other rate, and additive with race, root and
-- physique.

INSERT INTO manuals
    (code, name, tier, required_rank, archetype,
     cultivation_rate_bonus, physique_rate_bonus, attainment_rate_bonus,
     hp_bonus, defense_bonus, strength_bonus,
     special_name, special_text, description)
VALUES
    ('crimson_palm_canon', 'Crimson Palm Canon', 1, 1, 'offensive',
     0.0300, 0, 0, 0, 0, 0, NULL, NULL,
     'Twelve pages on how to hit someone with your own blood. Most of it is about the recovery.'),

    ('rooted_mountain_method', 'Rooted Mountain Method', 1, 1, 'defensive',
     0.0300, 0, 0, 0.0500, 0.0500, 0, NULL, NULL,
     'A standing method. The first chapter is a month of not moving.'),

    ('scarlet_flame_breathing_method', 'Scarlet Flame Breathing Method', 2, 1, 'offensive',
     0.0600, 0, 0, 0, 0, 0, NULL, NULL,
     'Breathe in on the count, out on the strike. The margin for error narrows as you improve.'),

    ('venomous_jade_wood_scripture', 'Venomous Jade Wood Scripture', 2, 2, 'offensive',
     0.0600, 0, 0.0300, 0, 0, 0, NULL, NULL,
     'Written on lacquered bamboo by someone who did not expect to be read.'),

    ('azure_frost_lotus_scripture', 'Azure Frost Lotus Scripture', 3, 2, 'cultivation',
     0.0800, 0, 0.0500, 0, 0.0500, 0, NULL, NULL,
     'A cold method. Practitioners are calm, and it is not always the good kind.'),

    ('iron_mountain_tyrant_body', 'Iron Mountain Tyrant Body', 3, 3, 'body',
     0.0500, 0.1500, 0, 0.1000, 0.0800, 0.1000,
     'Unmoved', 'The body method the Northern tribes teach before they teach a weapon.',
     'Body tempering, and nothing else. It does not pretend to make you clever.'),

    ('profound_thunder_steps', 'Profound Thunder Steps', 3, 3, 'movement',
     0.0700, 0.0500, 0, 0, 0, 0, NULL, NULL,
     'A movement method. The name is a warning about the noise.'),

    ('thousand_thought_soul_canon', 'Thousand Thought Soul Canon', 4, 3, 'cultivation',
     0.1200, 0, 0.1000, 0, 0, 0,
     'Thousand Thought', 'Reading it a second time is not the same as reading it once.',
     'The canon most sects hand out and most disciples never finish.'),

    ('blazing_heaven_sword_art', 'Blazing Heaven Sword Art', 5, 4, 'offensive',
     0.1000, 0, 0.0500, 0, 0, 0.0500, NULL, NULL,
     'Two Paths in one edge. The book is adamant that they are not layered.'),

    ('blood_blade_scripture', 'Blood Blade Scripture', 6, 6, 'offensive',
     0.1500, 0, 0.1000, 0, 0, 0.1000,
     'Price of the Edge', 'The scripture is honest that it costs the wielder as much as anyone.',
     'Rank 6, and the only copies are the ones people did not survive writing.');

INSERT INTO manual_paths (manual_id, path_code, weight)
SELECT m.manual_id, v.path_code, v.weight
FROM (VALUES
    ('crimson_palm_canon',             'blood',     1.0000),
    ('rooted_mountain_method',         'earth',     1.0000),
    ('scarlet_flame_breathing_method', 'fire',      1.0000),
    ('venomous_jade_wood_scripture',   'poison',    0.7000),
    ('venomous_jade_wood_scripture',   'wood',      0.3000),
    ('azure_frost_lotus_scripture',    'ice',       0.8000),
    ('azure_frost_lotus_scripture',    'water',     0.2000),
    ('iron_mountain_tyrant_body',      'strength',  0.6000),
    ('iron_mountain_tyrant_body',      'earth',     0.4000),
    ('profound_thunder_steps',         'lightning', 1.0000),
    ('thousand_thought_soul_canon',    'wisdom',    0.7000),
    ('thousand_thought_soul_canon',    'soul',      0.3000),
    ('blazing_heaven_sword_art',       'sword',     0.5000),
    ('blazing_heaven_sword_art',       'fire',      0.5000),
    ('blood_blade_scripture',          'blood',     1.0000)
) AS v (manual_code, path_code, weight)
JOIN manuals m ON m.code = v.manual_code;

INSERT INTO manual_techniques (manual_id, technique_id)
SELECT m.manual_id, t.technique_id
FROM (VALUES
    ('crimson_palm_canon',             'crimson_palm'),
    ('rooted_mountain_method',         'rooted_stance'),
    ('scarlet_flame_breathing_method', 'ember_lash'),
    ('venomous_jade_wood_scripture',   'venom_thorn_net'),
    ('azure_frost_lotus_scripture',    'frost_lotus_seal'),
    ('iron_mountain_tyrant_body',      'mountain_breaker_fist'),
    ('profound_thunder_steps',         'thunder_step'),
    ('thousand_thought_soul_canon',    'minds_eye'),
    ('blazing_heaven_sword_art',       'blazing_heaven_sword'),
    ('blood_blade_scripture',          'blood_blade')
) AS v (manual_code, technique_code)
JOIN manuals m ON m.code = v.manual_code
JOIN techniques t ON t.code = v.technique_code;


-- ---------------------------------------------------------------------------
-- Finding one
-- ---------------------------------------------------------------------------
-- Until pages drop and refinement exists, a manual is something you find on a
-- body. Rank gates which ones can turn up, so a Central Continent rat cannot
-- hand a new cultivator a rank 6 killing scripture.

INSERT INTO game_config (key, value, description) VALUES
    ('manual_drop_chance', 0.04,
     'PLACEHOLDER - chance a kill yields a manual, before rank filtering.');

CREATE FUNCTION roll_manual_drop(p_player_id BIGINT, p_species_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    creature_rank SMALLINT;
    found         BIGINT;
BEGIN
    IF random() >= game_config_value('manual_drop_chance') THEN
        RETURN NULL;
    END IF;

    SELECT rank INTO creature_rank FROM creature_species WHERE species_id = p_species_id;

    -- A manual no harder than the thing guarding it, and not one already owned.
    SELECT m.manual_id INTO found
    FROM manuals m
    WHERE m.created_by IS NULL
      AND m.required_rank <= GREATEST(creature_rank, 1)
      AND NOT EXISTS (
          SELECT 1 FROM player_manuals pm
          WHERE pm.player_id = p_player_id AND pm.manual_id = m.manual_id
      )
    ORDER BY random()
    LIMIT 1;

    IF found IS NULL THEN
        RETURN NULL;
    END IF;

    INSERT INTO player_manuals (player_id, manual_id) VALUES (p_player_id, found)
    ON CONFLICT DO NOTHING;

    RETURN found;
END;
$$;

COMMENT ON FUNCTION roll_manual_drop(BIGINT, BIGINT) IS
    'A manual off a corpse, gated by the creature''s rank and never a duplicate. The stopgap until pages and refinement exist.';
