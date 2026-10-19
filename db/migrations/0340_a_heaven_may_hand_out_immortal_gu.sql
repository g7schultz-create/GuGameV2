-- 0340_a_heaven_may_hand_out_immortal_gu
--
-- `gu_region_drop_respects_the_gate` refuses any Gu above
-- `gu_max_droppable_rank`, which is 5. Its own description says why, and says
-- what to do about it:
--
--     'The highest rank of Gu the world will hand over. Rank 6 is where a Gu
--      becomes Immortal; those are in the catalogue and are found nowhere
--      yet. Raise this to open them.'
--
-- Black Heaven is where they are found. But raising that one number opens
-- rank 8 Gu in the Central Continent as well, where a cultivator three days
-- old is gathering - and the gate was put there precisely so that could not
-- happen by accident.
--
-- SO THE GATE LEARNS WHERE IT IS STANDING. A region that anybody may walk
-- into still hands out nothing above `gu_max_droppable_rank`. A region with a
-- door on it - `regions.min_rank` above 1, which today means Black Heaven and
-- tomorrow the white heaven and the blessed lands - hands out up to
-- `gu_max_immortal_droppable_rank` instead.
--
-- That keeps the protection exactly where it was earning its keep and lifts
-- it exactly where the door already does the same job. The five mortal
-- regions are unchanged, and a new heaven needs one row in `regions` rather
-- than an argument about a global number.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('gu_max_immortal_droppable_rank', 8,
     'The highest rank of Gu a GATED region will hand over - one whose '
     'regions.min_rank is above 1, which is to say one a mortal cannot reach. '
     'Rank 6 and up are Immortal Gu, and a heaven is where they are found. '
     'The mortal world is still held to gu_max_droppable_rank.');


CREATE OR REPLACE FUNCTION gu_region_drop_respects_the_gate()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
DECLARE
    r    SMALLINT;
    gate SMALLINT;
    cap  NUMERIC;
BEGIN
    SELECT rank INTO r FROM gu_types WHERE gu_type_id = NEW.gu_type_id;
    SELECT min_rank INTO gate FROM regions WHERE code = NEW.region_code;

    -- Where it is standing decides what it may hand over. A door on the
    -- region is doing the same work this cap does, so behind one the cap is
    -- the immortal one.
    cap := CASE WHEN COALESCE(gate, 1) > 1
                THEN game_config_value('gu_max_immortal_droppable_rank')
                ELSE game_config_value('gu_max_droppable_rank') END;

    IF r > cap THEN
        RAISE EXCEPTION
            'rank % is above what % hands out (%); raise the cap for it first',
            r, NEW.region_code, cap
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$fn$;


-- ---------------------------------------------------------------------------
-- The mortal world is exactly as shut as it was
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    high BIGINT;
    saw  TEXT;
BEGIN
    SELECT gu_type_id INTO high FROM gu_types WHERE rank = 8 LIMIT 1;
    IF high IS NULL THEN
        RAISE NOTICE 'no rank 8 Gu to try the gate with';
        RETURN;
    END IF;

    -- An ungated region still refuses one.
    BEGIN
        INSERT INTO gu_region_drops (region_code, gu_type_id, weight)
        VALUES ('central', high, 1.0);
        RAISE EXCEPTION 'the Central Continent handed out a rank 8 Gu';
    EXCEPTION WHEN check_violation THEN
        saw := SQLERRM;
    END;
    IF saw NOT LIKE '%above what central hands out%' THEN
        RAISE EXCEPTION 'the refusal was not the gate: %', saw;
    END IF;

    -- And a gated one takes it. Rolled back either way - this is a probe,
    -- not a drop table.
    BEGIN
        INSERT INTO gu_region_drops (region_code, gu_type_id, weight)
        VALUES ('black_heaven', high, 1.0);
        DELETE FROM gu_region_drops
        WHERE region_code = 'black_heaven' AND gu_type_id = high;
    EXCEPTION WHEN check_violation THEN
        RAISE EXCEPTION 'Black Heaven refused an Immortal Gu: %', SQLERRM;
    END;

    RAISE NOTICE 'the mortal world still stops at rank %, a heaven at rank %',
        game_config_value('gu_max_droppable_rank'),
        game_config_value('gu_max_immortal_droppable_rank');
END;
$probe$;
