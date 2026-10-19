-- 0335_essence_is_how_an_immortal_advances
--
-- 0334 built thirty-six realms above the Dao Realm and gave each of them an
-- essence to drink. This is the drinking, and the two doors that close behind
-- it.
--
-- ABSORBING. `absorb_essence` turns essence into cultivation at
-- `essence_cultivation_rate` per point of VALUE, so a Yellow Apricot is worth
-- exactly the 243,000,000 Dewberries it exchanges for. No tier is the
-- efficient one to farm - that is what makes them denominations rather than
-- a ladder of nine separate decisions.
--
-- IT ASKS THAT THE MORTAL LADDER BE FINISHED FIRST. Not out of tidiness: the
-- essences are tradeable the moment they exist, and without this a Qi
-- Condensation cultivator handed one Green Grape by a friend would leap most
-- of the mortal ladder in a single command. The door is the top of the mortal
-- ladder rather than rank 10, because a cultivator standing on Dao Realm -
-- Peak has nowhere else to spend it.
--
-- PILLS STOP AT THE DOOR, and they REFUSE rather than doing nothing. A pill
-- that was silently worth zero would be a trap: the pill is consumed, the
-- message says it worked, and the cultivation does not move. So a cultivation
-- pill taken by an immortal is turned away with its reason, and the pill stays
-- in the bag. Rate pills go the same way for the same reason - they bank
-- hours of passive cultivation, and an immortal has none to bank.
--
-- BECAUSE PASSIVE CULTIVATION IS ZERO ABOVE THE MORTAL LADDER. That is the
-- whole point of the tier: essence is not the fast way up, it is the only
-- way. `cultivation_per_hour` returning zero is what makes that true, and
-- everything that multiplies it - a Race's rate, a manual's bonus, the
-- cultivation_rate stat - multiplies zero and stays zero without any of them
-- needing to know about immortals.
--
-- NOTHING DROPS ESSENCE YET. That is 0334's note and it still stands: blessed
-- lands, the black and white heavens and rogue immortals are where it comes
-- from, and none of them exist. Until they do, this system is complete,
-- inert, and waiting - which is the right state for it to be in.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- Drinking it
-- ---------------------------------------------------------------------------

CREATE FUNCTION absorb_essence(
    p_player_id BIGINT, p_code TEXT, p_quantity BIGINT
)
RETURNS TABLE(
    essence     TEXT,
    emoji       TEXT,
    absorbed    BIGINT,
    unit_value  BIGINT,
    gained      BIGINT,
    spilled     BIGINT,
    cultivation BIGINT,
    reserve     BIGINT,
    ceiling     BIGINT,
    realm_name  TEXT,
    ready       BOOLEAN,
    held        BIGINT
)
LANGUAGE plpgsql
AS $fn$
DECLARE
    ess      RECORD;
    was      BIGINT;
    was_res  BIGINT;
    mortal   SMALLINT;
    standing SMALLINT;
    worth    NUMERIC;
    give     BIGINT;
BEGIN
    IF p_quantity IS NULL OR p_quantity < 1 THEN
        RAISE EXCEPTION 'absorb at least one' USING ERRCODE = 'check_violation';
    END IF;

    SELECT e.rank, e.unit_value, m.name AS nm, m.emoji AS face
    INTO ess
    FROM immortal_essences e
    JOIN materials m ON m.code = e.material_code
    WHERE e.material_code = p_code;

    IF NOT FOUND THEN
        RAISE EXCEPTION '% is not an immortal essence',
            COALESCE(material_name(p_code), p_code)
            USING ERRCODE = 'check_violation';
    END IF;

    -- The last rung of the mortal ladder, read rather than written down, so
    -- adding a mortal realm later cannot leave this pointing at the wrong one.
    SELECT max(realm_id) INTO mortal FROM realms WHERE rank <= 9;

    SELECT pc.realm_id, pc.cultivation, pc.reserve
    INTO standing, was, was_res
    FROM player_cultivation pc WHERE pc.player_id = p_player_id;

    IF standing IS NULL THEN
        RAISE EXCEPTION 'player % has no cultivation row', p_player_id;
    END IF;

    IF standing < mortal THEN
        RAISE EXCEPTION
            'immortal essence means nothing to a mortal aperture - finish the '
            'mortal ladder first'
            USING ERRCODE = 'check_violation';
    END IF;

    -- Refuses on its own if they are not holding that many.
    PERFORM spend_material(p_player_id, p_code, p_quantity);

    -- Worked out in numeric and then clamped. A double handful of Yellow
    -- Apricots multiplies past a bigint long before it multiplies past the
    -- top of the ladder, and an overflow here would abort the absorb with a
    -- database error after the essence had already been spent.
    worth := p_quantity::numeric * ess.unit_value
             * game_config_value('essence_cultivation_rate');
    give  := LEAST(worth, 9000000000000000000::numeric)::bigint;

    PERFORM apply_cultivation_xp(p_player_id, give);

    RETURN QUERY
    SELECT ess.nm, ess.face, p_quantity, ess.unit_value,
           pc.cultivation - was,
           GREATEST(0, give - (pc.cultivation - was)),
           pc.cultivation, pc.reserve,
           cultivation_ceiling(p_player_id), r.name,
           COALESCE((SELECT bool_and(g.met) FROM breakthrough_gate(p_player_id) g),
                    FALSE),
           COALESCE((SELECT pm.quantity FROM player_materials pm
                     WHERE pm.player_id = p_player_id
                       AND pm.material_code = p_code), 0)
    FROM player_cultivation pc
    JOIN realms r ON r.realm_id = pc.realm_id
    WHERE pc.player_id = p_player_id;
END;
$fn$;

COMMENT ON FUNCTION absorb_essence(BIGINT, TEXT, BIGINT) IS
    'Turn immortal essence into cultivation. The only way up, once the mortal ladder is done.';


-- ---------------------------------------------------------------------------
-- Sitting still stops working
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION cultivation_per_hour(p_player_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $fn$
    SELECT
        -- Above the mortal ladder there is no sitting still. Essence is not
        -- the fast way up there, it is the only way - and putting the zero
        -- here means every multiplier below it multiplies zero, so nothing
        -- that grants a cultivation rate has to learn about immortals.
        CASE WHEN r.rank > 9 THEN 0 ELSE 1 END
         * game_config_value('passive_cultivation_per_hour')
         * realm_cultivation_scale(r.rank)
         -- Additive, every one of them: a +5% Race and a +2% manual make
         -- +7%, never +7.1%.
         * (COALESCE(tr.cultivation_multiplier, 1)
            + COALESCE(mb.cultivation_rate_bonus, 0)
            + player_stat(p_player_id, 'cultivation_rate'))
         * (pc.aptitude / game_config_value('training_aptitude_baseline'))
         * CASE WHEN pc.focus_path IS NULL THEN 1
                ELSE game_config_value('path_cultivation_xp_rate') END
    FROM player_cultivation pc
    JOIN realms r ON r.realm_id = pc.realm_id
    LEFT JOIN player_trait_rates tr ON tr.player_id = pc.player_id
    LEFT JOIN player_manual_bonuses mb ON mb.player_id = pc.player_id
    WHERE pc.player_id = p_player_id;
$fn$;


-- ---------------------------------------------------------------------------
-- And the pill is turned away with its reason
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    anchor := concat(
'    -- What this body gets out of the pill, which is not always what is in it.', chr(10),
'    -- Scaled once on the local copy of the row, so all five branches below pay', chr(10),
'    -- the adjusted dose without any of them having to remember to - and every', chr(10),
'    -- one of them still measures what it actually banked, as 0058 insisted.');

    swap := concat(
'    -- Above the mortal ladder a pill has nothing to push against: passive', chr(10),
'    -- cultivation is zero there and essence is the only way up. Refused', chr(10),
'    -- rather than quietly worth nothing, because a pill that is eaten, says', chr(10),
'    -- it worked and moves no cultivation is worse than one that will not go', chr(10),
'    -- down. The pill stays in the bag.', chr(10),
'    IF it.kind IN (''cultivation'', ''cultivation_rate'')', chr(10),
'       AND (SELECT r.rank FROM player_cultivation pc', chr(10),
'            JOIN realms r ON r.realm_id = pc.realm_id', chr(10),
'            WHERE pc.player_id = p_player_id) > 9 THEN', chr(10),
'        RAISE EXCEPTION', chr(10),
'            ''a pill cannot move an immortal - absorb immortal essence instead''', chr(10),
'            USING ERRCODE = ''check_violation'';', chr(10),
'    END IF;', chr(10),
chr(10),
anchor);

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'take_pill';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'take_pill no longer scales its dose where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- A rank costs what the rule says, and the doors are shut
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    per_stage BIGINT := game_config_value('essence_per_stage')::bigint;
    rate      BIGINT := game_config_value('essence_cultivation_rate')::bigint;
    bad       TEXT;
BEGIN
    -- Every immortal stage costs exactly `essence_per_stage` of its own
    -- rank's essence. This is the claim the whole ladder is built on, checked
    -- against the rows rather than against the formula that wrote them.
    SELECT string_agg(t.name || ' wants ' || t.wants, ', ') INTO bad
    FROM (
        SELECT r.name,
               (r.cultivation_required - prev.cultivation_required)
               / (e.unit_value * rate) AS wants
        FROM realms r
        JOIN realms prev ON prev.realm_id = r.realm_id - 1
        JOIN immortal_essences e ON e.rank = r.rank
        WHERE r.rank >= 10
    ) t
    WHERE t.wants <> per_stage;

    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these stages do not cost % essence: %', per_stage, bad;
    END IF;

    -- Sitting still is worth nothing up there...
    IF EXISTS (
        SELECT 1 FROM player_cultivation pc
        JOIN realms r ON r.realm_id = pc.realm_id
        WHERE r.rank > 9 AND cultivation_per_hour(pc.player_id) <> 0
    ) THEN
        RAISE EXCEPTION 'an immortal is still cultivating by sitting still';
    END IF;

    -- ...and is untouched below it.
    IF EXISTS (
        SELECT 1 FROM player_cultivation pc
        JOIN realms r ON r.realm_id = pc.realm_id
        WHERE r.rank <= 9 AND cultivation_per_hour(pc.player_id) <= 0
          AND pc.aptitude > 0
    ) THEN
        RAISE EXCEPTION 'a mortal stopped cultivating';
    END IF;

    RAISE NOTICE
        'every immortal stage costs % of its own essence, at % cultivation a point',
        per_stage, rate;
END;
$probe$;
