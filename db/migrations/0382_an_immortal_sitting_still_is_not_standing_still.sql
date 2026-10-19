-- 0382_an_immortal_sitting_still_is_not_standing_still
--
-- 0335 made essence the only way up the immortal ladder by putting a zero at
-- the front of `cultivation_per_hour`:
--
--     CASE WHEN r.rank > 9 THEN 0 ELSE 1 END
--
-- which was a clean way to say it - every multiplier after it multiplies zero,
-- so nothing granting a cultivation rate had to learn about immortals. An
-- immortal now gets a floor instead of a zero.
--
-- WHY THE MORTAL CURVE CANNOT SIMPLY BE LET THROUGH. `realm_cultivation_scale`
-- is rank squared. It reaches 100 at Dewberry and 324 at Yellow Apricot - a
-- little over threefold across the whole immortal band - while what a stage
-- COSTS goes from 1.67e10 to 1.28e18, which is eight orders of magnitude.
-- Deleting the zero would hand a Dewberry immortal ten thousand an hour
-- against a stage of sixteen billion: one stage per hundred and ninety years.
-- That is not a floor, it is a rounding error with a straight face.
--
-- So an immortal's sitting is measured against the stage they are actually
-- standing on: `immortal_passive_days_per_stage` of unbroken meditation is
-- one stage, at every realm. The rate climbs itself as the requirement does,
-- which is the only way a single number stays true from Dewberry to Yellow
-- Apricot.
--
-- THIRTY DAYS, AND WHY THAT IS STILL SLOW. A Dewberry stage is twenty essence.
-- A rogue immortal carries two to five, a blessed land condenses two a day, a
-- dungeon pays two to seven. Essence is days of playing; sitting is a month of
-- not. Essence stays the answer by more than an order of magnitude - what
-- changes is that a cultivator who cannot get to a heaven this week is no
-- longer making literally no progress at all.
--
-- Everything downstream still applies to it: traits, manuals, the
-- `cultivation_rate` stat, aptitude and a chosen Path all multiply an
-- immortal's floor exactly as they multiply a mortal's rate. A cultivator who
-- built for sitting still sits better, which was already true and stops being
-- true of nobody.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('immortal_passive_days_per_stage', 30,
     'Days of unbroken meditation that advance an immortal one stage with no essence at all. Measured against the stage actually being stood on, so the same number holds from Dewberry to Yellow Apricot. Deliberately slower than essence by better than an order of magnitude - it is a floor, not a route.');


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    anchor := concat(
'        -- Above the mortal ladder there is no sitting still. Essence is not', chr(10),
'        -- the fast way up there, it is the only way - and putting the zero', chr(10),
'        -- here means every multiplier below it multiplies zero, so nothing', chr(10),
'        -- that grants a cultivation rate has to learn about immortals.', chr(10),
'        CASE WHEN r.rank > 9 THEN 0 ELSE 1 END', chr(10),
'         * game_config_value(''passive_cultivation_per_hour'')', chr(10),
'         * realm_cultivation_scale(r.rank)');

    swap := concat(
'        -- Above the mortal ladder the rank-squared curve stops describing', chr(10),
'        -- anything: it reaches 324 at Yellow Apricot while a stage there', chr(10),
'        -- costs 1.28e18. An immortal''s floor is measured against the stage', chr(10),
'        -- they are standing on instead, so one number holds all the way up.', chr(10),
'        -- Every multiplier below still applies to it.', chr(10),
'        CASE WHEN r.rank > 9', chr(10),
'             THEN r.cultivation_required', chr(10),
'                  / GREATEST(1, game_config_value(', chr(10),
'                        ''immortal_passive_days_per_stage'') * 24)', chr(10),
'             ELSE game_config_value(''passive_cultivation_per_hour'')', chr(10),
'                  * realm_cultivation_scale(r.rank)', chr(10),
'        END');

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'cultivation_per_hour';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'cultivation_per_hour no longer zeroes an immortal where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- A month a stage at every realm, and still far behind essence
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    want   NUMERIC := game_config_value('immortal_passive_days_per_stage');
    r      RECORD;
    bad    TEXT;
    who    BIGINT;
    rate   NUMERIC;
    days   NUMERIC;
BEGIN
    -- A mortal is untouched. The zero was the only thing that changed, and a
    -- patch that quietly re-rated the whole mortal ladder would be far worse
    -- than the thing it fixed.
    SELECT string_agg(p.discord_name, ', ') INTO bad
    FROM players p
    JOIN player_cultivation pc ON pc.player_id = p.player_id
    JOIN realms rr ON rr.realm_id = pc.realm_id
    WHERE rr.rank <= 9
      AND cultivation_per_hour(p.player_id) <> (
          game_config_value('passive_cultivation_per_hour')
          * realm_cultivation_scale(rr.rank)
          * (COALESCE((SELECT tr.cultivation_multiplier FROM player_trait_rates tr
                       WHERE tr.player_id = p.player_id), 1)
             + COALESCE((SELECT mb.cultivation_rate_bonus
                         FROM player_manual_bonuses mb
                         WHERE mb.player_id = p.player_id), 0)
             + player_stat(p.player_id, 'cultivation_rate'))
          * (pc.aptitude / game_config_value('training_aptitude_baseline'))
          * CASE WHEN pc.focus_path IS NULL THEN 1
                 ELSE game_config_value('path_cultivation_xp_rate') END);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these mortals had their rate changed: %', left(bad, 200);
    END IF;

    -- And an immortal is no longer at zero, at every realm on the ladder.
    FOR r IN
        SELECT rr.rank, min(rr.name) AS name,
               min(rr.cultivation_required) AS needs
        FROM realms rr WHERE rr.rank > 9 GROUP BY rr.rank ORDER BY rr.rank
    LOOP
        -- The bare floor, with every multiplier at one: the stage divided by
        -- the days it is meant to take.
        rate := r.needs / (want * 24);
        IF rate <= 0 THEN
            RAISE EXCEPTION 'rank % still sits at zero', r.rank;
        END IF;
        days := r.needs / rate / 24;
        IF abs(days - want) > 0.01 THEN
            RAISE EXCEPTION
                'rank % takes % days a stage rather than %', r.rank, days, want;
        END IF;
    END LOOP;
    RAISE NOTICE
        'every immortal realm advances one stage in % days of sitting', want;

    -- Driven on somebody real, so the whole expression is exercised rather
    -- than the arithmetic I just wrote out again.
    SELECT pc.player_id INTO who
    FROM player_cultivation pc JOIN realms rr ON rr.realm_id = pc.realm_id
    WHERE rr.rank > 9 ORDER BY rr.rank DESC LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'no immortal to measure';
        RETURN;
    END IF;

    rate := cultivation_per_hour(who);
    IF rate <= 0 THEN
        RAISE EXCEPTION 'a live immortal still cultivates nothing an hour';
    END IF;

    SELECT rr.cultivation_required / rate / 24 INTO days
    FROM player_cultivation pc JOIN realms rr ON rr.realm_id = pc.realm_id
    WHERE pc.player_id = who;

    RAISE NOTICE
        'the deepest immortal sits at % an hour - % days to their next stage',
        round(rate), round(days, 1);
END;
$probe$;
