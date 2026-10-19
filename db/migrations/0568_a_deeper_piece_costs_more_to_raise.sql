-- 0568_a_deeper_piece_costs_more_to_raise
--
-- 0567 gave equipment a level that can be raised and priced it off the level
-- alone. Measured against the live world, that was far too cheap and the wrong
-- shape besides.
--
--     the whole ladder, level 1 to 18          221,180 work
--     what a deep cultivator already holds   5.6M - 15.7M
--
-- So clearwest could take twenty-five pieces from the bottom of the ladder to
-- the top out of the shelf they are already standing on, and shinonn reached
-- the cap by pouring in FOUR material stacks. "Sacrifice a ton of materials"
-- was the ask and four stacks is not a ton.
--
-- And the price ignored the piece. A tier 3 trinket and the tier 10 the Vault
-- pays out cost exactly the same to raise, which makes the Venerable piece the
-- cheapest thing in the game per point of what it becomes.
--
-- SO THE LADDER IS SCALED BY `tier^2`, the same squaring a material's own
-- worth already uses - depth is worth more than volume on both sides of the
-- trade:
--
--     tier  3     1.99M work for the full climb
--     tier  5     5.53M
--     tier  8    14.2M
--     tier 10    22.1M     <- half again what the richest cultivator holds
--
-- A Vault piece is now a project measured in inventories rather than in
-- stacks, and a shallow piece stays cheap enough to be worth bothering with.
--
-- Nothing already raised is clawed back: `exp` is spent on the way past each
-- level, so a piece that climbed under 0567's prices keeps every level it
-- bought. Only what is still ahead of it costs more.


DROP FUNCTION IF EXISTS equipment_exp_needed(SMALLINT);

CREATE FUNCTION equipment_exp_needed(p_level SMALLINT, p_tier SMALLINT)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $fn$
    -- NULL at the top of the ladder, which is how every caller knows to stop.
    SELECT CASE
        WHEN p_level >= (SELECT max(level) FROM equipment_level_scales)
        THEN NULL
        ELSE GREATEST(1, round(
            game_config_value('equipment_exp_base')
            * power(game_config_value('equipment_exp_growth'),
                    GREATEST(0, p_level - 1))
            -- DEPTH COSTS. Squared, matching `equipment_food_value`, so the
            -- two sides of the trade read the same way: a tier 10 piece wants
            -- a hundred times what a tier 1 does, and a tier 10 material is
            -- worth a hundred tier 1 ones.
            * power(GREATEST(1, COALESCE(p_tier, 1)), 2)))::bigint
    END;
$fn$;

COMMENT ON FUNCTION equipment_exp_needed(SMALLINT, SMALLINT) IS
    'Work to take a piece of this tier from this level to the next; NULL at the top of the ladder. Scaled by tier^2 since 0568 - priced on level alone, the Vault''s tier 10 cost the same to raise as a trinket and a deep cultivator could max twenty-five pieces from the shelf they already had.';


-- The three callers, each of which already has the piece in hand.
DO $patch$
DECLARE
    src     TEXT;
    patched TEXT;
    v_fn    TEXT;
BEGIN
    FOREACH v_fn IN ARRAY ARRAY['equipment_absorb', 'feed_equipment',
                                'feed_equipment_gear'] LOOP
        SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
        WHERE proname = v_fn AND pronamespace = 'public'::regnamespace;

        patched := src;
        patched := replace(patched, 'equipment_exp_needed(now_l)',
                                    'equipment_exp_needed(now_l, piece.tier)');
        patched := replace(patched, 'equipment_exp_needed(piece.level)',
                                    'equipment_exp_needed(piece.level, piece.tier)');
        patched := replace(patched, 'equipment_exp_needed(keep.level)',
                                    'equipment_exp_needed(keep.level, keep.tier)');
        patched := replace(patched, 'equipment_exp_needed(got.level_after)',
                                    'equipment_exp_needed(got.level_after, piece.tier)');

        IF patched = src THEN
            RAISE EXCEPTION '% did not read the old signature anywhere', v_fn;
        END IF;
        EXECUTE patched;
    END LOOP;
END
$patch$;

-- `feed_equipment_gear` reports against the piece it KEEPS, which it calls
-- `keep` rather than `piece` - so the one substitution above missed it.
DO $patch$
DECLARE
    src     TEXT;
    patched TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'feed_equipment_gear' AND pronamespace = 'public'::regnamespace;

    patched := replace(src, 'equipment_exp_needed(got.level_after, piece.tier)',
                            'equipment_exp_needed(got.level_after, keep.tier)');
    IF patched <> src THEN
        EXECUTE patched;
    END IF;
END
$patch$;


-- ---------------------------------------------------------------------------
-- The probes
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_cheap BIGINT;
    v_dear  BIGINT;
    v_rich  BIGINT;
    v_fn    TEXT;
BEGIN
    -- 1. DEPTH COSTS, and by the square.
    SELECT sum(equipment_exp_needed(level::smallint, 1::smallint))
    INTO v_cheap FROM generate_series(1, 17) level;
    SELECT sum(equipment_exp_needed(level::smallint, 10::smallint))
    INTO v_dear FROM generate_series(1, 17) level;

    -- Within a whisker rather than exactly: every level is rounded on its
    -- own, so a sum of rounded steps is not the rounding of a summed step.
    -- The first version of this demanded equality and failed on 135 parts in
    -- 22 million, which is the probe being wrong rather than the ladder.
    IF abs(v_dear::numeric / NULLIF(v_cheap, 0) - 100) > 0.01 THEN
        RAISE EXCEPTION
            'a tier 10 climb costs % against a tier 1 climb of % - a ratio of '
            '%, and it should be a hundred', v_dear, v_cheap,
            round(v_dear::numeric / NULLIF(v_cheap, 0), 4);
    END IF;

    -- 2. AND A VAULT PIECE IS NOW A PROJECT. The richest shelf in the world
    --    must not cover the whole climb, or "a ton of materials" is four
    --    stacks again.
    SELECT max(held) INTO v_rich FROM (
        SELECT sum(equipment_food_value(pm.material_code, pm.quantity)) AS held
        FROM player_materials pm
        JOIN materials m ON m.code = pm.material_code
        JOIN players p ON p.player_id = pm.player_id
        WHERE pm.quantity > 0 AND p.deleted_at IS NULL AND p.discord_id > 0
          AND (m.tier IS NOT NULL OR m.category = 'beast')
        GROUP BY pm.player_id) x;

    IF v_rich IS NOT NULL AND v_rich >= v_dear THEN
        RAISE EXCEPTION
            'the richest cultivator holds % and the full tier 10 climb costs '
            '% - it is still a shelf away', v_rich, v_dear;
    END IF;

    RAISE NOTICE
        'a tier 10 climb costs %, against the richest shelf in the world at %',
        v_dear, v_rich;

    -- 3. NOTHING STILL CALLS THE OLD ONE-ARGUMENT FORM. It is dropped, so a
    --    survivor would be a function that cannot run at all.
    FOREACH v_fn IN ARRAY ARRAY['equipment_absorb', 'feed_equipment',
                                'feed_equipment_gear'] LOOP
        IF (SELECT pg_get_functiondef(oid) FROM pg_proc
            WHERE proname = v_fn AND pronamespace = 'public'::regnamespace)
           ~ 'equipment_exp_needed\([a-z_.]+\)' THEN
            RAISE EXCEPTION '% still calls equipment_exp_needed with one argument', v_fn;
        END IF;
    END LOOP;
END
$probe$;
