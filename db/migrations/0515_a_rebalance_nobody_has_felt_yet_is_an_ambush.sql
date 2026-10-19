-- 0515_a_rebalance_nobody_has_felt_yet_is_an_ambush
--
-- 0514 cut the low ranks of every Gu ladder. Nobody's body has noticed.
--
-- `base_hp` reaches a cultivator's HP through `player_physique.max_hp`, which
-- is a STORED column recomputed by `recompute_body_on_loadout_change` - and
-- that trigger fires on equipping and unequipping, not on a magnitude
-- changing underneath a loadout nobody has touched. So right now:
--
--     m_i_y_u_k_i.   stored 3.89e12   while player_stat('base_hp') reads 183.71
--     pashu0         stored 3.21e12                                    186.44
--     shinonn._.     stored 2.87e12                                     80.03
--
-- The numbers that decide a fight have moved and the bodies have not. Left
-- alone, each of these would drop the next time its owner swapped a single
-- worm - days later, for no reason they could see, and blamed on whatever
-- they happened to be doing at the time. A rebalance people have not felt yet
-- is not a kindness, it is an ambush with a delay on it.
--
-- So every body is recomputed now, in one place, where it can be measured and
-- reported. `apply_physique_xp(player, 0)` is the recompute - granting zero
-- experience is how the rest of the schema says "work the stats out again",
-- and 0070 and the /dev physique command both already use it that way.
--
-- AND `current_hp` IS CLAMPED. A cultivator standing at 3.89e12 of 3.89e12
-- whose maximum falls is otherwise left above their own ceiling, which 0032
-- had to fix once already for a different reason.
--
-- WHAT IT COSTS, measured before and after rather than predicted. The people
-- who lose most are the three who built the thing the inverted ladder
-- rewarded - 31 to 41 worms at an average rank near 1 - and that is the
-- rebalance working rather than a side effect of it.
--
-- Forward-only. Do not edit once applied.

CREATE TEMP TABLE body_before AS
SELECT pp.player_id, pp.max_hp, pp.current_hp, pp.defense, pp.strength
FROM player_physique pp;


-- Every cultivator, not only the ones wearing worms: the change reaches a
-- body through `player_stat`, which sums eight sources, and recomputing only
-- the Gu-wearers would leave the rest on a stale read of the same function.
DO $recompute$
DECLARE
    one RECORD;
    v_n INTEGER := 0;
BEGIN
    FOR one IN
        SELECT pp.player_id FROM player_physique pp
        JOIN players p ON p.player_id = pp.player_id
        WHERE p.deleted_at IS NULL
        ORDER BY pp.player_id
    LOOP
        PERFORM apply_physique_xp(one.player_id, 0);
        v_n := v_n + 1;
    END LOOP;
    RAISE NOTICE 'recomputed % bodies', v_n;
END;
$recompute$;


-- Nobody stands above their own ceiling.
UPDATE player_physique
SET current_hp = LEAST(current_hp, max_hp)
WHERE current_hp > max_hp;


-- ---------------------------------------------------------------------------
-- The bodies agree with the stats, and the bill is itemised
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_bad   TEXT;
    v_n     INTEGER;
    one     RECORD;
BEGIN
    -- 1. Nothing is left standing over its own maximum.
    SELECT count(*) INTO v_n FROM player_physique WHERE current_hp > max_hp;
    IF v_n > 0 THEN
        RAISE EXCEPTION '% cultivators are above their own ceiling', v_n;
    END IF;

    -- 2. Nobody was left at zero or below. A rebalance that deletes a body is
    -- a different thing from one that trims it.
    SELECT string_agg(p.discord_name, ', ') INTO v_bad
    FROM player_physique pp JOIN players p USING (player_id)
    WHERE p.deleted_at IS NULL AND (pp.max_hp <= 0 OR pp.current_hp <= 0);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these cultivators have no body left: %', v_bad;
    END IF;

    -- 3. The recompute LANDED, asserted by idempotence rather than by
    -- movement. My first attempt required every large body to have moved,
    -- which is simply false: pashu0's base_hp is 127.44 from gear and 0.00
    -- from worms, so a Gu rebalance should leave them exactly where they are.
    -- Running it twice and finding nothing changes proves the stored bodies
    -- now agree with the stat system, which is the staleness this removes.
    CREATE TEMP TABLE body_settled AS
    SELECT player_id, max_hp, defense, strength FROM player_physique;

    FOR one IN
        SELECT pp.player_id FROM player_physique pp
        JOIN players p ON p.player_id = pp.player_id
        WHERE p.deleted_at IS NULL
    LOOP
        PERFORM apply_physique_xp(one.player_id, 0);
    END LOOP;

    SELECT string_agg(p.discord_name, ', ') INTO v_bad
    FROM body_settled s
    JOIN player_physique pp ON pp.player_id = s.player_id
    JOIN players p ON p.player_id = s.player_id
    WHERE pp.max_hp <> s.max_hp OR pp.defense <> s.defense
       OR pp.strength <> s.strength;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION
            'a second recompute moved these again, so the first did not settle: %',
            v_bad;
    END IF;

    -- 4. THE BILL. Named per cultivator, loudly, because this is the part a
    -- player will notice and ask about.
    FOR one IN
        SELECT p.discord_name,
               b.max_hp AS was,
               pp.max_hp AS now_at,
               round(100.0 * (1 - pp.max_hp::NUMERIC / NULLIF(b.max_hp, 0)), 1) AS lost
        FROM body_before b
        JOIN player_physique pp ON pp.player_id = b.player_id
        JOIN players p ON p.player_id = b.player_id
        WHERE p.deleted_at IS NULL AND b.max_hp <> pp.max_hp
        ORDER BY b.max_hp DESC
        LIMIT 8
    LOOP
        RAISE NOTICE '% : % -> % (%%% of their body)',
            one.discord_name, one.was, one.now_at, one.lost;
    END LOOP;

    SELECT count(*) INTO v_n
    FROM body_before b
    JOIN player_physique pp ON pp.player_id = b.player_id
    WHERE pp.max_hp < b.max_hp;

    RAISE NOTICE '% cultivators lost body to the rebalance', v_n;
END;
$probe$;
