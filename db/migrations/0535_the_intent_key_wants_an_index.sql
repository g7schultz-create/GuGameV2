-- 0535_the_intent_key_wants_an_index
--
-- `test_every_foreign_key_column_is_indexed` caught 0534's new foreign key:
--
--     battle_combatants.intent_technique_id -> techniques(technique_id)
--
-- 0534 added an index to `battle_combatants`, but on `(battle_id) WHERE
-- intent_action IS NULL` - the one a duel reads to find out who is still
-- choosing. That is the right index for the question the duel asks and it is
-- not the one the invariant is about: an unindexed FK column means every
-- DELETE or key change on `techniques` has to sequentially scan
-- `battle_combatants`, which holds 13,724 rows and grows with every fight.
--
-- 0491 added two of these for the same reason. The test exists because that
-- kept being forgotten, and this time it was caught the same hour rather than
-- in a slow query a month later.
--
-- Forward-only. Do not edit once applied.

CREATE INDEX battle_combatants_intent_technique_idx
    ON battle_combatants (intent_technique_id);


DO $probe$
BEGIN
    -- Narrowly what THIS migration is for. The global invariant - every
    -- foreign key leads an index, with partial indexes counting only when the
    -- predicate is exactly `col IS NOT NULL` - lives in
    -- `test_every_foreign_key_column_is_indexed`, and that is where it stays.
    -- My first draft of this probe re-implemented the rule here, got the
    -- leading-column test wrong (it checked each FK column independently
    -- rather than the index's leading columns in order) and reported four
    -- false positives that the suite is perfectly happy with. One definition.
    IF NOT EXISTS (
        SELECT 1 FROM pg_index i
        JOIN pg_attribute a
          ON a.attrelid = i.indrelid AND a.attnum = (i.indkey::smallint[])[0]
        WHERE i.indrelid = 'battle_combatants'::regclass
          AND a.attname = 'intent_technique_id'
          AND i.indpred IS NULL
    ) THEN
        RAISE EXCEPTION 'intent_technique_id still leads no index';
    END IF;

    -- And 0534's own index survives, because it answers a different question
    -- - who in this duel is still choosing - and both are wanted.
    IF NOT EXISTS (SELECT 1 FROM pg_indexes
                   WHERE indexname = 'battle_combatants_waiting_idx') THEN
        RAISE EXCEPTION 'the who-is-still-choosing index went missing';
    END IF;
END;
$probe$;
