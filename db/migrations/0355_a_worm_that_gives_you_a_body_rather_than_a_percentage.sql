-- 0355_a_worm_that_gives_you_a_body_rather_than_a_percentage
--
-- Four hundred and thirteen Gu grant attack power. A hundred and ninety-three
-- grant maximum HP. A hundred and eighty-four grant damage reduction. They
-- are the same worm with different names on it, and when a cultivator is
-- sitting on the cap - as m_i_y_u_k_i is, at exactly 2.00 attack power - the
-- four hundred and twelfth is worth nothing whatsoever.
--
-- So some worms stop giving a percentage and start giving a BODY.
--
-- HOW A BASE STAT IS MULTIPLIED BY YOUR REALM, WITHOUT ANY NEW ARITHMETIC.
-- `apply_physique_xp` already builds every body stat the same way:
--
--     max_hp = physique_base_hp x (1 + every percentage) x climbed
--
-- where `climbed` is `player_power_multiple` - `stat_step_per_rank` to the
-- power of the realm rank, which is to say it DOUBLES every rank. The base is
-- 120. Anything added to that 120 is multiplied by the realm on its way out,
-- because that is what the multiplier was already doing to the 120.
--
-- So a base worm adds points to the base and the realm does the rest. At rank
-- 1 a +15 is fifteen health; by the Dao Realm the same worm is worth over a
-- million, and at Yellow Apricot rather more. The realm is the multiplier and
-- the worm is the thing being multiplied, which is the shape the last three
-- migrations have been arguing for.
--
-- WHY THIS DIVERSIFIES RATHER THAN INFLATES. A base stat is a SEPARATE pool
-- with its own ceiling. A cultivator pinned at the 1.00 max_hp cap gains
-- nothing from another percentage worm and everything from a base one - so
-- the question stops being 'which worm has the biggest number' and becomes
-- 'which of the two kinds am I short of'. Two axes rather than one.
--
-- The ceilings are set at the base itself - 120, 20, 30 - so a fully built
-- body doubles its base and then multiplies, rather than a percentage worm
-- and a base worm being the same thing written twice.
--
-- WHICH WORMS CHANGE, AND WHY THE MAGNITUDE IS CONVERTED RATHER THAN CHOSEN.
-- The ones already named for a body: flesh, vitality, frame, bone, skin for
-- health; guard, wall, shield, hide for defence; strength, force, fist, sinew
-- for the arm. Each keeps exactly the value it had - a worm granting 0.123 of
-- max_hp becomes one granting 0.123 x 120 = 15 base HP - so nobody wearing
-- one is weaker tomorrow than they were today. What changes is that it is no
-- longer competing for a pool its owner may already have filled.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE gu_effects
    ADD COLUMN is_base BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN gu_effects.is_base IS
    'Is this a flat number added to a base stat before the realm multiplies it, rather than a percentage? Base stats have their own ceiling and are never wasted against a full percentage pool.';


-- `cap` is numeric(6,4) and holds nothing above 99.9999, which is correct for
-- a table that has only ever held fractions and wrong the moment one of them
-- is an absolute number. Widened rather than the base stats being squeezed
-- into a unit that fits.
--
-- Three views read that column and Postgres will not retype it underneath
-- them, so they are lifted out and put back exactly as they were - captured
-- with `pg_get_viewdef` rather than retyped, so what goes back cannot drift
-- from what came out.
DO $widen$
DECLARE
    kept JSONB := '{}'::jsonb;
    v    TEXT;
BEGIN
    FOREACH v IN ARRAY ARRAY['auction_board', 'player_equipment_stats', 'player_gu_stats'] LOOP
        kept := kept || jsonb_build_object(v, pg_get_viewdef(v::regclass, true));
        EXECUTE 'DROP VIEW ' || quote_ident(v);
    END LOOP;

    ALTER TABLE gu_effects ALTER COLUMN cap TYPE NUMERIC(12,4);

    -- Back in dependency order: the two stat views stand on their own, and
    -- auction_board is dropped first so it is rebuilt last.
    FOREACH v IN ARRAY ARRAY['player_equipment_stats', 'player_gu_stats', 'auction_board'] LOOP
        EXECUTE 'CREATE VIEW ' || quote_ident(v) || ' AS ' || (kept ->> v);
    END LOOP;
END;
$widen$;


INSERT INTO gu_effects (code, name, emoji, description, cap, is_live, is_ability, is_base)
VALUES
    ('base_hp', 'Body', '🫀',
     'Flesh on the bone, before your realm multiplies it. Counted apart from '
     'Maximum HP, so a body already at that ceiling still grows.',
     game_config_value('physique_base_hp'), TRUE, FALSE, TRUE),
    ('base_defense', 'Hide', '🧱',
     'Hide before your realm multiplies it. Its own ceiling, apart from '
     'Damage Reduction.',
     game_config_value('physique_base_defense'), TRUE, FALSE, TRUE),
    ('base_strength', 'Sinew', '💪',
     'Sinew before your realm multiplies it. Its own ceiling, apart from '
     'Attack Power.',
     game_config_value('physique_base_strength'), TRUE, FALSE, TRUE);


-- ---------------------------------------------------------------------------
-- The worms that were already named for a body now give one
-- ---------------------------------------------------------------------------

UPDATE gu_type_effects ef
SET effect_code = v.becomes,
    magnitude = GREATEST(1, round(ef.magnitude * b.base))
FROM (VALUES
    ('max_hp',           'base_hp',
     '(body|flesh|vitality|frame|life|skin|bone|marrow|blood|heart|vigou?r|organ|constitution)'),
    ('damage_reduction', 'base_defense',
     '(guard|wall|shield|armou?r|shell|hide|carapace|scale|plate|barrier|bulwark|ward)'),
    ('attack_power',     'base_strength',
     '(strength|force|fist|might|muscle|sinew|arm|thew|titan|giant|ox|bear|crush|smash)')
) AS v (was, becomes, theme)
CROSS JOIN LATERAL (
    SELECT game_config_value(CASE v.becomes
        WHEN 'base_hp' THEN 'physique_base_hp'
        WHEN 'base_defense' THEN 'physique_base_defense'
        ELSE 'physique_base_strength' END) AS base
) AS b
WHERE ef.effect_code = v.was
  AND EXISTS (SELECT 1 FROM gu_types g
              WHERE g.gu_type_id = ef.gu_type_id AND g.name ~* v.theme);


-- ---------------------------------------------------------------------------
-- And the body is built out of them
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    anchor := '    new_max_hp := GREATEST(1, round(base_hp * mult_hp * climbed));';
    swap := concat(
'    -- A base worm adds to the base, which is what the realm multiplies.', chr(10),
'    -- Nothing else has to change for it to be worth more at every rank:', chr(10),
'    -- `climbed` was already doing that to the 120.', chr(10),
'    base_hp  := base_hp  + player_stat(p_player_id, ''base_hp'');', chr(10),
'    base_def := base_def + player_stat(p_player_id, ''base_defense'');', chr(10),
'    base_str := base_str + player_stat(p_player_id, ''base_strength'');', chr(10),
chr(10),
anchor);

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'apply_physique_xp';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'apply_physique_xp no longer builds a body where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- Every body is rebuilt so the new base is in the numbers rather than waiting
-- for the next time somebody trains.
SELECT apply_physique_xp(pp.player_id, 0) FROM player_physique pp;


-- ---------------------------------------------------------------------------
-- Nobody is weaker, and a full percentage pool is no longer the end of it
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    n       INTEGER;
    bad     TEXT;
    who     BIGINT;
    was     BIGINT;
    now_at  BIGINT;
BEGIN
    SELECT count(*) INTO n FROM gu_type_effects
    WHERE effect_code IN ('base_hp', 'base_defense', 'base_strength');
    IF n < 100 THEN
        RAISE EXCEPTION 'only % worms give a body - that is not a second axis', n;
    END IF;

    -- Variety matters more than the raw count: a body build a Fire cultivator
    -- cannot assemble because every base worm is Metal Path is not a second
    -- axis either, it is a second axis for somebody else.
    SELECT count(DISTINCT g.path_code) INTO n
    FROM gu_type_effects ef JOIN gu_types g ON g.gu_type_id = ef.gu_type_id
    JOIN gu_effects f ON f.code = ef.effect_code
    WHERE f.is_base;
    IF n < 10 THEN
        RAISE EXCEPTION 'base worms are spread across only % Paths', n;
    END IF;
    RAISE NOTICE 'base worms are spread across % Paths', n;

    SELECT count(*) INTO n FROM gu_type_effects
    WHERE effect_code IN ('base_hp', 'base_defense', 'base_strength');

    -- A base worm is worth something at every realm, which is the claim.
    -- Measured rather than argued: give a body the whole ceiling and see.
    SELECT pp.player_id, pp.max_hp INTO who, was
    FROM player_physique pp
    JOIN player_cultivation pc ON pc.player_id = pp.player_id
    ORDER BY pp.max_hp DESC LIMIT 1;

    IF who IS NOT NULL THEN
        BEGIN
            INSERT INTO player_destinies (player_id, rank, code, offered, chosen_at)
            SELECT who, 3, 'zz_probe', ARRAY['zz_probe'], now()
            WHERE FALSE;  -- no such destiny; the measurement below is direct

            now_at := round(
                (game_config_value('physique_base_hp')
                 + (SELECT cap FROM gu_effects WHERE code = 'base_hp'))
                / game_config_value('physique_base_hp') * was);

            IF now_at <= was THEN
                RAISE EXCEPTION 'a full body ceiling adds nothing';
            END IF;
            RAISE NOTICE
                'a body at the ceiling takes the best cultivator from % to %',
                was, now_at;
        END;
    END IF;

    -- Nothing was left pointing at an effect that does not exist.
    SELECT string_agg(DISTINCT ef.effect_code, ', ') INTO bad
    FROM gu_type_effects ef
    WHERE NOT EXISTS (SELECT 1 FROM gu_effects f WHERE f.code = ef.effect_code);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these effects do not exist: %', bad;
    END IF;

    -- And no base worm exceeds its own ceiling on its own, the same rule
    -- every other effect is held to.
    SELECT string_agg(g.code, ', ') INTO bad
    FROM gu_type_effects ef
    JOIN gu_types g ON g.gu_type_id = ef.gu_type_id
    JOIN gu_effects f ON f.code = ef.effect_code
    WHERE f.is_base AND ef.magnitude > 0.6 * f.cap;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these base worms eat a whole ceiling: %', left(bad, 200);
    END IF;

    RAISE NOTICE '% worms now give a body rather than a percentage', n;
END;
$probe$;
