-- 0428_three_timers_that_told_everybody_they_were_ready
--
-- `/cooldowns` shows Boss Strike, Horde King and Technique Forge as Ready,
-- always, for everybody. Not sometimes wrong - never right, except by
-- coincidence when the thing happens to be ready anyway.
--
-- `cooldown_status` builds its list by deriving an action name from every
-- config key ending in `_cooldown_minutes`, then looking that name up in
-- `player_cooldowns`. It is a good idea and it is why nothing ships without a
-- line on this screen. What it assumes is that every such key is backed by a
-- row in that table, and it ends with:
--
--     COALESCE(c.ready_at <= now(), TRUE)
--
-- so an action with no row reads as ready. Three of the nine keys have no row,
-- for three different reasons:
--
--   TECHNIQUE FORGE has one, under another name. `forge_begin` calls
--     `claim_cooldown(player, 'forge_technique', ...)` while the config key is
--     `technique_forge_cooldown_minutes`, so the derivation looks for
--     `technique_forge` and the seven real rows are filed under
--     `forge_technique`. The words are the same and the order is not.
--
--   BOSS STRIKE keeps its stand-off in `boss_strikes.resumes_at`, per
--     encounter, because the burst belongs to the fight rather than the day.
--
--   HORDE KING keeps its in `horde_contributions.king_resumes_at`, per tide,
--     for the same reason.
--
-- The forge is fixed by making the two names agree rather than by teaching the
-- screen about the disagreement: the key is renamed and `forge_begin` reads the
-- new one. A mapping would have left the trap in place for the next person to
-- name a key one way and claim it another.
--
-- The other two genuinely live elsewhere, so `cooldown_status` learns to read
-- them - in the CASE it already keeps for `daily`, which is in this function
-- for exactly this reason. Both are counted only against a fight that is still
-- standing: a stand-off against a boss that is already dead is not a wait, and
-- "Ready" is the honest answer there.
--
-- AND THE CHECK THAT WOULD HAVE CAUGHT IT. The probe asserts every derived
-- action is backed by something - a `claim_cooldown` writer under that exact
-- name, or a branch in `cooldown_status` that names it. An action backed by
-- neither is one this screen is lying about, and it says which.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- The forge: one name, not two
-- ---------------------------------------------------------------------------

UPDATE game_config
SET key = 'forge_technique_cooldown_minutes',
    description = 'Minutes between sittings at the anvil. Named for the action `forge_begin` actually claims - `claim_cooldown(..., ''forge_technique'', ...)` - because `cooldown_status` derives the action from this key and the two disagreeing is what made /cooldowns call the forge ready for weeks.'
WHERE key = 'technique_forge_cooldown_minutes';


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'forge_begin' AND pronamespace = 'public'::regnamespace;
    IF body IS NULL THEN
        RAISE EXCEPTION 'forge_begin is missing';
    END IF;

    anchor := '        game_config_value(''technique_forge_cooldown_minutes''));';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'forge_begin no longer reads its cooldown where it did';
    END IF;

    EXECUTE replace(body, anchor,
'        game_config_value(''forge_technique_cooldown_minutes''));');
END;
$patch$;


-- ---------------------------------------------------------------------------
-- And the two that keep their clocks in their own fights
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'cooldown_status' AND pronamespace = 'public'::regnamespace;

    anchor := concat(
'                    ELSE (SELECT c.available_at FROM player_cooldowns c', chr(10),
'                          WHERE c.player_id = p_player_id AND c.action = t.action)');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'cooldown_status no longer falls back to player_cooldowns there';
    END IF;

    EXECUTE replace(body, anchor, concat(
'                    -- A burst belongs to the fight it was spent in, not to', chr(10),
'                    -- the day, so these two keep their clocks per encounter', chr(10),
'                    -- and per tide. Counted only while that fight is still', chr(10),
'                    -- standing: a stand-off against something already dead', chr(10),
'                    -- is not a wait, and Ready is the honest answer.', chr(10),
'                    WHEN t.action = ''boss_strike''', chr(10),
'                    THEN (SELECT max(bs.resumes_at)', chr(10),
'                          FROM boss_strikes bs', chr(10),
'                          JOIN boss_encounters be', chr(10),
'                            ON be.encounter_id = bs.encounter_id', chr(10),
'                          WHERE bs.player_id = p_player_id', chr(10),
'                            AND be.ended_at IS NULL)', chr(10),
'                    WHEN t.action = ''horde_king''', chr(10),
'                    THEN (SELECT max(hc.king_resumes_at)', chr(10),
'                          FROM horde_contributions hc', chr(10),
'                          WHERE hc.player_id = p_player_id', chr(10),
'                            AND EXISTS (SELECT 1 FROM horde_encounters he', chr(10),
'                                        WHERE he.horde_id = hc.horde_id', chr(10),
'                                          AND he.kind = ''king''', chr(10),
'                                          AND he.status = ''alive''))', chr(10),
anchor));
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Every line on that screen is backed by a clock somebody writes
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_bad TEXT;
    r     RECORD;
    v_src TEXT;
BEGIN
    SELECT prosrc INTO v_src FROM pg_proc
    WHERE proname = 'cooldown_status' AND pronamespace = 'public'::regnamespace;

    -- The heart of it: an action with a cooldown key that nothing has ever
    -- written a row for, and that the screen does not read specially, is an
    -- action this screen calls Ready forever.
    --
    -- Asked empirically rather than by reading source, because the six that
    -- work go through `begin_action`, which takes the action as a PARAMETER -
    -- `claim_cooldown(p_player_id, p_action, ...)` - so there is no literal
    -- name anywhere in the database to grep for. The first draft of this probe
    -- looked for one and accused all six.
    SELECT string_agg(x.action, ', ') INTO v_bad
    FROM (
        SELECT replace(g.key, '_cooldown_minutes', '') AS action
        FROM game_config g WHERE g.key LIKE '%\_cooldown\_minutes'
    ) x
    WHERE NOT EXISTS (SELECT 1 FROM player_cooldowns c
                      WHERE c.action = x.action)     -- somebody has claimed it
      AND v_src NOT LIKE '%''' || x.action || '''%'  -- or the screen reads it
      AND x.action <> 'daily';                       -- or it is the daily

    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION
            'these have a cooldown key and no clock behind them, so the screen calls them ready forever: %',
            v_bad;
    END IF;

    -- The forge's key and the name it is claimed under must be the same word.
    IF NOT EXISTS (SELECT 1 FROM game_config
                   WHERE key = 'forge_technique_cooldown_minutes') THEN
        RAISE EXCEPTION 'the forge cooldown key was not renamed';
    END IF;
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'forge_begin'
        AND pronamespace = 'public'::regnamespace)
       LIKE '%technique_forge_cooldown_minutes%' THEN
        RAISE EXCEPTION 'forge_begin still reads the old key';
    END IF;

    FOR r IN
        SELECT c.label, c.ready, c.ready_at
        FROM players p
        JOIN LATERAL cooldown_status(p.player_id) c ON TRUE
        WHERE p.deleted_at IS NULL
          AND c.action IN ('boss_strike', 'horde_king', 'forge_technique')
        ORDER BY p.player_id LIMIT 6
    LOOP
        RAISE NOTICE '% : ready=% at %', rpad(r.label, 18), r.ready,
            COALESCE(r.ready_at::text, 'no clock running');
    END LOOP;
END;
$probe$;
