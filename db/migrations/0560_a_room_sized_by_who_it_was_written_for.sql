-- 0560_a_room_sized_by_who_it_was_written_for
--
-- A Venerable cannot carry anybody, and the reason is arithmetic rather than
-- balance. `dungeon_rehearse` SUMS what every raider deals in a round, and
-- `dungeon_boss_pool` multiplies that sum by eight and the difficulty:
--
--     pool = (everyone's damage, added up) x 8 x hp_scale
--
-- So the stronger the party, the bigger the room. Measured on the rank 18
-- door at Hell, adding one deep cultivator to a solo run:
--
--     1 raider    pool 1.06e16
--     2 raiders   pool 1.41e17      <- thirteen times larger
--
-- The room grew to match the carrier exactly as it was designed to, which
-- makes "bring a friend who can clear it for you" impossible by construction.
-- Walking in beside somebody stronger does not help you; it builds a bigger
-- boss and hands you the same fight.
--
-- THE CAP IS THE TYPICAL RAIDER, NOT THE SUM. A room written for a given
-- realm should be the size that realm makes it, and a party of equals already
-- says what that size is - their median contribution is their individual
-- contribution. So:
--
--     cap = median(what one raider deals) x raiders x 8 x hp_scale
--
-- For a party of equals the median IS each of them, so cap = sum and nothing
-- changes - which is the whole point of using a median rather than a minimum.
-- For one Venerable among three friends the median is a friend, the room is
-- built for friends, and the Venerable removes it. That is the carry.
--
-- Applied as a CAP rather than a replacement: `LEAST(sum, cap)`. A party can
-- still make a room smaller than its own strength by bringing somebody weak,
-- and can never make one larger than the people in it would face alone. The
-- room never gets harder for having company.
--
-- Not restricted to the rank 18 door. The fault is in how every room is
-- sized, and a cap that fixed one door would leave the other eighteen with a
-- rule nobody could describe.
--
-- `dungeon_rehearse` is left exactly as it is - the sum is still the honest
-- reading of what a party does per round, and `dungeon_resolve_round` and the
-- difficulty preview both want it. What is new is a second reading beside it.


CREATE OR REPLACE FUNCTION dungeon_rehearse_typical(
    p_run_id BIGINT, p_species_id BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_def   BIGINT;
    v_n     INTEGER;
    v_move  BIGINT;
    one     RECORD;
    swung   RECORD;
    i       INTEGER;
    v_mine  BIGINT;
    v_each  BIGINT[] := '{}';
    v_med   NUMERIC;
BEGIN
    v_n := GREATEST(1, game_config_value('dungeon_rehearsal_rounds')::int);
    SELECT s.base_defense INTO v_def FROM creature_species s
    WHERE s.species_id = p_species_id;
    IF v_def IS NULL THEN
        RETURN 0;
    END IF;

    BEGIN
        -- Per RAIDER rather than per round, because a median needs the
        -- individual figures and `dungeon_rehearse` only ever kept the total.
        FOR one IN
            SELECT r.player_id, COALESCE(pp.max_hp, 1) AS max_hp
            FROM dungeon_raiders r
            LEFT JOIN player_physique pp ON pp.player_id = r.player_id
            WHERE r.run_id = p_run_id
            ORDER BY r.player_id
        LOOP
            v_move := dungeon_default_move(one.player_id);
            CONTINUE WHEN v_move IS NULL;

            v_mine := 0;
            FOR i IN 1..v_n LOOP
                -- Against an unkillable target, so no rehearsal ends early
                -- and drags the mean down. The same shape `dungeon_rehearse`
                -- uses, deliberately, so the two cannot disagree about what a
                -- round is worth.
                SELECT * INTO swung FROM player_swing(
                    one.player_id, v_move, p_species_id,
                    9223372036854775807::bigint, v_def,
                    GREATEST(1, one.max_hp), GREATEST(1, one.max_hp),
                    i, 'rehearsal', -p_run_id);
                v_mine := v_mine + GREATEST(0, swung.dealt);
            END LOOP;

            v_each := v_each || (v_mine / v_n);
        END LOOP;

        RAISE EXCEPTION 'rehearsal-done';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'rehearsal-done' THEN RAISE; END IF;
    END;

    IF array_length(v_each, 1) IS NULL THEN
        RETURN 0;
    END IF;

    SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY x)
    INTO v_med FROM unnest(v_each) AS x;

    -- The typical raider, counted once for each raider there is. A party of
    -- equals lands exactly on their own sum; a party carrying somebody lands
    -- on what the carried could have faced.
    RETURN GREATEST(0, round(v_med * array_length(v_each, 1)))::BIGINT;
END;
$fn$;

COMMENT ON FUNCTION dungeon_rehearse_typical(BIGINT, BIGINT) IS
    'What a room should be sized at: the MEDIAN raider''s damage per round times the number of raiders. Equal to `dungeon_rehearse` for a party of equals, and far below it when one cultivator is carrying the rest - which is what lets a Venerable clear a room for friends instead of inflating it. See 0560.';


DO $patch$
DECLARE
    src     TEXT;
    patched TEXT;
    anchor  TEXT :=
'    RETURN GREATEST(1, round(
        v_round
        * game_config_value(''dungeon_rounds_expected'')
        * (SELECT d.hp_scale FROM dungeon_difficulties d WHERE d.code = v_run.difficulty)
    ))::BIGINT;';
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'dungeon_boss_pool' AND pronamespace = 'public'::regnamespace;

    IF position(anchor IN src) = 0 THEN
        RAISE EXCEPTION 'dungeon_boss_pool does not size the room where it did';
    END IF;

    patched := replace(src, anchor,
'    -- CAPPED BY THE TYPICAL RAIDER. `v_round` is the SUM of what everybody
    -- deals, so a deep cultivator joining a weak party built a room to match
    -- themselves and handed their friends the same fight they could not win
    -- alone - thirteen times the pool, measured, for one extra raider. The
    -- median times the head count is what a party of equals would face, which
    -- for a party of equals is the same number. See 0560.
    RETURN GREATEST(1, round(
        LEAST(v_round, dungeon_rehearse_typical(p_run_id, v_run.species_id))
        * game_config_value(''dungeon_rounds_expected'')
        * (SELECT d.hp_scale FROM dungeon_difficulties d WHERE d.code = v_run.difficulty)
    ))::BIGINT;');

    IF patched = src THEN
        RAISE EXCEPTION 'the dungeon_boss_pool patch changed nothing';
    END IF;
    EXECUTE patched;
END
$patch$;
