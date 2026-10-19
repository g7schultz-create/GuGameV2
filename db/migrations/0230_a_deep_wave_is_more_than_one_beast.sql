-- 0230_a_deep_wave_is_more_than_one_beast
--
-- 0229 gave the tide two lanes drawing on one pool, and priced them
-- differently without meaning to.
--
-- Measured on a live rank 3 tide: a seventeen wave gauntlet run felled sixteen
-- bodies for 49,412 contribution - about 3,088 per beast taken out of the
-- tide. A world beast in the channel carries 11,340 health and stands for
-- twelve beasts: about 945 per beast, split among everybody who turned up.
-- Three and a quarter times the pay for the lane you can run alone, which
-- would have emptied the channel of people inside one tide.
--
-- The distortion is not the reward, it is the counting. A wave seventeen beast
-- carries five times what a beast of that tide is worth, because each wave is
-- 18% harder than the last - and it was still coming off `beasts_total` as
-- one. So a deep run was cutting through five beasts and being charged for
-- one.
--
-- SO A WAVE IS WORTH WHAT IT WEIGHS, the same rule 0229 wrote for the channel:
-- a body stands for as many beasts of the tide as it is actually made of.
-- Early waves are one. Wave seventeen is five. The lanes come out within reach
-- of each other, the gauntlet still pays better for being the harder walk, and
-- a deep run empties the sea faster - which is the correct incentive, because
-- emptying the sea is what brings the King out.
--
-- AND A PACK PAYS A PACK BOUNTY. `horde_slay_bounty` is the reward for the
-- finishing blow, and it was flat - the same for the last hit on a straggler
-- as on a twelve-beast world boss. The blow that drops something a channel
-- spent ten minutes on is worth more than that.
--
-- Forward-only. Do not edit once applied.


CREATE FUNCTION horde_gauntlet_worth(p_wave INTEGER)
RETURNS SMALLINT
LANGUAGE sql STABLE
AS $$
    SELECT GREATEST(1, round(
        game_config_value('horde_gauntlet_start')
        * power(game_config_value('horde_gauntlet_step'),
                GREATEST(0, p_wave - 1))))::smallint;
$$;

COMMENT ON FUNCTION horde_gauntlet_worth(INTEGER) IS
    'How many beasts of the tide one gauntlet wave stands for - the same health multiple the wave is built at, so the pool is charged what was actually cut through.';


-- The gauntlet charges the sea what it cut.
DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'horde_gauntlet_fight';

    old := '        UPDATE beast_hordes h
        SET beasts_slain = h.beasts_slain + 1
        WHERE h.horde_id = run.horde_id;';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'horde_gauntlet_fight no longer counts a wave the old way';
    END IF;

    EXECUTE replace(src, old,
        '        -- One body, but as many beasts as it was built out of. A wave
        -- seventeen beast is five of them, and the pool is charged five.
        UPDATE beast_hordes h
        SET beasts_slain = h.beasts_slain + horde_gauntlet_worth(was_wave)
        WHERE h.horde_id = run.horde_id;');
END;
$$;


-- And the channel pays a pack bounty for a pack.
DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc WHERE proname = 'horde_strike';

    old := '        paid := round(game_config_value(''horde_slay_bounty'')
                      * GREATEST(1, met.species_rank))::bigint;';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'horde_strike no longer pays the finisher the old way';
    END IF;

    EXECUTE replace(src, old,
        '        -- Times what it stood for: the last blow on a twelve beast pack is
        -- not the same as the last blow on a straggler.
        paid := round(game_config_value(''horde_slay_bounty'')
                      * GREATEST(1, met.species_rank)
                      * met.worth)::bigint;');
END;
$$;


DO $$
DECLARE
    tide  BIGINT;
    who   BIGINT;
    live  BIGINT;
    shall SMALLINT;
    deep  SMALLINT;
BEGIN
    SELECT h.horde_id INTO live FROM beast_hordes h
    WHERE h.status IN ('fighting', 'king') LIMIT 1;

    -- Somebody who can actually swing: the gauntlet refuses a cultivator with
    -- no technique, which is right for the game and useless for a probe.
    SELECT p.player_id INTO who FROM players p
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0
      AND dungeon_default_move(p.player_id) IS NOT NULL
      AND EXISTS (SELECT 1 FROM player_physique pp WHERE pp.player_id = p.player_id)
    LIMIT 1;
    IF who IS NULL THEN
        RAISE NOTICE 'nobody who can swing; the tests carry it';
        RETURN;
    END IF;

    BEGIN
        -- An early wave is one beast and a deep one is several. If those were
        -- ever equal the whole point of this migration would be gone.
        shall := horde_gauntlet_worth(1);
        deep  := horde_gauntlet_worth(17);

        IF shall <> 1 THEN
            RAISE EXCEPTION 'the first wave is worth % beasts, not one', shall;
        END IF;
        IF deep <= shall THEN
            RAISE EXCEPTION 'a deep wave is worth no more than the first';
        END IF;

        -- And the sea is actually charged it.
        IF live IS NOT NULL THEN
            tide := live;
        ELSE
            UPDATE beast_hordes SET status = 'won', ended_at = now()
            WHERE status IN ('fighting', 'king');
            tide := horde_open('northern', 3::smallint, NULL);
        END IF;

        IF (SELECT h.status FROM beast_hordes h WHERE h.horde_id = tide)
           = 'fighting' AND horde_sea_left(tide) > 0 THEN
            DECLARE
                run    BIGINT;
                before INTEGER;
                after  INTEGER;
                r      RECORD;
            BEGIN
                DELETE FROM horde_gauntlets WHERE player_id = who;
                run := horde_gauntlet_open(who);

                -- Walk it deep enough that a wave is worth more than one.
                LOOP
                    SELECT h.beasts_slain INTO before FROM beast_hordes h
                    WHERE h.horde_id = tide;

                    SELECT * INTO r FROM horde_gauntlet_fight(run);

                    SELECT h.beasts_slain INTO after FROM beast_hordes h
                    WHERE h.horde_id = tide;

                    IF r.beast_down AND after - before <> horde_gauntlet_worth(r.wave) THEN
                        RAISE EXCEPTION
                            'wave % took % from the sea, not the % it was worth',
                            r.wave, after - before, horde_gauntlet_worth(r.wave);
                    END IF;

                    EXIT WHEN r.run_status <> 'fighting' OR r.wave > 20;
                END LOOP;
            END;
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
