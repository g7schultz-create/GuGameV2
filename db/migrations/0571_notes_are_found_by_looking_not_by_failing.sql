-- 0571_notes_are_found_by_looking_not_by_failing
--
-- 0570 hung the Ancient Venerable Notes roll on `mat IS NULL`, meaning it only
-- fired when the ordinary outcome draw came up EMPTY. Measured: nought in
-- three hundred walks, against a stated chance of six per cent.
--
-- Two things wrong with it, and the second is worse than the first.
--
-- The arithmetic: `nothing` carries a weight of 18 out of 100, so gating on it
-- made the real chance 0.18 x 0.06, about one walk in ninety.
--
-- And the direction. `nothing` is the ONE outcome an Explorer's level reduces -
-- 'an Explorer's level is worth exactly the nothing it removes' - so hanging a
-- find on it meant the better a cultivator was at exploring, the less often
-- they found the rarest thing exploring can give. A skill that makes a find
-- rarer is not a skill.
--
-- The essence find in the same function already shows the right shape: roll it
-- on its own, and let it take the slot when it lands. Notes now do the same,
-- and sit AFTER essence so that on the rare walk where both come up, the
-- rarer thing is what the cultivator goes home with.


DO $patch$
DECLARE
    src     TEXT;
    patched TEXT;
    anchor  TEXT :=
'    IF mat IS NULL
       AND EXISTS (SELECT 1 FROM player_dao d WHERE d.player_id = p_player_id)
       AND random() < game_config_value(''explore_notes_chance'') THEN';
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'explore' AND pronamespace = 'public'::regnamespace;

    IF position(anchor IN src) = 0 THEN
        RAISE EXCEPTION 'explore does not roll for notes the way 0570 left it';
    END IF;

    patched := replace(src, anchor,
'    -- ON ITS OWN, not on the ordinary draw coming up empty. 0570 gated this
    -- on `mat IS NULL`, which meant it could only land on the `nothing`
    -- outcome - and `nothing` is the one weight an Explorer''s level takes
    -- away, so the better the explorer the rarer the find. Nought in three
    -- hundred walks, measured.
    --
    -- Placed after the essence block so the rarer of the two wins a tie.
    IF EXISTS (SELECT 1 FROM player_dao d WHERE d.player_id = p_player_id)
       AND random() < game_config_value(''explore_notes_chance'') THEN');

    IF patched = src THEN
        RAISE EXCEPTION 'the explore patch changed nothing';
    END IF;
    EXECUTE patched;
END
$patch$;


-- ---------------------------------------------------------------------------
-- The probe
--
-- Walked rather than read. The whole fault in 0570 was a condition that looked
-- right in the source and fired one time in ninety, so the only assertion
-- worth making here is how often it actually lands.
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who  BIGINT;
    v_cold BIGINT;
    r      RECORD;
    i      INTEGER;
    v_hit  INTEGER := 0;
    v_none INTEGER := 0;
    v_want NUMERIC := game_config_value('explore_notes_chance');
BEGIN
    SELECT d.player_id INTO v_who FROM player_dao d
    JOIN player_location l ON l.player_id = d.player_id
    LIMIT 1;

    IF v_who IS NULL THEN
        RAISE NOTICE 'nobody has crossed and is standing anywhere, so the roll '
                     'was not walked';
        RETURN;
    END IF;

    BEGIN
        FOR i IN 1..400 LOOP
            DELETE FROM player_cooldowns WHERE player_id = v_who;
            SELECT * INTO r FROM explore(v_who);
            IF r.material_code = 'ancient_venerable_notes' THEN
                v_hit := v_hit + 1;
            END IF;
        END LOOP;

        -- Generous bounds: this is a coin, not a clock. What it must not be is
        -- zero, or anything like the one-in-ninety 0570 shipped.
        IF v_hit < 400 * v_want * 0.4 THEN
            RAISE EXCEPTION
                'notes landed % times in 400 walks against a chance of % - '
                'that is the 0570 fault again', v_hit, v_want;
        END IF;
        RAISE NOTICE
            'notes landed % times in 400 walks (chance %, expected about %)',
            v_hit, v_want, round(400 * v_want);

        -- AND SOMEBODY WHO HAS NOT CROSSED STILL FINDS NONE.
        SELECT p.player_id INTO v_cold FROM players p
        JOIN player_location l ON l.player_id = p.player_id
        WHERE NOT EXISTS (SELECT 1 FROM player_dao d
                          WHERE d.player_id = p.player_id)
        LIMIT 1;

        IF v_cold IS NOT NULL THEN
            FOR i IN 1..300 LOOP
                DELETE FROM player_cooldowns WHERE player_id = v_cold;
                SELECT * INTO r FROM explore(v_cold);
                IF r.material_code = 'ancient_venerable_notes' THEN
                    v_none := v_none + 1;
                END IF;
            END LOOP;
            IF v_none > 0 THEN
                RAISE EXCEPTION
                    'somebody who has not crossed found notes % times', v_none;
            END IF;
            RAISE NOTICE
                'and none at all in 300 walks for somebody who has not crossed';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;
END
$probe$;
