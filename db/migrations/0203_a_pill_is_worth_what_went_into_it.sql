-- 0203_a_pill_is_worth_what_went_into_it
--
-- 0195 gave a flat `cultivation` pill a share of the stage the drinker is
-- standing in, which fixed the real problem - a constant against an
-- exponential ladder - and introduced a smaller one. The share was 5% of the
-- gap for a grade 7, every single time. Two cultivators, one brewing at
-- harmony 150 out of a cauldron stuffed to six times the tier floor and one
-- scraping a grade 7 at harmony 76 with the bare 240 potency, got identical
-- pills. Nothing a brewer did to a cultivation pill mattered except reaching
-- the tier.
--
-- Now it is worth what went into it. Both of the numbers a brewer actually
-- moves are in the answer:
--
--     share = 5%  x  grade weight  x  harmony / 100  x  potency / tier floor
--
--     harmony 150, potency 1.0x floor   ->  7.5%
--     harmony 128, potency 1.6x floor   ->  6.4% ...
--     harmony  83, potency 1.4x floor   ->  5.8%
--     harmony  76, potency 1.0x floor   ->  3.8%
--
-- Both terms are continuous, and harmony already carries a random +/-4 from
-- `brew`, so two pots of the same herbs do not come out the same. That is the
-- point: 5.7% and 4.3% rather than 5% and 5%.
--
-- POTENCY HAD NOWHERE TO BE KEPT. `player_pills` never stored it - `brew`
-- computed the total, used it to pick the tier and the batch size, and threw
-- it away. So it is a column now, and `brew` writes it.
--
-- Existing pills are backfilled with their tier's floor potency, which is the
-- least they can possibly have been made with. That is the honest default: it
-- cannot overstate a pill nobody recorded, and at 1.0x the multiplier it is
-- exactly the old behaviour, so nothing already brewed gets worse.
--
-- The potency term is capped at 2x. A cauldron holding six times the floor
-- would otherwise make a grade 7 worth a third of a realm, and overshoot is
-- already paid for once in the batch size.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE player_pills ADD COLUMN potency NUMERIC;

COMMENT ON COLUMN player_pills.potency IS
    'The tier x quantity that went into the pot. NULL for pills brewed before '
    '0203; `pill_cultivation_value` reads the tier floor for those.';


INSERT INTO game_config (key, value, description) VALUES
    ('pill_potency_cap', 2.0,
     'Most a cultivation pill may be multiplied by for overshooting its tier '
     'floor. Overshoot is already paid once in the batch size, so this is the '
     'second helping and not the first.'),
    ('pill_harmony_reference', 100.0,
     'The harmony at which a pill is worth its nominal share. Below it a pill '
     'is worth less and above it more, continuously - it is the number a '
     'brewer is already trying to raise.');


-- Everything brewed before this had its potency thrown away. The tier floor is
-- the least it can have been, so that is what it is credited with.
UPDATE player_pills p
SET potency = (SELECT pt.potency_required FROM pill_tiers pt
               WHERE pt.tier = p.tier)
WHERE p.potency IS NULL;


CREATE FUNCTION pill_cultivation_worth(
    p_player_id BIGINT,
    p_tier      SMALLINT,
    p_magnitude BIGINT,
    p_harmony   SMALLINT,
    p_potency   NUMERIC
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
            -- What the grade is worth, unchanged from 0195.
            * (SELECT pt.base_magnitude FROM pill_tiers pt
               WHERE pt.tier = p_tier)
            / (SELECT max(pt.base_magnitude) FROM pill_tiers pt)
            -- How well it was brewed. Continuous, and carrying brew's own
            -- +/-4, so two pots of the same herbs differ.
            * COALESCE(p_harmony, game_config_value('pill_harmony_reference'))
            / game_config_value('pill_harmony_reference')
            -- How much went into the pot, against the least that would have
            -- reached this tier. Capped: overshoot already buys batch size.
            * LEAST(
                game_config_value('pill_potency_cap'),
                COALESCE(p_potency, (SELECT pt.potency_required FROM pill_tiers pt
                                     WHERE pt.tier = p_tier))
                / GREATEST(1, (SELECT pt.potency_required FROM pill_tiers pt
                               WHERE pt.tier = p_tier))
              )
        )
    )::bigint;
$$;

COMMENT ON FUNCTION pill_cultivation_worth(BIGINT, SMALLINT, BIGINT, SMALLINT, NUMERIC) IS
    'What one flat cultivation pill is worth to this drinker: a share of the '
    'stage they are crossing, scaled by the grade, the harmony it was brewed '
    'at and the potency that went into the pot.';


CREATE OR REPLACE FUNCTION pill_cultivation_value(
    p_player_id BIGINT, p_tier SMALLINT, p_magnitude BIGINT
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    -- Kept for the callers that have no pill in hand. A pill row knows its own
    -- harmony and potency and should use `pill_cultivation_worth` instead.
    SELECT pill_cultivation_worth(p_player_id, p_tier, p_magnitude,
                                  NULL::smallint, NULL::numeric);
$$;



DO $$
DECLARE
    src TEXT;
    old TEXT;
    new TEXT;
BEGIN
    -- `brew` computes the potency and throws it away. Keep it.
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc WHERE proname = 'brew';

    old := '    INSERT INTO player_pills
        (owner_id, name, tier, kind, path_code, magnitude, quantity, harmony)
    VALUES (p_player_id, made_name, grade, kind_code, lead_path, made_mag, batch, final_h)';
    new := '    INSERT INTO player_pills
        (owner_id, name, tier, kind, path_code, magnitude, quantity, harmony,
         potency)
    VALUES (p_player_id, made_name, grade, kind_code, lead_path, made_mag,
            batch, final_h, total)';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'brew no longer writes a pill the old way';
    END IF;
    EXECUTE replace(src, old, new);

    -- And `take_pill` should ask with the pill in its hand.
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc WHERE proname = 'take_pill';

    old := '        it.magnitude := pill_cultivation_value(p_player_id, it.tier,
                                               it.magnitude);';
    new := '        it.magnitude := pill_cultivation_worth(p_player_id, it.tier,
                                               it.magnitude, it.harmony,
                                               it.potency);';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'take_pill no longer values a cultivation pill the old way';
    END IF;
    EXECUTE replace(src, old, new);
END;
$$;


DO $$
DECLARE
    who   BIGINT;
    floor_p NUMERIC;
    good  BIGINT;
    poor  BIGINT;
    flat  BIGINT;
BEGIN
    SELECT p.player_id INTO who FROM players p
    JOIN player_cultivation pc ON pc.player_id = p.player_id
    JOIN realms r ON r.realm_id = pc.realm_id
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0
    ORDER BY r.rank DESC, p.player_id LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'no live cultivator; tests carry it';
        RETURN;
    END IF;

    SELECT pt.potency_required INTO floor_p FROM pill_tiers pt WHERE pt.tier = 7;

    good := pill_cultivation_worth(who, 7::smallint, 4056::bigint,
                                   150::smallint, floor_p * 1.6);
    poor := pill_cultivation_worth(who, 7::smallint, 4056::bigint,
                                   76::smallint, floor_p);
    flat := pill_cultivation_value(who, 7::smallint, 4056::bigint);

    -- A well-brewed pill must beat a bad one, or none of this was worth doing.
    IF good <= poor THEN
        RAISE EXCEPTION
            'a harmony 150 pill is worth % and a harmony 76 one %', good, poor;
    END IF;

    -- And the nominal pill - harmony 100, potency at the floor - must still be
    -- the 0195 number, so this is a spread around the old value and not a buff
    -- wearing a spread as a disguise.
    IF pill_cultivation_worth(who, 7::smallint, 4056::bigint,
                              100::smallint, floor_p) <> flat THEN
        RAISE EXCEPTION 'the nominal pill changed value';
    END IF;

    RAISE NOTICE 'grade 7 now ranges % (harmony 76) to % (harmony 150, 1.6x)',
        poor, good;
END;
$$;
