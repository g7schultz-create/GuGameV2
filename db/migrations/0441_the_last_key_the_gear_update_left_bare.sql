-- 0441_the_last_key_the_gear_update_left_bare
--
-- `smith_rarity_caps.rarity` points at `rarities` and has nothing leading on
-- it. 0440 fixed the two the gear update left on `player_equipment` and this
-- is the third, on a table 0437 created.
--
-- The table is seven rows and will never be large, so the index buys nothing
-- at this size. It is added anyway, because the rule is not "index the tables
-- that are big" - it is that a parent's delete should never scan a child, and
-- a table that is exempt today because it is small is a table somebody has to
-- re-examine later. `rarities` is a lookup nobody deletes from, which is
-- exactly the kind of assumption that stops being true quietly.
--
-- Forward-only. Do not edit once applied.


CREATE INDEX smith_rarity_caps_rarity_idx ON smith_rarity_caps (rarity);


DO $probe$
DECLARE
    v_bad TEXT;
BEGIN
    -- The same question the suite asks, so this migration cannot be the one
    -- that leaves another behind.
    SELECT string_agg(format('%s.%s', c.conrelid::regclass, a.attname), ', ')
    INTO v_bad
    FROM pg_constraint c
    JOIN LATERAL unnest(c.conkey) AS k (attnum) ON TRUE
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
    WHERE c.contype = 'f'
      AND c.conrelid IN ('smith_rarity_caps'::regclass,
                         'equipment_ranks'::regclass,
                         'equipment_quality_bands'::regclass,
                         'equipment_level_scales'::regclass,
                         'player_equipment'::regclass)
      AND NOT EXISTS (
          SELECT 1 FROM pg_index i
          WHERE i.indrelid = c.conrelid AND i.indkey[0] = a.attnum
            AND i.indpred IS NULL
      );
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION
            'the gear update still leaves these keys bare: %', v_bad;
    END IF;
END;
$probe$;
