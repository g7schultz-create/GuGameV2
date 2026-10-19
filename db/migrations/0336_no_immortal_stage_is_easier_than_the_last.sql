-- 0336_no_immortal_stage_is_easier_than_the_last
--
-- 0334 priced every immortal stage at the same `essence_per_stage` of its own
-- rank's essence. It reads beautifully - one number, no table to look up -
-- and it walks straight into a rule this game has held since the mortal
-- ladder was rebuilt:
--
--     test_no_stage_is_easier_than_the_one_before_it
--     'Nascent Soul asked 152,852 for Mid and then 122,107 for Late, so
--      grinding through Mid was rewarded with a stage that took less work
--      than the one just finished.'
--
-- Twenty-five and twenty-five is not easier, but it is not harder either, and
-- the rule asks for harder. Dewberry Immortal - Mid cost 5,000,000,000 after
-- Early cost 5,000,000,000, and a ladder where climbing a rung tells you
-- nothing about the next one is exactly the flatness that rule was written to
-- stop.
--
-- So a stage is priced by which stage it is: 20, 25, 30, 35 of the rank's own
-- essence, a hundred and ten across a rank. Still one essence, still a number
-- a player can hold in their head, and now every rung is heavier than the one
-- under it.
--
-- THE RANK BOUNDARIES HOLD TOO, and that is the part worth checking rather
-- than assuming. Crossing from a rank into the next asks 20 of an essence
-- worth v' where the stage just finished asked 35 of one worth v, so the
-- boundary only climbs if v'/v > 1.75. The five lower essences step by three
-- and the top four by a hundred, so every boundary clears it - but it clears
-- by 1.71x at the narrowest, and a future hand that flattened the lower
-- essences to double would break the ladder in a way that is invisible from
-- the essence table alone. The probe below measures it.
--
-- `essence_per_stage` is retired into `immortal_stage_costs` rather than left
-- sitting in game_config meaning nothing.
--
-- Forward-only. Do not edit once applied.


CREATE TABLE immortal_stage_costs (
    stage         TEXT PRIMARY KEY,
    ord           SMALLINT NOT NULL UNIQUE,
    essence_units INTEGER NOT NULL,
    CONSTRAINT immortal_stage_costs_units_check CHECK (essence_units > 0)
);

COMMENT ON TABLE immortal_stage_costs IS
    'What each stage of an immortal rank costs, counted in that rank own essence.';

INSERT INTO immortal_stage_costs (stage, ord, essence_units) VALUES
    ('early',  1, 20),
    ('middle', 2, 25),
    ('late',   3, 30),
    ('peak',   4, 35);


-- The seam between the two ladders, which the first draft of this migration
-- got wrong and its own probe caught. Dao Realm - Peak is reached by a rung
-- costing 4,440,667,833, and twenty Dewberry at the old rate came to
-- 4,000,000,000 - a step DOWN at the most conspicuous crossing in the game,
-- the one where a mortal becomes an immortal. The rate goes up so the first
-- immortal stage outweighs the last mortal one.
UPDATE game_config
SET value = 250000000,
    description = 'Cultivation granted per point of essence VALUE absorbed. '
                  'Set so that twenty Dewberry - the cheapest immortal stage '
                  'there is - still costs more than the last rung of the '
                  'mortal ladder, which asks 4,440,667,833.'
WHERE key = 'essence_cultivation_rate';


UPDATE realms r
SET cultivation_required =
    (SELECT base.cultivation_required FROM realms base WHERE base.realm_id = 35)
    + game_config_value('essence_cultivation_rate')::bigint
      * (
          -- Every stage of every rank below this one, each at its own price.
          COALESCE((SELECT sum(lower.unit_value)
                           * (SELECT sum(essence_units) FROM immortal_stage_costs)
                    FROM immortal_essences lower WHERE lower.rank < r.rank), 0)
          -- Plus this rank's stages up to and including this one.
          + e.unit_value
            * (SELECT sum(c2.essence_units) FROM immortal_stage_costs c2
               WHERE c2.ord <= c.ord)
        )
FROM immortal_essences e, immortal_stage_costs c
WHERE e.rank = r.rank AND c.stage = r.stage AND r.rank >= 10;


DELETE FROM game_config WHERE key = 'essence_per_stage';


-- ---------------------------------------------------------------------------
-- Every rung heavier than the one below, boundaries included
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    bad      TEXT;
    deepest  BIGINT;
    narrowest NUMERIC;
BEGIN
    -- The rule that prompted this, applied to the whole ladder rather than
    -- only to the part this migration wrote.
    SELECT string_agg(t.name || ' costs ' || t.step || ' after ' || t.prev, ', ')
    INTO bad
    FROM (
        SELECT name,
               cultivation_required - LAG(cultivation_required) OVER (ORDER BY realm_id) AS step,
               LAG(cultivation_required) OVER (ORDER BY realm_id)
               - LAG(cultivation_required, 2) OVER (ORDER BY realm_id) AS prev
        FROM realms
    ) t
    WHERE t.step IS NOT NULL AND t.prev IS NOT NULL AND t.step <= t.prev;

    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these rungs are no heavier than the one below: %', bad;
    END IF;

    -- Each stage costs exactly what the schedule says, in its own essence.
    SELECT string_agg(t.name || ' wants ' || t.wants || ' not ' || t.should, ', ')
    INTO bad
    FROM (
        SELECT r.name,
               (r.cultivation_required - prev.cultivation_required)
               / (e.unit_value * game_config_value('essence_cultivation_rate')::bigint) AS wants,
               c.essence_units AS should
        FROM realms r
        JOIN realms prev ON prev.realm_id = r.realm_id - 1
        JOIN immortal_essences e ON e.rank = r.rank
        JOIN immortal_stage_costs c ON c.stage = r.stage
        WHERE r.rank >= 10
    ) t
    WHERE t.wants <> t.should;

    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these stages are not priced to the schedule: %', bad;
    END IF;

    -- How close the tightest rank boundary comes to going backwards. A rank
    -- whose essence is worth less than 1.75 times the one below it would make
    -- its first stage cheaper than the last stage of the rank before.
    SELECT min(hi.unit_value::numeric / lo.unit_value) INTO narrowest
    FROM immortal_essences hi
    JOIN immortal_essences lo ON lo.rank = hi.rank - 1;

    IF narrowest <= (SELECT max(essence_units) FROM immortal_stage_costs)::numeric
                    / (SELECT min(essence_units) FROM immortal_stage_costs) THEN
        RAISE EXCEPTION
            'the narrowest essence step is % and the stage schedule needs more than %',
            narrowest,
            (SELECT max(essence_units)::numeric / min(essence_units)
             FROM immortal_stage_costs);
    END IF;

    SELECT max(cultivation_required) INTO deepest FROM realms;
    IF deepest > 9000000000000000000 THEN
        RAISE EXCEPTION 'the deepest realm asks % and a bigint holds 9.2e18', deepest;
    END IF;

    RAISE NOTICE
        'every rung climbs; narrowest essence step %, deepest realm %',
        narrowest, deepest;
END;
$probe$;
