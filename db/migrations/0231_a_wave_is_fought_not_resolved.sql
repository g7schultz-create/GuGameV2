-- 0231_a_wave_is_fought_not_resolved
--
-- The gauntlet pressed a button and told you what had happened.
--
-- 0229 resolved a whole wave per press: the cultivator swung with whatever
-- `dungeon_default_move` picked, the beast answered, and it repeated until one
-- of them was down. That kept a twenty wave run to twenty clicks, which was
-- the right worry and the wrong answer - because a fight nobody makes a
-- decision in is not a fight, it is a slot machine with a health bar. Every
-- other fight in this game asks which technique, and the whole technique
-- system - qi costs, loadouts, path matchups, the manuals people spend
-- fortunes on - only means something where somebody is choosing.
--
-- SO A PRESS IS ONE EXCHANGE NOW, and the press names a technique. You swing
-- with what you chose, the beast answers, and the wave stands until one of you
-- does not. `horde_gauntlet_fight` is gone rather than kept beside it: two
-- ways to take the same swing is the split this project keeps paying for.
--
-- QI IS WHAT MAKES IT A CHOICE. A technique with no cost would mean always
-- picking the strongest, which is not a decision. So a run carries a qi pool
-- like a duel does, spends it per technique, and can Guard to get it back at
-- the price of standing there while something bites you. The numbers are the
-- duel's own - `guard_qi_restore`, `guard_qi`, `guard_damage_reduction` - so
-- bracing means the same thing here as it does anywhere else.
--
-- The pool carries ACROSS waves, which is what makes depth cost something now
-- that health is not the only thing running out. Felling a wave hands some
-- back, so clearing is a breather rather than a slow bleed to a qi-starved
-- stalemate.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- A run has a qi pool and a memory of the exchange it is on
-- ---------------------------------------------------------------------------

ALTER TABLE horde_gauntlets
    ADD COLUMN qi        BIGINT  NOT NULL DEFAULT 0,
    ADD COLUMN max_qi    BIGINT  NOT NULL DEFAULT 1,
    ADD COLUMN exchanges INTEGER NOT NULL DEFAULT 0;

-- Runs that were opened before this migration get a real pool rather than the
-- placeholder default, so a run in flight is playable instead of stranded.
UPDATE horde_gauntlets g
SET max_qi = GREATEST(1, player_max_qi(g.player_id)),
    qi     = GREATEST(1, player_max_qi(g.player_id))
WHERE g.status = 'fighting';

ALTER TABLE horde_gauntlets
    ADD CONSTRAINT horde_gauntlet_qi_positive  CHECK (max_qi > 0),
    ADD CONSTRAINT horde_gauntlet_qi_in_range  CHECK (qi <= max_qi),
    ADD CONSTRAINT horde_gauntlet_qi_not_below CHECK (qi >= 0);

COMMENT ON COLUMN horde_gauntlets.qi IS
    'What is left to spend, carried across waves. The reason a technique is a choice rather than a formality.';
COMMENT ON COLUMN horde_gauntlets.exchanges IS
    'Blows traded in the wave now standing. Momentum builds on it, the same way it builds on a turn number in a duel.';


INSERT INTO game_config (key, value, description) VALUES
    ('horde_gauntlet_wave_qi', 0.25,
     'Fraction of the qi pool handed back for felling a wave. Clearing is '
     'meant to be a breather, not a slow bleed toward a stalemate nobody can '
     'break.');


-- ---------------------------------------------------------------------------
-- Opening one fills the pool
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION horde_gauntlet_open(p_player_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    tide RECORD;
    body BIGINT;
    pool BIGINT;
    made BIGINT;
BEGIN
    SELECT * INTO tide FROM beast_hordes
    WHERE status = 'fighting' ORDER BY horde_id DESC LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'there is no tide to walk into'
            USING ERRCODE = 'check_violation';
    END IF;

    IF EXISTS (SELECT 1 FROM horde_gauntlets g
               WHERE g.player_id = p_player_id AND g.status = 'fighting') THEN
        RAISE EXCEPTION 'you are already on the line'
            USING ERRCODE = 'check_violation';
    END IF;

    IF dungeon_default_move(p_player_id) IS NULL THEN
        RAISE EXCEPTION 'you have nothing to swing - learn a technique with /learn first'
            USING ERRCODE = 'check_violation';
    END IF;

    IF horde_sea_left(tide.horde_id) <= 0 THEN
        RAISE EXCEPTION 'the sea is empty - what is left of it is in the channel'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT pp.max_hp INTO body FROM player_physique pp
    WHERE pp.player_id = p_player_id;

    IF body IS NULL THEN
        RAISE EXCEPTION 'you have no body to walk it with'
            USING ERRCODE = 'check_violation';
    END IF;

    pool := GREATEST(1, player_max_qi(p_player_id));

    -- Full, unlike a dungeon, where you go in as you are. A dungeon costs a
    -- key and wounds you for real; this costs nothing and cannot, so starting
    -- at anything but full would measure the last fight instead of the build.
    INSERT INTO horde_gauntlets (horde_id, player_id, hp, max_hp, qi, max_qi)
    VALUES (tide.horde_id, p_player_id,
            GREATEST(1, body), GREATEST(1, body), pool, pool)
    RETURNING gauntlet_id INTO made;

    IF NOT horde_gauntlet_next(made) THEN
        UPDATE horde_gauntlets SET status = 'cleared', ended_at = now()
        WHERE gauntlet_id = made;
    END IF;

    RETURN made;
END;
$$;


-- A new wave is a fresh exchange count, so momentum starts over with it.
CREATE OR REPLACE FUNCTION horde_gauntlet_next(p_gauntlet_id BIGINT)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    run     RECORD;
    tide    RECORD;
    species RECORD;
    step    NUMERIC;
    pool    BIGINT;
BEGIN
    SELECT * INTO run FROM horde_gauntlets WHERE gauntlet_id = p_gauntlet_id;
    SELECT * INTO tide FROM beast_hordes WHERE horde_id = run.horde_id;

    IF tide.status <> 'fighting' OR horde_sea_left(run.horde_id) <= 0 THEN
        RETURN FALSE;
    END IF;

    -- Beasts only. The gauntlet is the weaker lane by design; the elites and
    -- the packs stand in the channel where a crowd can meet them.
    SELECT cs.* INTO species
    FROM creature_regions cr
    JOIN creature_species cs ON cs.species_id = cr.species_id
    WHERE cr.region_code = tide.region_code AND cs.kind = 'beast'
    ORDER BY -ln(random()) / cr.weight
    LIMIT 1;

    IF species IS NULL THEN
        RETURN FALSE;
    END IF;

    step := power(game_config_value('horde_gauntlet_step'), run.wave);
    pool := GREATEST(1, round(species.base_hp
                              * (1 + tide.rank * 0.6)
                              * game_config_value('horde_gauntlet_start')
                              * step))::bigint;

    UPDATE horde_gauntlets g
    SET wave = g.wave + 1,
        species_id = species.species_id,
        beast_hp = pool,
        beast_max_hp = pool,
        exchanges = 0,
        -- A breather for clearing one, and never past the pool.
        qi = LEAST(g.max_qi,
                   g.qi + ceil(game_config_value('horde_gauntlet_wave_qi')
                               * g.max_qi))
    WHERE g.gauntlet_id = p_gauntlet_id;

    RETURN TRUE;
END;
$$;


-- ---------------------------------------------------------------------------
-- One exchange, with a technique behind it
-- ---------------------------------------------------------------------------
-- The whole-wave resolver goes rather than staying beside this. Two ways to
-- take the same swing is the split 0225 spent a migration undoing.

DROP FUNCTION horde_gauntlet_fight(BIGINT);

CREATE FUNCTION horde_gauntlet_swing(
    p_gauntlet_id  BIGINT,
    p_action       TEXT DEFAULT 'attack',
    p_technique_id BIGINT DEFAULT NULL
)
RETURNS TABLE (
    wave        INTEGER,
    beast_name  TEXT,
    move_name   TEXT,
    dealt       BIGINT,
    taken       BIGINT,
    healed      BIGINT,
    qi_spent    BIGINT,
    qi_left     BIGINT,
    strikes     SMALLINT,
    crits       SMALLINT,
    guarded     BOOLEAN,
    beast_down  BOOLEAN,
    you_down    BOOLEAN,
    hp_left     BIGINT,
    hp_max      BIGINT,
    beast_left  BIGINT,
    earned      BIGINT,
    run_status  TEXT,
    sea_left    INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    run       RECORD;
    species   RECORD;
    tech      RECORD;
    swung     RECORD;
    bit       RECORD;
    cost      BIGINT := 0;
    out_dmg   BIGINT := 0;
    out_heal  BIGINT := 0;
    out_taken BIGINT := 0;
    n_strikes SMALLINT := 0;
    n_crits   SMALLINT := 0;
    body      BIGINT;
    pool      BIGINT;
    qi_now    BIGINT;
    hurt      BIGINT;
    down      BOOLEAN := FALSE;
    brace     BOOLEAN := FALSE;
    paid      BIGINT := 0;
    bite      NUMERIC;
    was_wave  INTEGER;
    said      TEXT;
BEGIN
    SELECT * INTO run FROM horde_gauntlets
    WHERE gauntlet_id = p_gauntlet_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'there is no such run' USING ERRCODE = 'check_violation';
    END IF;
    IF run.status <> 'fighting' THEN
        RAISE EXCEPTION 'that run is over' USING ERRCODE = 'check_violation';
    END IF;
    IF (SELECT h.status FROM beast_hordes h WHERE h.horde_id = run.horde_id)
       <> 'fighting' THEN
        UPDATE horde_gauntlets SET status = 'cleared', ended_at = now()
        WHERE gauntlet_id = p_gauntlet_id;
        RAISE EXCEPTION 'the tide has broken off' USING ERRCODE = 'check_violation';
    END IF;

    SELECT cs.* INTO species FROM creature_species cs
    WHERE cs.species_id = run.species_id;

    body     := run.hp;
    pool     := run.beast_hp;
    qi_now   := run.qi;
    was_wave := run.wave;
    bite     := game_config_value('horde_gauntlet_bite')
                * power(game_config_value('horde_gauntlet_step'), run.wave - 1);

    -- ---- what the cultivator does ----------------------------------------
    IF p_action = 'attack' THEN
        IF p_technique_id IS NULL THEN
            RAISE EXCEPTION 'choose a technique to attack with'
                USING ERRCODE = 'check_violation';
        END IF;

        SELECT t.* INTO tech
        FROM player_usable_techniques u
        JOIN techniques t ON t.technique_id = u.technique_id
        WHERE u.player_id = run.player_id AND u.technique_id = p_technique_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'you do not know that technique'
                USING ERRCODE = 'check_violation';
        END IF;

        cost := ceil(tech.qi_cost_pct * run.max_qi)::bigint;
        IF qi_now < cost THEN
            RAISE EXCEPTION 'not enough qi for %', tech.name
                USING ERRCODE = 'check_violation';
        END IF;
        qi_now := qi_now - cost;
        said   := tech.name;

        SELECT * INTO swung FROM player_swing(
            run.player_id, p_technique_id, run.species_id, pool,
            species.base_defense::bigint, body, run.max_hp, run.exchanges + 1);

        out_dmg   := swung.dealt;
        pool      := swung.hp_left;
        out_heal  := swung.healed;
        n_strikes := swung.strikes;
        n_crits   := swung.crits;
        body      := LEAST(run.max_hp, body + swung.healed);

    ELSIF p_action = 'guard' THEN
        brace  := TRUE;
        said   := 'Guard';
        -- The duel's own numbers, so bracing means one thing in this game.
        qi_now := LEAST(run.max_qi,
                        qi_now + ceil((game_config_value('guard_qi_restore')
                                       + player_stat(run.player_id, 'guard_qi'))
                                      * run.max_qi))::bigint;
    ELSE
        RAISE EXCEPTION 'no such action: %', p_action
            USING ERRCODE = 'check_violation';
    END IF;

    down := pool <= 0;

    -- ---- and what answers -------------------------------------------------
    IF NOT down THEN
        SELECT * INTO bit FROM compute_creature_damage(
            run.species_id, run.player_id, bite,
            (SELECT pp.defense FROM player_physique pp
             WHERE pp.player_id = run.player_id)::bigint);

        hurt := GREATEST(0, bit.final_damage);
        IF brace THEN
            hurt := GREATEST(0,
                floor(hurt * (1 - game_config_value('guard_damage_reduction'))));
        END IF;

        out_taken := hurt;
        body      := GREATEST(0, body - hurt);
    END IF;

    IF down THEN
        paid := round(game_config_value('horde_slay_bounty')
                      * GREATEST(1, species.rank))::bigint
              + round(game_config_value('horde_gauntlet_depth') * was_wave)::bigint;

        -- One body, but as many beasts as it was built out of.
        UPDATE beast_hordes h
        SET beasts_slain = h.beasts_slain + horde_gauntlet_worth(was_wave)
        WHERE h.horde_id = run.horde_id;
    END IF;

    -- Credited every exchange rather than at the end, so a run somebody walks
    -- away from still counted, and the board moves while they are on it.
    IF out_dmg > 0 OR out_heal > 0 OR paid > 0 THEN
        INSERT INTO horde_contributions
            (horde_id, player_id, damage_dealt, healing_done, beasts_slain,
             last_swing_at)
        VALUES (run.horde_id, run.player_id, out_dmg + paid, out_heal,
                CASE WHEN down THEN 1 ELSE 0 END, now())
        ON CONFLICT (horde_id, player_id) DO UPDATE
            SET damage_dealt  = horde_contributions.damage_dealt + out_dmg + paid,
                healing_done  = horde_contributions.healing_done + out_heal,
                beasts_slain  = horde_contributions.beasts_slain
                                + CASE WHEN down THEN 1 ELSE 0 END,
                last_swing_at = now();
    ELSE
        -- A guard is still turning up. Without this a defender who braced for
        -- a minute would drop off `horde_hands` and shrink the tide.
        INSERT INTO horde_contributions (horde_id, player_id, last_swing_at)
        VALUES (run.horde_id, run.player_id, now())
        ON CONFLICT (horde_id, player_id) DO UPDATE SET last_swing_at = now();
    END IF;

    UPDATE horde_gauntlets g
    SET hp = body,
        qi = qi_now,
        beast_hp = GREATEST(0, pool),
        exchanges = g.exchanges + 1,
        felled = g.felled + CASE WHEN down THEN 1 ELSE 0 END,
        damage_dealt = g.damage_dealt + out_dmg,
        healing_done = g.healing_done + out_heal,
        damage_taken = g.damage_taken + out_taken
    WHERE g.gauntlet_id = p_gauntlet_id;

    IF body <= 0 THEN
        UPDATE horde_gauntlets SET status = 'fallen', ended_at = now()
        WHERE gauntlet_id = p_gauntlet_id;
    ELSIF down THEN
        IF NOT horde_gauntlet_next(p_gauntlet_id) THEN
            UPDATE horde_gauntlets SET status = 'cleared', ended_at = now()
            WHERE gauntlet_id = p_gauntlet_id;
        END IF;
    END IF;

    SELECT * INTO run FROM horde_gauntlets WHERE gauntlet_id = p_gauntlet_id;

    RETURN QUERY SELECT
        was_wave, species.name, said, out_dmg, out_taken, out_heal,
        cost, run.qi, n_strikes, n_crits, brace,
        down, (run.status = 'fallen'),
        run.hp, run.max_hp, run.beast_hp, paid, run.status,
        horde_sea_left(run.horde_id);
END;
$$;

COMMENT ON FUNCTION horde_gauntlet_swing(BIGINT, TEXT, BIGINT) IS
    'One exchange on the line: the technique the cultivator chose, then the answer. The same `player_swing` a duel and a dungeon round use.';


-- The screen needs the pool it is spending.
CREATE OR REPLACE VIEW horde_gauntlet_board AS
SELECT g.gauntlet_id, g.horde_id, g.player_id, g.wave, g.felled,
       g.hp, g.max_hp, g.beast_hp, g.beast_max_hp, g.status,
       g.damage_dealt, g.healing_done, g.damage_taken,
       cs.name AS beast_name, cs.rank AS beast_rank, cs.description,
       p.discord_name,
       h.region_code, h.rank AS tide_rank,
       horde_sea_left(g.horde_id) AS sea_left,
       horde_contribution(g.horde_id, g.player_id) AS contribution,
       g.qi, g.max_qi, g.exchanges
FROM horde_gauntlets g
JOIN beast_hordes h ON h.horde_id = g.horde_id
JOIN players p      ON p.player_id = g.player_id
LEFT JOIN creature_species cs ON cs.species_id = g.species_id;


DO $$
DECLARE
    tide  BIGINT;
    who   BIGINT;
    live  BIGINT;
    run   BIGINT;
    move  BIGINT;
    r     RECORD;
    was   BIGINT;
BEGIN
    SELECT h.horde_id INTO live FROM beast_hordes h
    WHERE h.status IN ('fighting', 'king') LIMIT 1;

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
        IF live IS NOT NULL THEN
            tide := live;
        ELSE
            UPDATE beast_hordes SET status = 'won', ended_at = now()
            WHERE status IN ('fighting', 'king');
            tide := horde_open('northern', 2::smallint, NULL);
        END IF;

        IF (SELECT h.status FROM beast_hordes h WHERE h.horde_id = tide)
           <> 'fighting' OR horde_sea_left(tide) <= 0 THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        DELETE FROM horde_gauntlets WHERE player_id = who;
        run  := horde_gauntlet_open(who);
        move := dungeon_default_move(who);

        -- A swing has to name a technique.
        BEGIN
            PERFORM horde_gauntlet_swing(run, 'attack', NULL);
            RAISE EXCEPTION 'a swing landed with no technique behind it';
        EXCEPTION
            WHEN check_violation THEN NULL;
        END;

        -- One that is not theirs is refused.
        BEGIN
            PERFORM horde_gauntlet_swing(run, 'attack', -1::bigint);
            RAISE EXCEPTION 'a technique nobody knows was allowed';
        EXCEPTION
            WHEN check_violation THEN NULL;
        END;

        -- The chosen one costs qi and lands.
        was := (SELECT g.qi FROM horde_gauntlets g WHERE g.gauntlet_id = run);
        SELECT * INTO r FROM horde_gauntlet_swing(run, 'attack', move);

        IF r.dealt <= 0 THEN
            RAISE EXCEPTION 'a chosen technique did nothing';
        END IF;
        IF r.qi_spent <= 0 THEN
            RAISE EXCEPTION 'a technique was free';
        END IF;
        IF r.qi_left >= was THEN
            RAISE EXCEPTION 'the pool did not go down';
        END IF;

        -- And a guard buys some of it back.
        IF (SELECT g.status FROM horde_gauntlets g WHERE g.gauntlet_id = run)
           = 'fighting' THEN
            was := (SELECT g.qi FROM horde_gauntlets g WHERE g.gauntlet_id = run);
            SELECT * INTO r FROM horde_gauntlet_swing(run, 'guard');
            IF NOT r.guarded THEN
                RAISE EXCEPTION 'a guard did not brace';
            END IF;
            IF r.qi_left <= was THEN
                RAISE EXCEPTION 'a guard bought no qi back';
            END IF;
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
