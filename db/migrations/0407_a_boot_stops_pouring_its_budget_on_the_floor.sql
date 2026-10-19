-- 0407_a_boot_stops_pouring_its_budget_on_the_floor
--
-- Two ceilings most of the server is already standing on.
--
-- EVASION. Boots spend 65 per cent of their budget on Evasion, which caps at
-- 0.40, and both minters clamp with `LEAST(ef.cap, ...)` and throw the rest
-- away at the moment of forging. Thirty-one boots are sitting at exactly
-- 0.4000 right now across seven owners, and six of the eight active
-- cultivators are hard capped - which means a better boot is worth nothing to
-- them, and the largest share of the slot is the part being discarded. The
-- rolls behind those thirty-one run from 0.5616 to 0.9120, so between a third
-- and more than half of each was never written down.
--
-- Evasion still caps at 0.40, and a boot still STORES 0.40. What changes is
-- where the overflow goes: into Sinew, at `equipment_dodge_to_sinew` points
-- per whole point of it. Boots make you hard to catch, and past the point
-- where that stops helping they make you strong instead.
--
-- CULTIVATION SPEED capped at 1.00, and a tier 8 mythic helm alone rolls 1.012
-- on its slot share - so the best helm in the game overflows by itself with
-- nothing else equipped. clearwest and sylvrime are both pinned at exactly
-- 1.000. Raised to 3.00, where `multi_hit` already sits.
--
-- No helm needs a backfill, and this is worth saying because it is not
-- obvious: no cultivation_rate row is STORED at the cap. Both of them reached
-- 1.000 by summing a Gu, a manual and a helm, and `player_stat` clamped the
-- total on the way out. Raising the ceiling releases them on its own.
--
-- HOW THE OVERFLOW IS CAUGHT. A rule table and a trigger, rather than surgery
-- on two large minting queries that build their effect rows quite differently.
-- Both minters stop clamping - not so a raw figure gets stored, but so the
-- TRIGGER can see the overflow before it is rounded off. The trigger then
-- applies exactly the clamp the minters used to, and routes what is over the
-- ceiling to the effect the rule names. The stored Evasion is unchanged; the
-- difference is that the remainder now lands somewhere instead of nowhere.
--
-- The clamp is also not the only guard, which is why moving it is safe: the
-- `player_equipment_stats` view sums a player's worn pieces under its own
-- `LEAST(ef.cap, sum(...))`, and `player_stat` clamps the whole stack again
-- over every source. Two readers already expected totals to exceed a cap -
-- the view even returns a `capped` flag saying so.
--
-- WHY THE MINTERS ALSO GAIN AN `ON CONFLICT`. The trigger inserts a second row
-- in the middle of the minter's own multi-row INSERT. Nothing mints
-- base_strength today - it is not an ore signature, a beast part or a slot
-- share - so the two can never collide, but that is an accident of content
-- rather than a property of the code. Give an ore a Sinew signature later and
-- forging it into boots would have been a primary key violation. A merge is
-- the right answer there anyway: two sources of one effect should add.
--
-- AND THE THIRTY-ONE THAT ALREADY EXIST. Their overflow was never recorded, so
-- it is reconstructed from what a boot of that tier and quality would have
-- rolled on its slot share. That is the SLOT portion only - an ore's signature
-- and a beast part can also pay into Evasion - so the backfill is deliberately
-- conservative and pays a little less than the piece really lost. Paying
-- nothing was the other option and it is worse.
--
-- ONE THING THIS MIGRATION CANNOT DO ALONE. base_strength is a FLAT stat -
-- points on a body, `is_base = TRUE` - and every screen that prints a piece's
-- effects renders `magnitude * 100` with a per cent sign after it. Ten points
-- of Sinew would read as "Sinew 1000%". That is fixed in the bot alongside
-- this, in forge.py, auction.py and trade.py, which until now had never been
-- handed a flat effect on a piece of equipment.
--
-- Forward-only. Do not edit once applied.


UPDATE gu_effects SET cap = 3.0000 WHERE code = 'cultivation_rate';


INSERT INTO game_config (key, value, description) VALUES
    ('equipment_dodge_to_sinew', 20,
     'Points of Sinew a boot pays for each whole point of Evasion it rolled past the 0.40 ceiling. At 20 the thirty-one capped boots pay between 3 and 10, which is worth wearing beside a Sinew Gu without replacing it, and a tier 8 mythic would pay 16 against a cap of 30.');


-- ---------------------------------------------------------------------------
-- What an effect does when the thing it was spent on is already full
-- ---------------------------------------------------------------------------

CREATE TABLE effect_overflow_rules (
    effect_code TEXT PRIMARY KEY REFERENCES gu_effects(code) ON DELETE CASCADE,
    spills_to   TEXT NOT NULL REFERENCES gu_effects(code) ON DELETE RESTRICT,
    rate        NUMERIC NOT NULL CHECK (rate > 0),
    CHECK (effect_code <> spills_to)
);

COMMENT ON TABLE effect_overflow_rules IS
    'Where a piece''s budget goes when the effect it was spent on is already at its ceiling. A table rather than a branch, so the next one is a row.';

INSERT INTO effect_overflow_rules (effect_code, spills_to, rate)
VALUES ('dodge', 'base_strength',
        game_config_value('equipment_dodge_to_sinew'));


CREATE FUNCTION equipment_effect_overflows()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_cap  NUMERIC;
    v_rule effect_overflow_rules%ROWTYPE;
    v_over NUMERIC;
    v_pays NUMERIC;
BEGIN
    SELECT ef.cap INTO v_cap FROM gu_effects ef WHERE ef.code = NEW.effect_code;
    IF v_cap IS NULL OR NEW.magnitude <= v_cap THEN
        RETURN NEW;
    END IF;

    SELECT * INTO v_rule FROM effect_overflow_rules r
    WHERE r.effect_code = NEW.effect_code;

    -- The clamp the minters used to apply, applied here instead so that the
    -- line above got to see what was being thrown away.
    v_over        := NEW.magnitude - v_cap;
    NEW.magnitude := v_cap;

    -- No rule means the old behaviour exactly: hold it at the ceiling and let
    -- the rest go. That is still right for most effects; only the ones
    -- somebody has made a decision about get a second home.
    IF v_rule.effect_code IS NULL THEN
        RETURN NEW;
    END IF;

    v_pays := round(v_over * v_rule.rate);
    IF v_pays <= 0 THEN
        RETURN NEW;
    END IF;

    -- This fires the trigger again for `spills_to`, which is why a rule may
    -- not point at an effect that has a rule of its own - the probe at the
    -- foot of this migration refuses that shape. With no rule of its own the
    -- second pass clamps at most and returns, so the recursion is one deep.
    INSERT INTO equipment_effects (equipment_id, effect_code, magnitude)
    VALUES (NEW.equipment_id, v_rule.spills_to, v_pays)
    ON CONFLICT (equipment_id, effect_code) DO UPDATE
        SET magnitude = equipment_effects.magnitude + EXCLUDED.magnitude;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION equipment_effect_overflows() IS
    'Clamps an equipment effect to its ceiling and, where a rule says so, pays the remainder into another stat rather than discarding it.';

CREATE TRIGGER equipment_effects_overflow
    BEFORE INSERT ON equipment_effects
    FOR EACH ROW EXECUTE FUNCTION equipment_effect_overflows();


-- ---------------------------------------------------------------------------
-- The minters stop rounding it off before the trigger can look
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    merge  TEXT;
BEGIN
    merge := concat(
'    -- Since 0407 the overflow trigger can add a row of its own part way', chr(10),
'    -- through this statement. Nothing mints base_strength today so the two', chr(10),
'    -- cannot collide, but that is a fact about the content rather than', chr(10),
'    -- about this query, and a forge that throws is a poor way to learn an', chr(10),
'    -- ore was given a Sinew signature. Two sources of one effect should add.', chr(10),
'    ON CONFLICT (equipment_id, effect_code) DO UPDATE', chr(10),
'        SET magnitude = equipment_effects.magnitude + EXCLUDED.magnitude;');

    -- ---- forge ------------------------------------------------------------
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'forge';
    IF body IS NULL THEN
        RAISE EXCEPTION 'forge is missing';
    END IF;

    anchor := '           LEAST(ef.cap, round(sum(c.magnitude), 4))';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'forge no longer clamps its effects where it did';
    END IF;
    body := replace(body, anchor, concat(
'           -- Unclamped since 0407, so that the trigger on equipment_effects', chr(10),
'           -- gets to see the overflow. It applies the same ceiling this line', chr(10),
'           -- used to, and decides where the remainder goes.', chr(10),
'           round(sum(c.magnitude), 4)'));

    anchor := concat(
'    GROUP BY c.effect_code, ef.cap', chr(10),
'    HAVING round(sum(c.magnitude), 4) > 0;');
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'forge no longer closes its effect insert where it did';
    END IF;
    body := replace(body, anchor, concat(
'    GROUP BY c.effect_code, ef.cap', chr(10),
'    HAVING round(sum(c.magnitude), 4) > 0', chr(10), merge));

    EXECUTE body;

    -- ---- dungeon_mint_equipment -------------------------------------------
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'dungeon_mint_equipment';
    IF body IS NULL THEN
        RAISE EXCEPTION 'dungeon_mint_equipment is missing';
    END IF;

    anchor := '    SELECT made, c.effect_code, LEAST(ef.cap, round(sum(c.magnitude), 4))';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION
            'dungeon_mint_equipment no longer clamps its effects where it did';
    END IF;
    body := replace(body, anchor, concat(
'    -- Unclamped since 0407, for the reason `forge` gives.', chr(10),
'    SELECT made, c.effect_code, round(sum(c.magnitude), 4)'));

    anchor := concat(
'    GROUP BY c.effect_code, ef.cap', chr(10),
'    HAVING round(sum(c.magnitude), 4) > 0;');
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION
            'dungeon_mint_equipment no longer closes its effect insert where it did';
    END IF;
    body := replace(body, anchor, concat(
'    GROUP BY c.effect_code, ef.cap', chr(10),
'    HAVING round(sum(c.magnitude), 4) > 0', chr(10), merge));

    EXECUTE body;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- And the boots that were already full get what they had been losing
-- ---------------------------------------------------------------------------

INSERT INTO equipment_effects (equipment_id, effect_code, magnitude)
SELECT ee.equipment_id, r.spills_to,
       round((t.base_magnitude * se.share * q.keep - ef.cap) * r.rate)
FROM equipment_effects ee
JOIN player_equipment e   ON e.equipment_id = ee.equipment_id
JOIN equipment_tiers t    ON t.tier = e.tier
JOIN equipment_qualities q ON q.rarity = e.quality
JOIN slot_effects se      ON se.slot = e.slot AND se.effect_code = ee.effect_code
JOIN gu_effects ef        ON ef.code = ee.effect_code
JOIN effect_overflow_rules r ON r.effect_code = ee.effect_code
WHERE ee.magnitude >= ef.cap
  AND round((t.base_magnitude * se.share * q.keep - ef.cap) * r.rate) > 0
ON CONFLICT (equipment_id, effect_code) DO UPDATE
    SET magnitude = equipment_effects.magnitude + EXCLUDED.magnitude;


-- ---------------------------------------------------------------------------
-- Nobody stands on a ceiling with the rest of their budget on the floor
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    r       RECORD;
    v_eq    BIGINT;
    v_dodge NUMERIC;
    v_sinew NUMERIC;
    v_want  NUMERIC;
BEGIN
    IF (SELECT cap FROM gu_effects WHERE code = 'cultivation_rate') <= 1.0 THEN
        RAISE EXCEPTION 'cultivation speed is still capped where it was';
    END IF;

    -- A rule may not point at an effect that has a rule of its own, or the
    -- trigger recurses without a floor.
    IF EXISTS (
        SELECT 1 FROM effect_overflow_rules a
        JOIN effect_overflow_rules b ON b.effect_code = a.spills_to
    ) THEN
        RAISE EXCEPTION 'an overflow rule spills into another one';
    END IF;

    -- Neither minter clamps any more, or the trigger never sees an overflow.
    IF EXISTS (
        SELECT 1 FROM pg_proc p
        WHERE p.pronamespace = 'public'::regnamespace
          AND p.proname IN ('forge', 'dungeon_mint_equipment')
          AND p.prosrc LIKE '%LEAST(ef.cap, round(sum(c.magnitude)%'
    ) THEN
        RAISE EXCEPTION 'a minter still clamps before the trigger can look';
    END IF;

    -- Both merge instead of colliding with the row the trigger adds.
    IF (SELECT count(*) FROM pg_proc p
        WHERE p.pronamespace = 'public'::regnamespace
          AND p.proname IN ('forge', 'dungeon_mint_equipment')
          AND p.prosrc LIKE '%ON CONFLICT (equipment_id, effect_code) DO UPDATE%'
       ) <> 2 THEN
        RAISE EXCEPTION 'a minter can still collide with its own trigger';
    END IF;

    -- ---- and the thing actually works, on a boot that is rolled back ------
    BEGIN
        INSERT INTO player_equipment
            (owner_id, name, slot, tier, quality, harmony, ore_code)
        SELECT e.owner_id, 'probe boot', 'boots', 8, 'legendary', 100, e.ore_code
        FROM player_equipment e LIMIT 1
        RETURNING equipment_id INTO v_eq;

        -- What a tier 8 legendary boot rolls on its slot share, unclamped.
        INSERT INTO equipment_effects (equipment_id, effect_code, magnitude)
        VALUES (v_eq, 'dodge', 0.9120);

        SELECT magnitude INTO v_dodge FROM equipment_effects
        WHERE equipment_id = v_eq AND effect_code = 'dodge';
        SELECT magnitude INTO v_sinew FROM equipment_effects
        WHERE equipment_id = v_eq AND effect_code = 'base_strength';
        v_want := round(0.5120 * game_config_value('equipment_dodge_to_sinew'));

        IF v_dodge IS DISTINCT FROM 0.4000 THEN
            RAISE EXCEPTION 'the trigger stored % rather than the ceiling', v_dodge;
        END IF;
        IF v_sinew IS DISTINCT FROM v_want THEN
            RAISE EXCEPTION 'the overflow paid % Sinew rather than %',
                COALESCE(v_sinew::text, 'nothing'), v_want;
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    RAISE NOTICE 'a capped boot pays % Sinew and keeps its 40 per cent', v_want;

    FOR r IN
        SELECT p.discord_name,
               round(player_stat(p.player_id, 'dodge'), 3) AS evasion,
               round(player_stat(p.player_id, 'base_strength')) AS sinew,
               round(player_stat(p.player_id, 'cultivation_rate'), 3) AS cult
        FROM players p WHERE p.deleted_at IS NULL
          AND player_stat(p.player_id, 'dodge') > 0
        ORDER BY player_stat(p.player_id, 'base_strength') DESC
    LOOP
        RAISE NOTICE '% evasion %  sinew %  cultivation %',
            rpad(r.discord_name, 16), r.evasion, r.sinew, r.cult;
    END LOOP;

    RAISE NOTICE '% boots now carry the Sinew they had been discarding',
        (SELECT count(*) FROM equipment_effects ee
         JOIN player_equipment e ON e.equipment_id = ee.equipment_id
         WHERE e.slot = 'boots' AND ee.effect_code = 'base_strength');
END;
$probe$;
