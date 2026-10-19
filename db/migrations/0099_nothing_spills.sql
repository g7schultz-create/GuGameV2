-- 0099_nothing_spills
--
-- Cultivation earned at the bottleneck is held instead of dropped.
--
-- 0044 made the ceiling real: cultivation stops at the next realm's door and
-- `apply_cultivation_xp` clamped everything above it away. That was correct
-- about the ceiling and wrong about the overflow - a player who idled a day
-- past their bottleneck was told "the bottleneck took the rest", which reads
-- as "the last day did not count". Every source was affected, because every
-- source goes through that one function: passive time, pills, meditation,
-- and whatever a command hands out.
--
-- So the overflow goes into a reserve on the cultivation row, and a
-- breakthrough pours it back in. The player loses nothing for arriving at the
-- door before they walk through it.
--
-- WHY THE RESERVE HAS A LID. Uncapped, the best play becomes NOT breaking
-- through: sit at the door for a month, bank a month, then cross three realms
-- in a minute. That turns a bottleneck into a savings account and the realm
-- ladder into a formality. The lid is one realm's worth - specifically the
-- gap the reserve will be poured into - so the most a full reserve can ever
-- buy is the very next crossing, and only for somebody who waited about as
-- long as that realm took to earn. Everything past a full reserve is still
-- lost, and the screens say so rather than quietly rounding it away.
--
-- ONE CHOKEPOINT. `apply_cultivation_xp` is the only thing in this schema
-- that writes `player_cultivation.cultivation`, which is why this is a change
-- to one function rather than to six callers. A reserve that only caught
-- passive time would have been a worse promise than no reserve: it would be
-- true on the screen the player checked and false on the one they did not.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- Where it is held
-- ---------------------------------------------------------------------------

ALTER TABLE player_cultivation
    ADD COLUMN reserve BIGINT NOT NULL DEFAULT 0 CHECK (reserve >= 0);

COMMENT ON COLUMN player_cultivation.reserve IS
    'Cultivation earned above the ceiling, held until a breakthrough makes room for it. Capped by cultivation_reserve_cap().';

INSERT INTO game_config (key, value, description) VALUES
    ('cultivation_reserve_share', 1.00,
     'How much the reserve holds, as a share of the realm gap it will be poured into. 1.00 is one whole realm''s worth.');


-- ---------------------------------------------------------------------------
-- How much it holds
-- ---------------------------------------------------------------------------
-- Measured against the gap the reserve is SPENT on rather than the one it was
-- earned at, because that is the gap it has to be judged against: a full
-- reserve should arrive at the next realm's door and no further.

CREATE FUNCTION cultivation_reserve_cap(p_player_id BIGINT)
RETURNS BIGINT
LANGUAGE sql STABLE
AS $$
    SELECT round(
        game_config_value('cultivation_reserve_share')
        * COALESCE(
            -- The gap after the one they are stuck at.
            (SELECT after.cultivation_required - next.cultivation_required
             FROM player_cultivation pc
             JOIN realms next  ON next.realm_id  = pc.realm_id + 1
             JOIN realms after ON after.realm_id = pc.realm_id + 2
             WHERE pc.player_id = p_player_id),
            -- One below the top of the ladder there is no gap after this one,
            -- and above the top there is no ceiling to overflow at all. Fall
            -- back to the gap in hand so the last crossing is not the one
            -- where the promise quietly stops applying.
            (SELECT next.cultivation_required - here.cultivation_required
             FROM player_cultivation pc
             JOIN realms here ON here.realm_id = pc.realm_id
             JOIN realms next ON next.realm_id = pc.realm_id + 1
             WHERE pc.player_id = p_player_id),
            0)
    )::bigint;
$$;

COMMENT ON FUNCTION cultivation_reserve_cap(BIGINT) IS
    'The lid on held-back cultivation: one realm gap by default, so a full reserve buys the next crossing and nothing beyond it.';


-- ---------------------------------------------------------------------------
-- apply_cultivation_xp, which now keeps what it cannot use
-- ---------------------------------------------------------------------------
-- Same signature, same return, six unchanged callers.

CREATE OR REPLACE FUNCTION apply_cultivation_xp(p_player_id BIGINT, p_xp BIGINT)
RETURNS SMALLINT
LANGUAGE plpgsql
AS $$
DECLARE
    ceiling  BIGINT := cultivation_ceiling(p_player_id);
    lid      BIGINT;
    held     BIGINT;
    have     BIGINT;
    room     BIGINT;
    taken    BIGINT;
    spilled  BIGINT;
    realm    SMALLINT;
BEGIN
    SELECT pc.cultivation, pc.reserve INTO have, held
    FROM player_cultivation pc
    WHERE pc.player_id = p_player_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'player % has no cultivation row', p_player_id;
    END IF;

    -- At the top of the ladder there is no door to wait at, so nothing is
    -- ever held back and the reserve never fills.
    IF ceiling IS NULL THEN
        UPDATE player_cultivation pc
        SET cultivation = pc.cultivation + p_xp
        WHERE pc.player_id = p_player_id
        RETURNING pc.realm_id INTO realm;
        RETURN realm;
    END IF;

    -- GREATEST guards a total that is somehow already past its own ceiling:
    -- a clamp must never take cultivation away.
    room    := GREATEST(0, ceiling - have);
    taken   := LEAST(GREATEST(p_xp, 0), room);
    spilled := GREATEST(p_xp, 0) - taken;

    lid := cultivation_reserve_cap(p_player_id);

    UPDATE player_cultivation pc
    SET cultivation = pc.cultivation + taken,
        -- Whatever will fit under the lid. Past that it really is gone, and
        -- a screen that showed a rising reserve here would be lying about a
        -- number the player can read back.
        reserve     = pc.reserve + LEAST(spilled, GREATEST(0, lid - held))
    WHERE pc.player_id = p_player_id
    RETURNING pc.realm_id INTO realm;

    RETURN realm;
END;
$$;

COMMENT ON FUNCTION apply_cultivation_xp(BIGINT, BIGINT) IS
    'Adds cultivation up to the next realm''s requirement; the overflow is held in the reserve rather than dropped. The realm itself moves only in breakthrough().';


-- ---------------------------------------------------------------------------
-- Pouring it back
-- ---------------------------------------------------------------------------

CREATE FUNCTION draw_from_reserve(p_player_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    ceiling BIGINT := cultivation_ceiling(p_player_id);
    have    BIGINT;
    held    BIGINT;
    drawn   BIGINT;
BEGIN
    SELECT pc.cultivation, pc.reserve INTO have, held
    FROM player_cultivation pc
    WHERE pc.player_id = p_player_id
    FOR UPDATE;

    IF NOT FOUND OR COALESCE(held, 0) = 0 THEN
        RETURN 0;
    END IF;

    -- No ceiling means the whole reserve fits, which is what reaching the top
    -- of the ladder is worth: everything ever held back arrives at once.
    drawn := CASE WHEN ceiling IS NULL THEN held
                  ELSE LEAST(held, GREATEST(0, ceiling - have)) END;

    UPDATE player_cultivation pc
    SET cultivation = pc.cultivation + drawn,
        reserve     = pc.reserve - drawn
    WHERE pc.player_id = p_player_id;

    RETURN drawn;
END;
$$;

COMMENT ON FUNCTION draw_from_reserve(BIGINT) IS
    'Pours held-back cultivation into the room a breakthrough just made. Anything still over the new ceiling stays held.';


-- ---------------------------------------------------------------------------
-- breakthrough, which now empties the reserve into the room it just made
-- ---------------------------------------------------------------------------
-- Lifted from 0086 with the draw added. The returned `cultivation` is read
-- back afterwards rather than reported from the row that was locked at the
-- top, because after a draw the value in hand is one the player would
-- otherwise see contradicted by their own profile a second later.

DROP FUNCTION breakthrough(BIGINT);

CREATE FUNCTION breakthrough(p_player_id BIGINT)
RETURNS TABLE (
    realm_before     SMALLINT,
    realm_after      SMALLINT,
    name_before      TEXT,
    name_after       TEXT,
    rank_before      SMALLINT,
    rank_after       SMALLINT,
    stage_after      TEXT,
    cultivation      BIGINT,
    next_ceiling     BIGINT,
    qi_capacity      BIGINT,
    essence_capacity BIGINT,
    gu_capacity      SMALLINT,
    aperture_gained  SMALLINT,
    techniques_freed INTEGER,
    tempering_gained BIGINT,
    body_levels      SMALLINT,
    founded_stat     TEXT,
    founded_by       NUMERIC,
    jade_gained      BIGINT,
    reserve_drawn    BIGINT,
    reserve_left     BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    cult      player_cultivation%ROWTYPE;
    was       realms%ROWTYPE;
    becomes   realms%ROWTYPE;
    tempering BIGINT := 0;
    body_was  SMALLINT;
    body_now  SMALLINT;
    founding  NUMERIC := 0;
    weakest   TEXT;
    jade      BIGINT := 0;
    drawn     BIGINT := 0;
    held      BIGINT := 0;
    now_at    BIGINT;
BEGIN
    SELECT * INTO cult FROM player_cultivation
    WHERE player_id = p_player_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'player % has no cultivation row', p_player_id;
    END IF;

    SELECT * INTO was FROM realms WHERE realm_id = cult.realm_id;
    SELECT * INTO becomes FROM realms WHERE realm_id = cult.realm_id + 1;

    IF becomes.realm_id IS NULL THEN
        RAISE EXCEPTION 'there is nothing above % in this world', was.name
            USING ERRCODE = 'check_violation';
    END IF;

    IF cult.cultivation < becomes.cultivation_required THEN
        RAISE EXCEPTION
            'you hold % of the % needed to break into %',
            cult.cultivation, becomes.cultivation_required, becomes.name
            USING ERRCODE = 'check_violation';
    END IF;

    -- The tribulation goes here: a roll before this line, and an outcome
    -- column on the way out. Everything below is what surviving one is worth.
    UPDATE player_cultivation pc
    SET realm_id = becomes.realm_id
    WHERE pc.player_id = p_player_id;

    -- The ceiling has just moved, so whatever was waiting behind the old one
    -- goes in now. This is the entire point of the reserve, and it happens
    -- before anything below reads a cultivation total.
    drawn := draw_from_reserve(p_player_id);

    SELECT pc.cultivation, pc.reserve INTO now_at, held
    FROM player_cultivation pc WHERE pc.player_id = p_player_id;

    -- A body that grows on the crossing itself. Measured in body levels
    -- because that is the currency the promise is written in - "foundation
    -- stats rise permanently" is what a body level IS.
    SELECT pp.body_level INTO body_was
    FROM player_physique pp WHERE pp.player_id = p_player_id;

    tempering := round(player_stat(p_player_id, 'realm_tempering')
                       * game_config_value('physique_xp_per_level'));

    -- Whichever pillar is currently lowest, and only that one. Read BEFORE
    -- the grant, so a body does not measure itself against the growth it is
    -- about to receive.
    founding := player_stat(p_player_id, 'realm_foundation');
    IF founding > 0 THEN
        weakest := weakest_foundation(p_player_id);
        INSERT INTO player_foundation_bonuses (player_id, stat, bonus)
        VALUES (p_player_id, weakest, founding)
        ON CONFLICT (player_id, stat) DO UPDATE
            SET bonus = player_foundation_bonuses.bonus + EXCLUDED.bonus;
    END IF;

    -- The one faucet a player can plan around: twenty-six crossings, known
    -- in advance, and worth the same every time.
    jade := game_config_value('jade_per_realm');
    IF jade > 0 THEN
        PERFORM grant_jade(p_player_id, jade, 'breakthrough');
    END IF;

    -- Unconditional, and zero XP is a no-op that still recomputes: the
    -- founding above has to reach the stored stats before this function
    -- reports what the body became.
    PERFORM apply_physique_xp(p_player_id, tempering);

    SELECT pp.body_level INTO body_now
    FROM player_physique pp WHERE pp.player_id = p_player_id;

    RETURN QUERY
    SELECT was.realm_id, becomes.realm_id,
           was.name, becomes.name,
           was.rank, becomes.rank, becomes.stage,
           now_at,
           (SELECT after.cultivation_required FROM realms after
            WHERE after.realm_id = becomes.realm_id + 1),
           becomes.qi_capacity, becomes.essence_capacity,
           becomes.gu_capacity,
           (becomes.gu_capacity - was.gu_capacity)::smallint,
           (SELECT count(*)::integer FROM techniques t
            WHERE t.created_by IS NULL
              AND t.rank > was.rank AND t.rank <= becomes.rank),
           tempering,
           COALESCE(body_now - body_was, 0)::smallint,
           weakest,
           founding,
           jade,
           drawn,
           held;
END;
$$;

COMMENT ON FUNCTION breakthrough(BIGINT) IS
    'Takes the next realm and pours the reserve into the room it makes. The only thing that moves realm_id - which is what leaves room for a tribulation to stand in the way of it.';


-- ---------------------------------------------------------------------------
-- settle_passive_cultivation, which reports what was held rather than lost
-- ---------------------------------------------------------------------------
-- Lifted from 0066. The only changes are the reserve: read before, read
-- after, reported as its own column. The gain column keeps meaning exactly
-- what it meant - cultivation that actually landed - because a card that
-- folded the two together would be telling a player at the bottleneck that
-- they were making progress they cannot yet spend.

DROP FUNCTION settle_passive_cultivation(BIGINT);

CREATE FUNCTION settle_passive_cultivation(p_player_id BIGINT)
RETURNS TABLE (
    hours              NUMERIC,
    capped             BOOLEAN,
    cultivation_gained BIGINT,
    cultivation_stored BIGINT,
    physique_gained    BIGINT,
    insight_gained     BIGINT,
    hp_restored        BIGINT,
    focus_path         TEXT,
    realm_before       SMALLINT,
    realm_after        SMALLINT,
    level_before       SMALLINT,
    level_after        SMALLINT,
    tier_before        SMALLINT,
    tier_after         SMALLINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    cult          player_cultivation%ROWTYPE;
    rates         player_trait_rates%ROWTYPE;
    baseline      NUMERIC := game_config_value('training_aptitude_baseline');
    cap_hours     NUMERIC := game_config_value('passive_cap_hours');
    manual_cult   NUMERIC := 0;
    manual_phys   NUMERIC := 0;
    elapsed       NUMERIC;
    paid          NUMERIC;
    was_capped    BOOLEAN;
    cult_offered  BIGINT;
    cult_gain     BIGINT;
    cult_before   BIGINT;
    res_before    BIGINT;
    res_after     BIGINT;
    cult_stored   BIGINT;
    cult_after    BIGINT;
    phys_gain     BIGINT;
    insight_gain  BIGINT := 0;
    hp_gain       BIGINT := 0;
    hp_before     BIGINT;
    hp_after      BIGINT;
    r_before      SMALLINT;
    r_after       SMALLINT;
    l_before      SMALLINT;
    l_after       SMALLINT;
    t_before      SMALLINT;
    t_after       SMALLINT;
    cult_boost    NUMERIC := 0;
    cult_hours    NUMERIC := 0;
    att_boost     NUMERIC := 0;
    att_hours     NUMERIC := 0;
BEGIN
    SELECT * INTO cult FROM player_cultivation
    WHERE player_id = p_player_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'player % has no cultivation row', p_player_id;
    END IF;

    elapsed    := EXTRACT(EPOCH FROM (now() - cult.last_tick_at)) / 3600.0;
    was_capped := elapsed > cap_hours;
    paid       := LEAST(elapsed, cap_hours);

    SELECT * INTO rates FROM player_trait_rates WHERE player_id = p_player_id;

    -- A boost is hours, not a clock. Nothing in this game ticks, so a pill
    -- that "lasts twelve hours" would have had to invent one - and would then
    -- have burned those hours while nobody was cultivating. These are spent
    -- only by time that is actually settled, so an hour bought is an hour had.
    SELECT b.magnitude, LEAST(paid, b.hours_left) INTO cult_boost, cult_hours
    FROM player_boosts b
    WHERE b.player_id = p_player_id AND b.kind = 'cultivation_rate';

    SELECT b.magnitude, LEAST(paid, b.hours_left) INTO att_boost, att_hours
    FROM player_boosts b
    WHERE b.player_id = p_player_id AND b.kind = 'attainment_rate';

    cult_boost := COALESCE(cult_boost, 0);
    cult_hours := COALESCE(cult_hours, 0);
    att_boost  := COALESCE(att_boost, 0);
    att_hours  := COALESCE(att_hours, 0);

    SELECT b.cultivation_rate_bonus, b.physique_rate_bonus
    INTO manual_cult, manual_phys
    FROM player_manual_bonuses b WHERE b.player_id = p_player_id;
    manual_cult := COALESCE(manual_cult, 0) + player_stat(p_player_id, 'cultivation_rate');
    manual_phys := COALESCE(manual_phys, 0);

    SELECT pc.realm_id, pc.cultivation, pc.reserve
    INTO r_before, cult_before, res_before
    FROM player_cultivation pc WHERE pc.player_id = p_player_id;
    SELECT pp.body_level INTO l_before FROM player_physique pp WHERE pp.player_id = p_player_id;
    SELECT COALESCE(a.tier, 0) INTO t_before
    FROM (SELECT 1) _
    LEFT JOIN player_path_attainment a
        ON a.player_id = p_player_id AND a.path_code = cult.focus_path;

    cult_offered := round(
        (paid + cult_boost * cult_hours)
        * game_config_value('passive_cultivation_per_hour')
        * (COALESCE(rates.cultivation_multiplier, 1) + manual_cult)
        * (cult.aptitude / baseline)
        * CASE WHEN cult.focus_path IS NULL THEN 1
               ELSE game_config_value('path_cultivation_xp_rate') END
    );

    phys_gain := round(
        paid
        * game_config_value('passive_physique_per_hour')
        * (COALESCE(rates.physique_multiplier, 1) + manual_phys)
    );

    IF cult.focus_path IS NOT NULL THEN
        insight_gain := round(
            (paid + att_boost * att_hours)
            * game_config_value('passive_insight_per_hour')
            * player_attainment_rate(p_player_id, cult.focus_path)
        );
    END IF;

    r_after := apply_cultivation_xp(p_player_id, cult_offered);
    l_after := apply_physique_xp(p_player_id, phys_gain);

    -- What was actually banked, not what was offered. The bottleneck can
    -- refuse most of it, and a card that reports the offer is a card that lies.
    SELECT pc.cultivation, pc.reserve INTO cult_after, res_after
    FROM player_cultivation pc WHERE pc.player_id = p_player_id;
    cult_gain   := GREATEST(0, cult_after - cult_before);
    -- Measured, not calculated. What the reserve took is whatever
    -- it is now holding that it was not holding before - so a full
    -- reserve reports the zero it actually stored.
    cult_stored := GREATEST(0, res_after - res_before);

    SELECT pp.current_hp INTO hp_before
    FROM player_physique pp WHERE pp.player_id = p_player_id;

    UPDATE player_physique pp
    SET current_hp = least(pp.max_hp,
                           pp.current_hp + floor(paid * 60 * pp.regeneration)::bigint)
    WHERE pp.player_id = p_player_id
    RETURNING pp.current_hp INTO hp_after;

    hp_gain := GREATEST(0, COALESCE(hp_after, 0) - COALESCE(hp_before, 0));

    IF cult.focus_path IS NOT NULL THEN
        t_after := grant_path_insight(
            p_player_id, cult.focus_path, insight_gain, round(paid * 3600)::bigint, 0
        );
    ELSE
        t_after := t_before;
    END IF;

    -- Swept away FIRST, then spent. `hours_left > 0` is a CHECK, and it is
    -- the right one - a boost row with nothing left in it is not a state
    -- worth having - so the exhausted rows have to go before anything tries
    -- to write a zero into them.
    DELETE FROM player_boosts b
    WHERE b.player_id = p_player_id
      AND ((b.kind = 'cultivation_rate' AND b.hours_left <= cult_hours)
        OR (b.kind = 'attainment_rate'  AND b.hours_left <= att_hours));

    UPDATE player_boosts b SET hours_left = b.hours_left - cult_hours
    WHERE b.player_id = p_player_id AND b.kind = 'cultivation_rate';
    UPDATE player_boosts b SET hours_left = b.hours_left - att_hours
    WHERE b.player_id = p_player_id AND b.kind = 'attainment_rate';

    UPDATE player_cultivation
    SET last_tick_at = last_tick_at + make_interval(secs => paid * 3600)
    WHERE player_id = p_player_id;

    RETURN QUERY SELECT
        round(paid, 4), was_capped,
        cult_gain, cult_stored, phys_gain, insight_gain, COALESCE(hp_gain, 0), cult.focus_path,
        r_before, r_after, l_before, l_after, t_before, t_after;
END;
$$;
