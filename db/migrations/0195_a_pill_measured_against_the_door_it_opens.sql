-- 0195_a_pill_measured_against_the_door_it_opens
--
-- A flat `cultivation` pill grants a fixed number. The realm ladder is
-- exponential. So the same grade 7 pill - 4,056 cultivation, 240 potency,
-- eighty-odd herbs - is worth this much of the stage it is trying to cross:
--
--     rank 1     640%   of a stage      one pill clears four stages
--     rank 2      67%
--     rank 3      17%
--     rank 4       3.3%                 30 pills per stage
--     rank 5       0.34%               295 pills
--     rank 6       0.066%            1,519 pills
--     rank 7       0.010%           10,417 pills
--     rank 9       0.0000%         490,055 pills
--
-- That is the complaint exactly: a hundred herbs for no measurable progress.
-- Not because the pill is weak - it is enormous at rank 1 - but because it is
-- a constant and everything it is measured against doubles every stage.
--
-- So measure it against the door. A `cultivation` pill is now worth a SHARE
-- OF THE STAGE THE DRINKER IS STANDING IN: grade 7 gives 5% of the gap to the
-- next realm, and the lower grades give their share of that in proportion to
-- `pill_tiers.base_magnitude`, which is already what a grade is worth.
--
--     rank 4:   4,056  ->     6,155        rank 7:  4,056 ->  2,112,473
--     rank 6:   4,056  ->   307,986        every rank: 20 pills per stage
--
-- NOBODY'S PILLS GET WORSE. The value is GREATEST(what it grants today, the
-- share) - so at rank 1, where 4,056 is already six stages' worth, nothing
-- changes at all. The buff lands exactly where the complaint was.
--
-- Nothing in a bag is edited. `take_pill` computes this when the pill is
-- swallowed, so the pills already brewed are worth whatever the drinker's
-- realm makes them worth - and worth more later if they are saved.
--
-- Overflow is not wasted: `apply_cultivation_xp` spills past the realm's door
-- into the reserve, and `breakthrough` draws it back out.
--
-- The insight pills have the same shape of problem against
-- `attainment_tiers.insight_required` and are NOT touched here. This is about
-- cultivation.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('pill_cultivation_share', 0.05,
     'Share of the gap to the next realm that a TOP GRADE flat cultivation '
     'pill grants. Lower grades give their proportion of it, by '
     'pill_tiers.base_magnitude. Twenty grade 7 pills is one stage at every '
     'realm, which is the point: the number stops falling behind the ladder.');


-- The stage the drinker is standing in, measured floor to floor. At the top
-- of the ladder there is no next door, so it borrows the last step - which is
-- the same thing 0176 does for the top pill grade's batch.
CREATE FUNCTION cultivation_stage_gap(p_player_id BIGINT)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT GREATEST(1, COALESCE(
        (SELECT above.cultivation_required - here.cultivation_required
         FROM player_cultivation pc
         JOIN realms here ON here.realm_id = pc.realm_id
         JOIN realms above ON above.realm_id = pc.realm_id + 1
         WHERE pc.player_id = p_player_id),
        (SELECT here.cultivation_required - below.cultivation_required
         FROM player_cultivation pc
         JOIN realms here ON here.realm_id = pc.realm_id
         JOIN realms below ON below.realm_id = pc.realm_id - 1
         WHERE pc.player_id = p_player_id),
        1
    ))::bigint;
$$;


-- What a flat cultivation pill is actually worth to THIS cultivator. The one
-- authority: `take_pill` reads it and nothing recomputes the rule elsewhere.
CREATE FUNCTION pill_cultivation_value(
    p_player_id BIGINT, p_tier SMALLINT, p_magnitude BIGINT
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT GREATEST(
        -- Never worse than the flat number it grants today.
        GREATEST(1, p_magnitude),
        round(
            cultivation_stage_gap(p_player_id)
            * game_config_value('pill_cultivation_share')
            * (SELECT pt.base_magnitude FROM pill_tiers pt
               WHERE pt.tier = p_tier)
            / (SELECT max(pt.base_magnitude) FROM pill_tiers pt)
        )
    )::bigint;
$$;

COMMENT ON FUNCTION pill_cultivation_value(BIGINT, SMALLINT, BIGINT) IS
    'A flat cultivation pill measured against the stage the drinker is in, '
    'never below what it grants today.';


-- Lifted and patched rather than retyped: `take_pill` is long and only one
-- line of it changes.
DO $$
DECLARE
    src TEXT;
    old TEXT := '    ELSIF it.kind = ''cultivation'' THEN
        SELECT pc.cultivation INTO before FROM player_cultivation pc
        WHERE pc.player_id = p_player_id;';
    new TEXT := '    ELSIF it.kind = ''cultivation'' THEN
        -- A constant against an exponential ladder is noise by rank 5. Worth
        -- a share of the stage being crossed instead, and never less than the
        -- flat number, so low realms are untouched.
        it.magnitude := pill_cultivation_value(p_player_id, it.tier,
                                               it.magnitude);
        SELECT pc.cultivation INTO before FROM player_cultivation pc
        WHERE pc.player_id = p_player_id;';
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'take_pill';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'take_pill no longer grants flat cultivation the old way';
    END IF;

    EXECUTE replace(src, old, new);
END;
$$;


DO $$
DECLARE
    thin  TEXT;
    who   BIGINT;
    pill  BIGINT;
    was   BIGINT;
    got   RECORD;
    share NUMERIC := game_config_value('pill_cultivation_share');
BEGIN
    -- A higher grade is always worth more. The proportion comes from
    -- base_magnitude, so this is really a check that that column climbs.
    SELECT string_agg(a.tier || ' >= ' || b.tier, ', ') INTO thin
    FROM pill_tiers a JOIN pill_tiers b ON b.tier = a.tier + 1
    WHERE a.base_magnitude >= b.base_magnitude;

    IF thin IS NOT NULL THEN
        RAISE EXCEPTION 'the grade ladder does not climb: %', thin;
    END IF;

    -- ---- the rule this migration exists for ------------------------------
    -- At EVERY realm, a top grade pill is worth a real share of the stage.
    -- Stated over the realms table so a realm added later has to answer it,
    -- and so the failure it fixes cannot come back by adding a steeper rank.
    FOR got IN
        SELECT r.realm_id, r.name, r.rank,
               COALESCE(above.cultivation_required - r.cultivation_required,
                        r.cultivation_required
                        - LAG(r.cultivation_required) OVER (ORDER BY r.realm_id)
               ) AS gap
        FROM realms r
        LEFT JOIN realms above ON above.realm_id = r.realm_id + 1
    LOOP
        CONTINUE WHEN got.gap IS NULL OR got.gap <= 0;

        IF round(got.gap * share) * 1.0 / got.gap < share - 0.001 THEN
            RAISE EXCEPTION
                'a top grade pill is only %%% of a stage at %',
                round(100.0 * round(got.gap * share) / got.gap, 4), got.name;
        END IF;
    END LOOP;

    -- ---- and it actually pays, on a live cultivator ----------------------
    SELECT p.player_id INTO who
    FROM players p
    JOIN player_cultivation pc ON pc.player_id = p.player_id
    JOIN realms r ON r.realm_id = pc.realm_id
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0
    ORDER BY r.rank DESC, p.player_id
    LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'no live cultivator; tests carry it';
        RETURN;
    END IF;

    BEGIN
        SELECT pc.cultivation INTO was FROM player_cultivation pc
        WHERE pc.player_id = who;

        INSERT INTO player_pills (owner_id, name, tier, kind, path_code,
                                  magnitude, quantity, harmony)
        VALUES (who, 'Probe Pill', 7, 'cultivation', 'space', 4056, 1, 150)
        RETURNING pill_id INTO pill;

        PERFORM take_pill(who, pill);

        IF (SELECT pc.cultivation FROM player_cultivation pc
            WHERE pc.player_id = who) - was <= 4056 THEN
            RAISE EXCEPTION
                'a grade 7 pill still grants no more than its flat number';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
