-- 0318_a_miner_deep_enough_to_reach_it
--
-- 0317 put tier 8 metal in the ground and left no way to dig it up.
-- `mining_tier_cap` clamps at 7, so the five Pseudo-Immortal seams were in
-- five regions, in the vein tables, findable by nobody. Four schema rules
-- caught it between them, which is the system working:
--
--   every_region_reaches_every_tier_of_ore   regions now hold 1..8, not 1..7
--   a_deeper_miner_reaches_deeper            the deepest miner still got 7
--   a_ladder_has_exactly_the_rungs_its_range_needs
--   the_top_rung_is_where_the_cap_lands
--
-- The last two are the interesting pair. A ladder must have exactly
-- `cap - base` rungs, and its top rung must land EXACTLY on the cap - one
-- short is a tier nobody can reach, one spare is a rung that buys nothing
-- because the LEAST() above it has already clamped. Adding a tier means both
-- ladders that lead to it grow a rung, or the tier is decorative.
--
-- Mining goes to 8 with a rung at 92. That is above the forge's 85 on
-- purpose: you have to be able to dig the metal before being able to work it
-- is worth anything, and a smith who qualifies first simply waits on a miner
-- - which is the correct dependency between two professions that are
-- supposed to need each other.
--
-- Forward-only. Do not edit once applied.


INSERT INTO profession_steps (ladder, step, level_required)
VALUES ('mining_tier', 7, 92);

CREATE OR REPLACE FUNCTION mining_tier_cap(p_level SMALLINT)
RETURNS SMALLINT
LANGUAGE sql
STABLE
AS $$
    SELECT LEAST(8, game_config_value('mining_base_tier')
                    + ladder_steps('mining_tier', p_level))::smallint;
$$;


-- ---------------------------------------------------------------------------
-- Both ladders span their range exactly, and land on their cap
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    rungs INTEGER;
    top   SMALLINT;
BEGIN
    -- Mining: base 1, cap 8, so seven rungs.
    SELECT count(*), max(level_required) INTO rungs, top
    FROM profession_steps WHERE ladder = 'mining_tier';
    IF rungs <> 8 - game_config_value('mining_base_tier') THEN
        RAISE EXCEPTION 'mining_tier has % rungs, wants %',
            rungs, 8 - game_config_value('mining_base_tier');
    END IF;
    IF mining_tier_cap(top) <> 8 THEN
        RAISE EXCEPTION 'the top mining rung gives %, not 8', mining_tier_cap(top);
    END IF;
    IF mining_tier_cap((top - 1)::smallint) <> 7 THEN
        RAISE EXCEPTION 'mining was already capped before its top rung';
    END IF;

    -- Forging: base 2, cap 8, so six rungs.
    SELECT count(*), max(level_required) INTO rungs, top
    FROM profession_steps WHERE ladder = 'forge_tier';
    IF rungs <> 8 - game_config_value('forge_base_tier') THEN
        RAISE EXCEPTION 'forge_tier has % rungs, wants %',
            rungs, 8 - game_config_value('forge_base_tier');
    END IF;
    IF smith_tier_cap(top) <> 8 THEN
        RAISE EXCEPTION 'the top forge rung gives %, not 8', smith_tier_cap(top);
    END IF;
    IF smith_tier_cap((top - 1)::smallint) <> 7 THEN
        RAISE EXCEPTION 'forging was already capped before its top rung';
    END IF;

    -- And digging comes before working: a smith cannot reach tier 8 before
    -- somebody can mine it.
    IF (SELECT max(level_required) FROM profession_steps WHERE ladder = 'forge_tier')
       >= (SELECT max(level_required) FROM profession_steps WHERE ladder = 'mining_tier') THEN
        RAISE EXCEPTION 'a smith reaches tier 8 before any miner can supply it';
    END IF;
END;
$$;


-- ---------------------------------------------------------------------------
-- Every region runs 1 to 8 without a gap
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    bad TEXT;
BEGIN
    SELECT string_agg(t.region_code || ' (' || t.low || '-' || t.high
                      || ', ' || t.distinct_tiers || ' tiers)', ', ')
    INTO bad
    FROM (
        SELECT rv.region_code, min(o.tier) AS low, max(o.tier) AS high,
               count(DISTINCT o.tier) AS distinct_tiers
        FROM region_veins rv JOIN ores o ON o.material_code = rv.material_code
        GROUP BY rv.region_code
    ) t
    WHERE (t.low, t.high, t.distinct_tiers) <> (1, 8, 8);

    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these regions do not run 1 to 8: %', bad;
    END IF;

    RAISE NOTICE 'all five regions hold every tier from 1 to 8';
END;
$$;
