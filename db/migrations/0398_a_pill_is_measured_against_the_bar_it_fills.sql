-- 0398_a_pill_is_measured_against_the_bar_it_fills
--
-- There ARE qi pills. Qi Restoration, brewed like anything else, and six of
-- the eight cultivators here are carrying some. They are worth nothing:
--
--     m_i_y_u_k_i   tier 7 Qi Restoration      520 of an 8,192,000 aperture
--                                              0.006 per cent
--     pashu0        tier 7 Healing           1,275 of 7,654,084,706 health
--                                              0.00002 per cent
--     grafv         tier 6 Qi Restoration      196 of a 32,000 aperture
--                                              0.61 per cent
--
-- A pill's magnitude is a flat number rolled at the brew. Health and the
-- aperture are exponential in the realm. So a restorative pill is a rounding
-- error by the Dao Realm and an insult by Green Grape, and the only reason
-- nobody complained is that until 0397 qi never came back at all and the pills
-- were beside the point.
--
-- THIS GAME ALREADY SOLVED THIS ONCE. 0203 hit exactly this with cultivation
-- pills and wrote `pill_cultivation_worth`, whose comment is the whole
-- argument:
--
--     "A constant against an exponential ladder is noise by rank 5. Worth a
--      share of the stage being crossed instead, and never less than the flat
--      number, so low realms are untouched."
--
-- Healing and Qi never got the same treatment. `pill_restore_worth` is that
-- function's shape applied to the two bars it left behind - the same tier
-- weighting, the same harmony term, the same potency term, and the same
-- GREATEST against the flat number so that nothing at the shallow end moves.
--
-- WHAT A PILL IS WORTH NOW. At the top tier, well brewed: half an aperture, or
-- a third of a body. Which sits where it should against what else fills those
-- bars - `rest` returns 15 to 55 per cent of health on a five minute cooldown,
-- and 0397 returns a quarter of the aperture an hour. A pill is the thing you
-- spend when you do not want to wait, and now it is worth spending.
--
-- Scaled in ONE place. `take_pill` already re-rates `it.magnitude` on its
-- local copy of the row for `pill_potency`, with a comment explaining that all
-- five branches below then pay the adjusted dose without having to remember
-- to. This goes in beside it, so the healing branch, the qi branch and the
-- spill-to-the-beast that 0384 hung off the healing branch all follow without
-- being touched.
--
-- WHICH ALSO REPAIRS 0384. That migration sent what a healing pill could not
-- hold to the beast at your heel. It was correct and it was moving 1,275 of a
-- 7.6 billion point body. It now moves something.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('pill_qi_share', 0.50,
     'Share of the aperture a top-tier, well-brewed Qi Restoration pill returns. Lower tiers scale by base_magnitude against the top tier. Set against qi_regen_per_hour: a pill is worth about two hours of waiting, which is what a consumable should be.'),
    ('pill_healing_share', 0.35,
     'Share of maximum health a top-tier, well-brewed Healing pill returns. A little under what a rest gives at its best, because a rest is free and on a five minute cooldown while a pill was brewed.');


CREATE FUNCTION pill_restore_worth(
    p_player_id BIGINT, p_kind TEXT, p_tier SMALLINT,
    p_magnitude BIGINT, p_harmony SMALLINT, p_potency NUMERIC
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    -- `pill_cultivation_worth` for the two bars it did not cover. Same shape,
    -- deliberately: the grade, the brew and the pot all count exactly as they
    -- do there, and the flat number is a floor rather than the answer.
    SELECT GREATEST(
        -- Never worse than the number rolled at the brew, so nothing at the
        -- shallow end of the game moves at all.
        GREATEST(1, p_magnitude),
        round(
            CASE p_kind
                WHEN 'qi' THEN player_max_qi(p_player_id)
                                * game_config_value('pill_qi_share')
                WHEN 'healing' THEN COALESCE(
                                (SELECT pp.max_hp FROM player_physique pp
                                 WHERE pp.player_id = p_player_id), 0)
                                * game_config_value('pill_healing_share')
                ELSE 0
            END
            -- What the grade is worth, the same weighting 0195 set.
            * (SELECT pt.base_magnitude FROM pill_tiers pt WHERE pt.tier = p_tier)
            / (SELECT max(pt.base_magnitude) FROM pill_tiers pt)
            -- How well it was brewed.
            * COALESCE(p_harmony, game_config_value('pill_harmony_reference'))
            / game_config_value('pill_harmony_reference')
            -- And how much went into the pot, capped as it is there.
            * LEAST(
                game_config_value('pill_potency_cap'),
                COALESCE(p_potency,
                         (SELECT pt.potency_required FROM pill_tiers pt
                          WHERE pt.tier = p_tier))
                / GREATEST(1, (SELECT pt.potency_required FROM pill_tiers pt
                               WHERE pt.tier = p_tier))
              )
        )
    )::bigint;
$$;

COMMENT ON FUNCTION pill_restore_worth(BIGINT, TEXT, SMALLINT, BIGINT, SMALLINT, NUMERIC) IS
    'What a Healing or Qi Restoration pill is worth to this body: a share of the bar it fills, and never less than the flat number it was brewed with.';


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'take_pill';

    IF body IS NULL THEN
        RAISE EXCEPTION 'take_pill is missing';
    END IF;

    -- Straight after the potency re-rate, which already exists to spare every
    -- branch below from remembering to adjust its own dose.
    anchor := concat(
'    it.magnitude := GREATEST(1, round(', chr(10),
'        it.magnitude * (1 + player_stat(p_player_id, ''pill_potency''))));');

    swap := concat(anchor, chr(10),
'', chr(10),
'    -- And a restorative pill is measured against the bar it is filling, the', chr(10),
'    -- way 0203 measured a cultivation pill against the stage being crossed.', chr(10),
'    -- A flat number is 0.006 per cent of a Green Grape aperture. Done here', chr(10),
'    -- for the same reason the line above is: the healing branch, the qi', chr(10),
'    -- branch and the spill to the beast 0384 hung off the first all pay the', chr(10),
'    -- adjusted dose without one of them having to remember to.', chr(10),
'    IF it.kind IN (''healing'', ''qi'') THEN', chr(10),
'        it.magnitude := pill_restore_worth(p_player_id, it.kind, it.tier,', chr(10),
'                                           it.magnitude, it.harmony,', chr(10),
'                                           it.potency);', chr(10),
'    END IF;');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'take_pill no longer re-rates its dose where it did';
    END IF;

    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- A pill is worth taking at every realm, and worth no less than it was
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    r        RECORD;
    v_worst  NUMERIC := 1;
    v_flat   BIGINT;
    v_now    BIGINT;
BEGIN
    -- THE FLOOR: nobody's pill got weaker. This is the half that protects the
    -- shallow end, and it is the half a share-of-the-bar rewrite gets wrong.
    FOR r IN
        SELECT pl.pill_id, pl.owner_id, pl.kind, pl.tier, pl.magnitude,
               pl.harmony, pl.potency, p.discord_name
        FROM player_pills pl
        JOIN players p ON p.player_id = pl.owner_id
        WHERE pl.kind IN ('healing', 'qi')
    LOOP
        v_flat := GREATEST(1, round(r.magnitude));
        v_now  := pill_restore_worth(r.owner_id, r.kind, r.tier, r.magnitude,
                                     r.harmony, r.potency);
        IF v_now < v_flat THEN
            RAISE EXCEPTION
                '%''s tier % % pill got weaker: % against %',
                r.discord_name, r.tier, r.kind, v_now, v_flat;
        END IF;
    END LOOP;

    -- AND THE POINT: a pill is a real fraction of the bar it fills now.
    FOR r IN
        SELECT p.discord_name, rr.rank, pl.kind, pl.tier,
               pl.magnitude AS was,
               pill_restore_worth(pl.owner_id, pl.kind, pl.tier, pl.magnitude,
                                  pl.harmony, pl.potency) AS now_worth,
               CASE pl.kind WHEN 'qi' THEN player_max_qi(p.player_id)
                            ELSE pp.max_hp END AS bar
        FROM player_pills pl
        JOIN players p ON p.player_id = pl.owner_id
        JOIN player_physique pp ON pp.player_id = p.player_id
        JOIN player_cultivation pc ON pc.player_id = p.player_id
        JOIN realms rr ON rr.realm_id = pc.realm_id
        WHERE pl.kind IN ('healing', 'qi') AND rr.rank >= 7
        ORDER BY rr.rank DESC, pl.kind, pl.tier DESC
        LIMIT 8
    LOOP
        RAISE NOTICE '% (realm %) tier % % : % -> % of a % bar (%)',
            rpad(r.discord_name, 14), r.rank, r.tier, rpad(r.kind, 7),
            r.was, r.now_worth, r.bar,
            round(100.0 * r.now_worth / GREATEST(1, r.bar), 1) || ' per cent';
        v_worst := LEAST(v_worst, r.now_worth::numeric / GREATEST(1, r.bar));
    END LOOP;

    -- A top-tier pill at the deepest realm must not still be noise. This is
    -- the exact failure being repaired, and a probe that did not check it
    -- would pass against the old behaviour too.
    SELECT pill_restore_worth(p.player_id, 'qi', 7::smallint, 500::bigint,
                              game_config_value('pill_harmony_reference')::smallint,
                              NULL)
    INTO v_now
    FROM players p
    JOIN player_cultivation pc ON pc.player_id = p.player_id
    WHERE p.deleted_at IS NULL
    ORDER BY player_max_qi(p.player_id) DESC LIMIT 1;

    SELECT player_max_qi(p.player_id) INTO v_flat
    FROM players p JOIN player_cultivation pc ON pc.player_id = p.player_id
    WHERE p.deleted_at IS NULL
    ORDER BY player_max_qi(p.player_id) DESC LIMIT 1;

    IF v_flat > 0 AND v_now::numeric / v_flat < 0.10 THEN
        RAISE EXCEPTION
            'a top tier qi pill is still only % of the deepest aperture',
            round(100.0 * v_now / v_flat, 3);
    END IF;

    RAISE NOTICE
        'a top tier qi pill returns % of the deepest aperture in the game',
        round(100.0 * v_now / GREATEST(1, v_flat), 1) || ' per cent';
END;
$probe$;
