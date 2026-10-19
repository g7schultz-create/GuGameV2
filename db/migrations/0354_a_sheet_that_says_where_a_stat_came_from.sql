-- 0354_a_sheet_that_says_where_a_stat_came_from
--
-- `player_stat` adds seven things together - worms, gear, body, root,
-- dwelling, manual and destiny - and then clamps the sum to the effect's cap.
-- Nothing in the game shows any of that. A cultivator can read what their Gu
-- give on /gu and what their gear gives on /gear, and nowhere can they read
-- what they actually HAVE, which is the number every fight is decided by.
--
-- That gap matters more after 0352 and 0353 than it did before. The whole
-- point of a wider aperture is choosing which stats to carry, and the whole
-- point of making abilities scarce is that a crit build is now assembled
-- rather than stumbled into. Both of those are decisions a player cannot make
-- without seeing the sheet - including, particularly, which of their stats
-- are already sitting on the ceiling, where the next worm of that kind is
-- worth nothing at all.
--
-- One function, seven columns of provenance, and `is_ability` carried through
-- from 0353 so the screen can separate the mechanics from the numbers the way
-- the drop tables now do.
--
-- Forward-only. Do not edit once applied.


CREATE FUNCTION player_stat_sheet(p_player_id BIGINT)
RETURNS TABLE(
    effect_code  TEXT,
    name         TEXT,
    emoji        TEXT,
    is_ability   BOOLEAN,
    total        NUMERIC,
    cap          NUMERIC,
    capped       BOOLEAN,
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
    SELECT f.code, f.name, f.emoji, f.is_ability,
           player_stat(p_player_id, f.code),
           f.cap,
           -- What the sources ADD UP to, against the ceiling - so a sheet can
           -- say 'you are wasting this' rather than only 'you are at the cap'.
           (gu_stat(p_player_id, f.code)
            + equipment_stat(p_player_id, f.code)
            + physique_stat(p_player_id, f.code)
            + root_stat(p_player_id, f.code)
            + dwelling_stat(p_player_id, f.code)
            + manual_stat(p_player_id, f.code)
            + destiny_stat(p_player_id, f.code)) > f.cap,
           gu_stat(p_player_id, f.code),
           equipment_stat(p_player_id, f.code),
           physique_stat(p_player_id, f.code),
           root_stat(p_player_id, f.code),
           dwelling_stat(p_player_id, f.code),
           manual_stat(p_player_id, f.code),
           destiny_stat(p_player_id, f.code)
    FROM gu_effects f
    WHERE f.is_live
    ORDER BY f.is_ability DESC, player_stat(p_player_id, f.code) DESC, f.name;
$$;

COMMENT ON FUNCTION player_stat_sheet(BIGINT) IS
    'Every live stat a cultivator has, what it totals, what it is capped at, and which of the seven sources it came from.';


-- ---------------------------------------------------------------------------
-- It agrees with the thing every fight actually reads
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    who BIGINT;
    bad TEXT;
    n   INTEGER;
BEGIN
    SELECT p.player_id INTO who FROM players p
    WHERE p.deleted_at IS NULL
      AND EXISTS (SELECT 1 FROM player_gu_equipped e WHERE e.player_id = p.player_id)
    ORDER BY (SELECT count(*) FROM player_gu_equipped e WHERE e.player_id = p.player_id) DESC
    LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'nobody is wearing a Gu to read a sheet off';
        RETURN;
    END IF;

    -- The sheet is not a second opinion. Every row must equal what
    -- `player_stat` returns, or a screen and a fight would disagree about the
    -- same number.
    SELECT string_agg(s.effect_code || ' (' || s.total || ' vs '
                      || player_stat(who, s.effect_code) || ')', ', ')
    INTO bad
    FROM player_stat_sheet(who) s
    WHERE s.total <> player_stat(who, s.effect_code);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'the sheet disagrees with player_stat: %', bad;
    END IF;

    -- And the parts add up to the whole, once the cap has had its say.
    SELECT string_agg(s.effect_code, ', ') INTO bad
    FROM player_stat_sheet(who) s
    WHERE LEAST(s.cap, s.from_gu + s.from_gear + s.from_body + s.from_root
                       + s.from_home + s.from_manual + s.from_destiny) <> s.total;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these do not add up: %', bad;
    END IF;

    SELECT count(*) INTO n FROM player_stat_sheet(who) WHERE total > 0;
    RAISE NOTICE 'the sheet reads % live stats for the best-equipped cultivator', n;
END;
$probe$;
