-- 0419_the_servant_tables_index_the_keys_they_point_with
--
-- `test_every_foreign_key_column_is_indexed` sweeps the whole schema and found
-- four columns 0414 and 0415 added without one:
--
--     servant_tiers.rarity
--     servant_bonuses.effect_code
--     servants.bonus_kind
--     player_servants.realm_id
--
-- Three of those are small lookup tables that will never be big enough for a
-- planner to care, and the rule is worth keeping anyway - it is not about any
-- one of these four. An unindexed foreign key also makes the PARENT slow to
-- delete from, because every delete has to scan the child to prove nothing
-- points at the row, and `realms` and `gu_effects` are exactly the sort of
-- table somebody edits during a migration years from now.
--
-- 0388 and 0408 were both this same sweep catching the same omission. It is
-- an easy one to make and the test is the reason it never lasts.
--
-- Forward-only. Do not edit once applied.


CREATE INDEX servant_tiers_rarity_idx        ON servant_tiers (rarity);
CREATE INDEX servant_bonuses_effect_idx      ON servant_bonuses (effect_code);
CREATE INDEX servants_bonus_kind_idx         ON servants (bonus_kind);
CREATE INDEX player_servants_realm_idx       ON player_servants (realm_id);


DO $probe$
DECLARE
    v_bad TEXT;
BEGIN
    SELECT string_agg(format('%s.%s', c.conrelid::regclass, a.attname), ', ')
    INTO v_bad
    FROM pg_constraint c
    JOIN unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord) ON TRUE
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
    WHERE c.contype = 'f'
      AND c.conrelid::regclass::text LIKE '%servant%'
      AND NOT EXISTS (
          SELECT 1 FROM pg_index i
          WHERE i.indrelid = c.conrelid
            AND (i.indkey::smallint[])[0] = k.attnum);

    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these servant keys still point without an index: %',
            v_bad;
    END IF;

    RAISE NOTICE 'every servant foreign key is indexed';
END;
$probe$;
