-- 0506_the_metal_the_miner_and_the_smith_move_together
--
-- 0504 opened a ninth mining band for the Heavenly Court's veins and opened
-- it on one side only. The standing tests said so immediately, and the
-- comment above the ladder table in the test suite had already said it:
--
--     "Both of these ran to 7 until 0317 added Pseudo-Immortal gear, which
--      is tier 8 - so the metal, the miner who digs it and the smith who
--      works it all had to gain a rung together."
--
-- I gave the miner a rung and left the smith at eight, which makes tier 9 ore
-- a material nobody can work - a rung painted on the wall, which is the exact
-- phrase 0393's test uses for the same mistake in the Gu bench.
--
-- So the other two halves:
--
--     forge_tier         a seventh rung at level 117, continuing 6/14/26/42/60/85
--     smith_tier_cap     LEAST(8) -> LEAST(9), the last reader in the schema
--                        still holding the old ceiling
--     equipment_tiers    a ninth row, because the forge reads its potency
--                        and magnitude out of a table that stops at eight
--
-- THE NUMBERS COME OFF THE CURVE RATHER THAN OUT OF MY HEAD.
--
--     magnitude  0.06 0.10 0.16 0.25 0.38 0.55 0.80 1.15   ratios ~1.44 at the top
--     potency       4   12   28   60  120  230  400 1200   the last step is x3
--
-- so tier 9 is magnitude 1.65 and potency 3,600. The jump at tier 8 was
-- already x3 on potency; keeping that makes the ninth band a project rather
-- than the next level up, which is what an apex band should be.
--
-- And the three ladder tests are updated where they carry the old cap as a
-- constant - `LADDERS` in the test suite - because `rungs == cap - base` is
-- the invariant and it still holds: 9 - 1 = 8 rungs for mining, 9 - 2 = 7 for
-- the forge.
--
-- NO TIER 9 ORE EXISTS YET. It is seeded with the Heavenly Court in 0507,
-- which is the only place it comes from.
--
-- Forward-only. Do not edit once applied.


-- A fifth ceiling, found the same way as the other four - by trying. The
-- gear tier table has its own CHECK stopping at 8, so the row could not go
-- in even with the ladders widened.
ALTER TABLE equipment_tiers DROP CONSTRAINT equipment_tiers_tier_check;
ALTER TABLE equipment_tiers ADD CONSTRAINT equipment_tiers_tier_check
    CHECK (tier >= 1 AND tier <= 9);

INSERT INTO equipment_tiers (tier, potency_required, base_magnitude)
VALUES (9, 3600.00, 1.6500)
ON CONFLICT (tier) DO NOTHING;

INSERT INTO profession_steps (ladder, step, level_required)
VALUES ('forge_tier', 7, 117)
ON CONFLICT DO NOTHING;

DO $patch$
DECLARE
    src TEXT;
BEGIN
    src := pg_get_functiondef('smith_tier_cap(smallint)'::regprocedure);
    IF (length(src) - length(replace(src, 'LEAST(8,', ''))) / length('LEAST(8,') <> 1 THEN
        RAISE EXCEPTION 'the forge ceiling in smith_tier_cap is not there exactly once';
    END IF;
    EXECUTE replace(src, 'LEAST(8,', 'LEAST(9,');
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Both trades reach the ninth band, and the band exists to reach
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_mine SMALLINT;
    v_forge SMALLINT;
    v_n     INTEGER;
    v_bad   TEXT;
BEGIN
    v_mine  := mining_tier_cap(32767::SMALLINT);
    v_forge := smith_tier_cap(32767::SMALLINT);

    IF v_mine <> 9 OR v_forge <> 9 THEN
        RAISE EXCEPTION
            'the miner reaches % and the smith %, wanted 9 and 9', v_mine, v_forge;
    END IF;

    -- The invariant the test suite enforces: one rung per band between the
    -- base and the cap, no missing rung and no spare one.
    SELECT string_agg(x.ladder || ' has ' || x.rungs || ' rungs for ' || x.wants, ', ')
    INTO v_bad
    FROM (
        SELECT 'mining_tier' AS ladder,
               (SELECT count(*) FROM profession_steps WHERE ladder = 'mining_tier') AS rungs,
               9 - game_config_value('mining_base_tier') AS wants
        UNION ALL
        SELECT 'forge_tier',
               (SELECT count(*) FROM profession_steps WHERE ladder = 'forge_tier'),
               9 - game_config_value('forge_base_tier')
    ) x
    WHERE x.rungs <> x.wants;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'a ladder is the wrong length: %', v_bad;
    END IF;

    -- Both ladders still only climb, which a trigger enforces on write and
    -- nothing enforced on the rows that were already there.
    SELECT string_agg(a.ladder, ', ') INTO v_bad
    FROM profession_steps a JOIN profession_steps b
      ON b.ladder = a.ladder AND b.step = a.step + 1
    WHERE b.level_required <= a.level_required;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'a ladder stopped climbing: %', v_bad;
    END IF;

    -- The forge can price the band it can now reach.
    IF NOT EXISTS (SELECT 1 FROM equipment_tiers WHERE tier = 9) THEN
        RAISE EXCEPTION 'the smith reaches tier 9 and the tier table stops at 8';
    END IF;

    -- And the gear curve still only climbs, on both columns.
    SELECT count(*) INTO v_n
    FROM equipment_tiers a JOIN equipment_tiers b ON b.tier = a.tier + 1
    WHERE b.potency_required <= a.potency_required
       OR b.base_magnitude <= a.base_magnitude;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'the gear tier curve stopped climbing at % places', v_n;
    END IF;

    -- Nobody can already forge the apex. The deepest smith alive is what
    -- decides whether this is a goal or a formality.
    SELECT count(*) INTO v_n FROM player_professions
    WHERE profession = 'blacksmithing' AND level >= 117;

    RAISE NOTICE
        'miner and smith both reach band 9; % smiths are already past the new rung',
        v_n;
END;
$probe$;
