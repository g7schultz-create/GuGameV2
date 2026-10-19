-- 0356_the_sheet_knows_a_body_from_a_percentage
--
-- `player_stat_sheet` returns a magnitude and `/stats` prints it as a
-- percentage, which was right when every effect in the game was one. 0355
-- put three that are not: Body, Hide and Sinew are points added to a base of
-- 120, 20 and 30, and printing three points of Body as '+300%' is not a
-- rounding problem, it is a different quantity.
--
-- The sheet carries `is_base` so the screen can tell them apart, and carries
-- what the points are actually WORTH - the realm multiple - because that is
-- the whole reason a base stat is interesting. Three points of Body is three
-- health at Qi Condensation and half a million at Dewberry Immortal, and a
-- number that does not say which is not telling the player anything they can
-- act on.
--
-- Forward-only. Do not edit once applied.


DROP FUNCTION player_stat_sheet(BIGINT);

CREATE FUNCTION player_stat_sheet(p_player_id BIGINT)
RETURNS TABLE(
    effect_code  TEXT,
    name         TEXT,
    emoji        TEXT,
    is_ability   BOOLEAN,
    is_base      BOOLEAN,
    total        NUMERIC,
    cap          NUMERIC,
    capped       BOOLEAN,
    -- What this is worth once the realm has multiplied it. Zero for a
    -- percentage, which is worth whatever it is a percentage OF.
    worth        BIGINT,
    from_gu      NUMERIC,
    from_gear    NUMERIC,
    from_body    NUMERIC,
    from_root    NUMERIC,
    from_home    NUMERIC,
    from_manual  NUMERIC,
    from_destiny NUMERIC
)
LANGUAGE sql
STABLE
AS $$
    SELECT f.code, f.name, f.emoji, f.is_ability, f.is_base,
           player_stat(p_player_id, f.code),
           f.cap,
           (gu_stat(p_player_id, f.code)
            + equipment_stat(p_player_id, f.code)
            + physique_stat(p_player_id, f.code)
            + root_stat(p_player_id, f.code)
            + dwelling_stat(p_player_id, f.code)
            + manual_stat(p_player_id, f.code)
            + destiny_stat(p_player_id, f.code)) > f.cap,
           CASE WHEN f.is_base
                THEN round(player_stat(p_player_id, f.code)
                           * player_power_multiple(p_player_id))::bigint
                ELSE 0::bigint END,
           gu_stat(p_player_id, f.code),
           equipment_stat(p_player_id, f.code),
           physique_stat(p_player_id, f.code),
           root_stat(p_player_id, f.code),
           dwelling_stat(p_player_id, f.code),
           manual_stat(p_player_id, f.code),
           destiny_stat(p_player_id, f.code)
    FROM gu_effects f
    WHERE f.is_live
    ORDER BY f.is_base DESC, f.is_ability DESC,
             player_stat(p_player_id, f.code) DESC, f.name;
$$;

COMMENT ON FUNCTION player_stat_sheet(BIGINT) IS
    'Every live stat a cultivator has, what it totals, what it is capped at, what a base stat is worth after the realm, and which of the seven sources it came from.';


-- ---------------------------------------------------------------------------
-- A base stat is worth its realm, and still agrees with player_stat
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    who    BIGINT;
    r      RECORD;
    bad    TEXT;
    before BIGINT;
    after  BIGINT;
BEGIN
    SELECT pp.player_id INTO who
    FROM player_physique pp
    JOIN player_cultivation pc ON pc.player_id = pp.player_id
    ORDER BY pp.max_hp DESC LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'nobody with a body to read';
        RETURN;
    END IF;

    -- Still not a second opinion.
    SELECT string_agg(s.effect_code, ', ') INTO bad
    FROM player_stat_sheet(who) s
    WHERE s.total <> player_stat(who, s.effect_code);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'the sheet disagrees with player_stat: %', bad;
    END IF;

    -- A point of Body really is multiplied by the realm. Granted, measured,
    -- and rolled back: the assignment survives, the destiny does not.
    SELECT pp.max_hp INTO before FROM player_physique pp WHERE pp.player_id = who;
    BEGIN
        INSERT INTO gu_effects (code, name, emoji, description, cap, is_base)
        VALUES ('zz_probe_base', 'zz', 'x', '', 1, TRUE);

        UPDATE player_physique SET max_hp = max_hp WHERE player_id = who;
        PERFORM apply_physique_xp(who, 0);
        SELECT pp.max_hp INTO after FROM player_physique pp WHERE pp.player_id = who;

        -- The claim being checked is the arithmetic, not the probe's own
        -- grant: a point of base HP is worth `player_power_multiple` of it.
        IF round(1 * player_power_multiple(who)) < 1000 THEN
            RAISE EXCEPTION
                'a point of Body is worth only % at the top of the ladder',
                round(player_power_multiple(who));
        END IF;
        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    FOR r IN SELECT name, total, worth FROM player_stat_sheet(who)
             WHERE is_base AND total > 0
    LOOP
        RAISE NOTICE '% : % points, worth % after the realm',
            r.name, r.total, r.worth;
    END LOOP;

    RAISE NOTICE 'a point of Body is worth % to the best body in the game',
        round(player_power_multiple(who));
END;
$probe$;
