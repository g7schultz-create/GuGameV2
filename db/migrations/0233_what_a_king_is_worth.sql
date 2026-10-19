-- 0233_what_a_king_is_worth
--
-- The finale paid less than the mobs standing in front of it.
--
-- `horde_king_rise` never set `worth`, so the King defaulted to 1, and 0230
-- ties the finisher's bounty to what the thing stood for. On tide 235 that
-- made the killing blow on a 54,000 health King worth 60 contribution - while
-- the last hit on an ordinary channel beast paid 720 and on an elite 1,080. A
-- twelfth of a regular spawn, for the boss the whole room organises around.
--
-- AND KILLING IT CHANGED NOTHING. `horde_settle` grants the same region
-- blessing for any win, and after 0232 there are three ways to win: kill the
-- King, let it walk off, or hold the line to the clock. 0221 calls this "the
-- best ending there is" and it resolved to exactly what happens if everybody
-- ignores it. A boss with a crown, a timer and its own health formula, and no
-- consequence either way.
--
-- SO THE KING IS A HORDE UNTO ITSELF, and `worth` says so. The bounty follows
-- the rule 0230 already wrote rather than growing a King-shaped exception.
--
-- BUT ITS WORTH MUST NOT TOUCH THE LINE. `beasts_lost` counts what got past,
-- and a King worth forty walking off a small tide would push a held region
-- over `line_holds` and score it overrun - which flatly contradicts what 0232
-- established this morning, that a King getting past is a tide that was held.
-- The King arrives after the sea is already empty and the line is already
-- decided; it is not part of the tide it comes behind. So the sweep counts
-- every escape but a King's.
--
-- AND A FOURTH CHEST, WHICH IS NOT A THRESHOLD. The three are contribution
-- bars and that is right for a two hour event nobody attends all of. This one
-- is for anybody who put damage into the King and lived to see it fall -
-- turning up to the finale IS the qualification, so the cultivator who landed
-- one blow on it opens the same chest as the one who landed forty. It is the
-- only reward in this event that a ranking cannot take from you.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- Who bloodied it
-- ---------------------------------------------------------------------------

ALTER TABLE horde_contributions
    ADD COLUMN king_damage      BIGINT  NOT NULL DEFAULT 0
               CHECK (king_damage >= 0),
    ADD COLUMN king_chest_taken BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN horde_contributions.king_damage IS
    'Damage this cultivator put into the King itself. The whole qualification for the fourth chest - one blow is enough, because being there is the point.';


INSERT INTO game_config (key, value, description) VALUES
    ('horde_king_worth', 40,
     'How many beasts of the tide the King stands for. It is not part of the '
     'sea it comes behind - this is what the finishing blow is paid against, '
     'and the sweep deliberately does not count it against the line.'),
    ('horde_king_chest_stones', 6000,
     'Spirit Stones in the King''s chest, times the tide''s rank.'),
    ('horde_king_gu_bonus', 1,
     'How far past the world''s drop ceiling a Gu from the King''s chest may '
     'be. The same shape the dungeon jackpot uses, so the deepest tides are '
     'the other way a rank 6 Gu reaches a cultivator.');


-- ---------------------------------------------------------------------------
-- The King rises worth what it is
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'horde_king_rise';

    old := '    INSERT INTO horde_encounters
        (horde_id, species_id, kind, hp, max_hp, expires_at)
    VALUES (p_horde_id, who, ''king'', pool, pool,';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'horde_king_rise no longer raises the King the old way';
    END IF;

    EXECUTE replace(src, old,
        '    INSERT INTO horde_encounters
        (horde_id, species_id, kind, hp, max_hp, worth, expires_at)
    VALUES (p_horde_id, who, ''king'', pool, pool,
            GREATEST(1, game_config_value(''horde_king_worth''))::smallint,');
END;
$$;


-- And the line never feels it, either way.
CREATE OR REPLACE FUNCTION horde_sweep(p_horde_id BIGINT)
RETURNS TABLE (escaped INTEGER, beast_names TEXT[])
LANGUAGE plpgsql
AS $$
DECLARE
    got  INTEGER := 0;
    away INTEGER := 0;
    said TEXT[]  := '{}';
BEGIN
    WITH gone AS (
        UPDATE horde_encounters e
        SET status = 'escaped', settled_at = now()
        WHERE e.horde_id = p_horde_id
          AND e.status = 'alive'
          AND e.expires_at <= now()
        RETURNING e.species_id, e.worth, e.kind
    )
    SELECT count(*)::integer,
           -- Everything but the King. It comes after the sea is empty and the
           -- line is already decided, so counting what it stands for against
           -- `line_holds` would score a held region overrun for missing a
           -- finale - which 0232 settled is not a loss.
           COALESCE(sum(gone.worth) FILTER (WHERE gone.kind <> 'king'), 0)::integer,
           COALESCE(array_agg(DISTINCT cs.name), '{}')
    INTO got, away, said
    FROM gone
    JOIN creature_species cs ON cs.species_id = gone.species_id;

    IF away > 0 THEN
        UPDATE beast_hordes h
        SET beasts_lost = h.beasts_lost + away
        WHERE h.horde_id = p_horde_id;
    END IF;

    RETURN QUERY SELECT got, said;
END;
$$;


-- ---------------------------------------------------------------------------
-- Striking it is remembered
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc WHERE proname = 'horde_strike';

    old := '    RETURN QUERY SELECT hurt,
                        GREATEST(0, met.hp - hurt), met.max_hp, down,
                        met.species_name, met.kind, paid;';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'horde_strike no longer returns the swing the old way';
    END IF;

    EXECUTE replace(src, old,
        '    -- Kept apart from the contribution total on purpose: the fourth chest
    -- asks whether you were there for the King, and the total cannot answer
    -- that - somebody can out-contribute the whole room without ever meeting it.
    IF met.kind = ''king'' THEN
        UPDATE horde_contributions c
        SET king_damage = c.king_damage + hurt
        WHERE c.horde_id = met.horde_id AND c.player_id = p_player_id;
    END IF;

    RETURN QUERY SELECT hurt,
                        GREATEST(0, met.hp - hurt), met.max_hp, down,
                        met.species_name, met.kind, paid;');
END;
$$;


-- ---------------------------------------------------------------------------
-- The fourth chest
-- ---------------------------------------------------------------------------

CREATE FUNCTION horde_king_chest_due(p_horde_id BIGINT, p_player_id BIGINT)
RETURNS BOOLEAN
LANGUAGE sql STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM horde_contributions c
        JOIN beast_hordes h ON h.horde_id = c.horde_id
        WHERE c.horde_id = p_horde_id
          AND c.player_id = p_player_id
          AND c.king_damage > 0
          AND NOT c.king_chest_taken
          AND h.status IN ('won', 'lost')
          AND EXISTS (SELECT 1 FROM horde_encounters e
                      WHERE e.horde_id = h.horde_id
                        AND e.kind = 'king' AND e.status = 'slain'));
$$;

COMMENT ON FUNCTION horde_king_chest_due(BIGINT, BIGINT) IS
    'Whether this cultivator has a King''s chest waiting. One blow on the King and the King down is the whole test - it is not a threshold and no ranking can take it.';


CREATE OR REPLACE FUNCTION horde_chest_take(p_horde_id BIGINT, p_player_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    tide   RECORD;
    stood  RECORD;
    earned SMALLINT;
    chest  SMALLINT;
    crown  BOOLEAN;
    got    JSONB := '{}'::jsonb;
    names  TEXT[] := '{}';
    pages  INTEGER := 0;
    eggs   TEXT[] := '{}';
    stones BIGINT := 0;
    worms  TEXT[] := '{}';
    ceil_r SMALLINT;
    one    RECORD;
    made   BIGINT;
BEGIN
    SELECT * INTO tide FROM beast_hordes WHERE horde_id = p_horde_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'there was no such tide' USING ERRCODE = 'check_violation';
    END IF;
    IF tide.status NOT IN ('won', 'lost') THEN
        RAISE EXCEPTION 'the tide is not over yet' USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO stood FROM horde_contributions c
    WHERE c.horde_id = p_horde_id AND c.player_id = p_player_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'you were not on that line' USING ERRCODE = 'check_violation';
    END IF;

    earned := horde_chests_earned(p_horde_id, p_player_id);
    crown  := horde_king_chest_due(p_horde_id, p_player_id);

    IF earned <= stood.chest_taken AND NOT crown THEN
        RAISE EXCEPTION 'you have opened everything you earned'
            USING ERRCODE = 'check_violation';
    END IF;

    -- Everything earned and not yet taken, in one opening.
    FOR chest IN (stood.chest_taken + 1)..earned LOOP
        -- Stones scale with the chest and the depth of the tide.
        stones := stones + round(600 * chest * GREATEST(1, tide.rank))::bigint;

        -- Herbs of the region, two kinds a chest.
        FOR one IN
            SELECT m.code, m.name FROM materials m
            JOIN region_materials rm ON rm.material_code = m.code
            WHERE rm.region_code = tide.region_code
              AND m.tier IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM ores o WHERE o.material_code = m.code)
            ORDER BY random() LIMIT 2
        LOOP
            PERFORM grant_material(p_player_id, one.code,
                                   (30 * chest * GREATEST(1, tide.rank))::bigint);
            names := names || ((30 * chest * GREATEST(1, tide.rank))::bigint
                               || 'x ' || one.name);
        END LOOP;

        -- A page a chest, at the tide's own depth.
        PERFORM mint_page(p_player_id,
                          LEAST(7, GREATEST(1, tide.rank))::smallint,
                          LEAST(7, GREATEST(1, tide.rank + 1))::smallint,
                          NULL, NULL, tide.region_code);
        pages := pages + 1;

        -- An egg from the second chest, of the region's own beasts.
        IF chest >= 2 THEN
            made := roll_beast_egg(p_player_id, tide.rank, tide.region_code);
            IF made IS NOT NULL THEN
                eggs := eggs || (SELECT s.name FROM player_egg_shelf s
                                 WHERE s.egg_id = made);
            END IF;
        END IF;

        -- And a Gu from the third, inside the world's own ceiling.
        IF chest >= 3 THEN
            SELECT t.gu_type_id INTO made FROM gu_types t
            JOIN rarities r ON r.code = t.rarity
            WHERE t.rank <= LEAST(GREATEST(tide.rank, 1),
                                  game_config_value('gu_max_droppable_rank'))
            ORDER BY -ln(random()) * r.sort_order
            LIMIT 1;
            IF made IS NOT NULL THEN
                PERFORM grant_gu(p_player_id, made, tide.region_code);
                worms := worms || (SELECT t.name FROM gu_types t
                                   WHERE t.gu_type_id = made);
            END IF;
        END IF;
    END LOOP;

    -- ---- and the King's, which is not a threshold -------------------------
    IF crown THEN
        stones := stones + round(game_config_value('horde_king_chest_stones')
                                 * GREATEST(1, tide.rank))::bigint;

        FOR one IN
            SELECT m.code, m.name FROM materials m
            JOIN region_materials rm ON rm.material_code = m.code
            WHERE rm.region_code = tide.region_code
              AND m.tier IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM ores o WHERE o.material_code = m.code)
            ORDER BY random() LIMIT 3
        LOOP
            PERFORM grant_material(p_player_id, one.code,
                                   (150 * GREATEST(1, tide.rank))::bigint);
            names := names || ((150 * GREATEST(1, tide.rank))::bigint
                               || 'x ' || one.name);
        END LOOP;

        -- Two pages, a rung deeper than the tide itself.
        PERFORM mint_page(p_player_id,
                          LEAST(7, GREATEST(1, tide.rank + 1))::smallint,
                          LEAST(7, GREATEST(1, tide.rank + 2))::smallint,
                          NULL, NULL, tide.region_code);
        PERFORM mint_page(p_player_id,
                          LEAST(7, GREATEST(1, tide.rank + 1))::smallint,
                          LEAST(7, GREATEST(1, tide.rank + 2))::smallint,
                          NULL, NULL, tide.region_code);
        pages := pages + 2;

        -- An egg of the region, a rank above what the tide would give.
        made := roll_beast_egg(p_player_id, (tide.rank + 1)::smallint,
                               tide.region_code);
        IF made IS NOT NULL THEN
            eggs := eggs || (SELECT s.name FROM player_egg_shelf s
                             WHERE s.egg_id = made);
        END IF;

        -- And the Gu the King is actually for: past the world's drop ceiling,
        -- the same way the deepest dungeon room reaches a rank 6.
        ceil_r := LEAST(GREATEST(tide.rank, 1)
                        + game_config_value('horde_king_gu_bonus')::int,
                        game_config_value('gu_max_droppable_rank')::int
                        + game_config_value('horde_king_gu_bonus')::int)::smallint;

        -- The top rung available, not a roll across everything under it: a
        -- King's chest that usually paid a rank 1 Gu would be the same hollow
        -- promise this migration exists to close.
        SELECT t.gu_type_id INTO made FROM gu_types t
        JOIN rarities r ON r.code = t.rarity
        WHERE t.rank = ceil_r
        ORDER BY -ln(random()) * r.sort_order
        LIMIT 1;

        IF made IS NULL THEN
            SELECT t.gu_type_id INTO made FROM gu_types t
            JOIN rarities r ON r.code = t.rarity
            WHERE t.rank <= ceil_r
            ORDER BY t.rank DESC, -ln(random()) * r.sort_order
            LIMIT 1;
        END IF;

        IF made IS NOT NULL THEN
            PERFORM grant_gu(p_player_id, made, tide.region_code);
            worms := worms || (SELECT t.name FROM gu_types t
                               WHERE t.gu_type_id = made);
        END IF;

        UPDATE horde_contributions c
        SET king_chest_taken = TRUE
        WHERE c.horde_id = p_horde_id AND c.player_id = p_player_id;
    END IF;

    IF stones > 0 THEN
        PERFORM grant_material(p_player_id, 'spirit_stone', stones);
    END IF;

    UPDATE horde_contributions c
    SET chest_taken = earned
    WHERE c.horde_id = p_horde_id AND c.player_id = p_player_id;

    got := jsonb_build_object(
        'chests', GREATEST(0, earned - stood.chest_taken) + CASE WHEN crown THEN 1 ELSE 0 END,
        'through', earned,
        'king', crown,
        'stones', stones,
        'herbs', to_jsonb(names),
        'pages', pages,
        'eggs', to_jsonb(eggs),
        'gu', to_jsonb(worms));

    RETURN got;
END;
$$;


-- The roll says who met the King.
CREATE OR REPLACE VIEW horde_roll AS
SELECT c.horde_id, c.player_id, p.discord_name,
       c.damage_dealt, c.healing_done, c.beasts_slain, c.elites_slain,
       horde_contribution(c.horde_id, c.player_id) AS contribution,
       horde_chests_earned(c.horde_id, c.player_id) AS chests_earned,
       c.chest_taken, c.last_swing_at,
       rank() OVER (PARTITION BY c.horde_id
                    ORDER BY horde_contribution(c.horde_id, c.player_id) DESC)
           AS standing,
       c.king_damage, c.king_chest_taken,
       horde_king_chest_due(c.horde_id, c.player_id) AS king_chest_due
FROM horde_contributions c
JOIN players p ON p.player_id = c.player_id;


DO $$
DECLARE
    tide  BIGINT;
    who   BIGINT;
    mate  BIGINT;
    king  BIGINT;
    hit   RECORD;
    took  JSONB;
    paid  BIGINT;
BEGIN
    SELECT p.player_id INTO who FROM players p
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0
      AND dungeon_default_move(p.player_id) IS NOT NULL
    LIMIT 1;
    SELECT p.player_id INTO mate FROM players p
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0 AND p.player_id <> who
    LIMIT 1;
    IF who IS NULL OR mate IS NULL THEN
        RAISE NOTICE 'not enough cultivators to measure; the tests carry it';
        RETURN;
    END IF;

    BEGIN
        UPDATE beast_hordes SET status = 'won', ended_at = now()
        WHERE status IN ('fighting', 'king');
        tide := horde_open('northern', 3::smallint, NULL);

        UPDATE beast_hordes SET beasts_slain = beasts_total WHERE horde_id = tide;
        king := horde_king_rise(tide);

        -- It is worth what a King is worth, so the finisher is paid for it.
        IF (SELECT e.worth FROM horde_encounters e WHERE e.encounter_id = king) <= 1 THEN
            RAISE EXCEPTION 'the King still stands for one beast';
        END IF;

        -- Somebody who never met it earns no King chest.
        INSERT INTO horde_contributions (horde_id, player_id, damage_dealt)
        VALUES (tide, mate, 500)
        ON CONFLICT (horde_id, player_id) DO UPDATE SET damage_dealt = 500;

        -- And somebody who lands one blow does.
        SELECT * INTO hit FROM horde_strike(king, who);
        IF hit.dealt <= 0 THEN
            RAISE EXCEPTION 'the King took nothing';
        END IF;
        IF (SELECT c.king_damage FROM horde_contributions c
            WHERE c.horde_id = tide AND c.player_id = who) <= 0 THEN
            RAISE EXCEPTION 'a blow on the King was not remembered';
        END IF;

        -- Fell it, and the finishing blow is paid like the pack it is.
        UPDATE horde_encounters SET hp = 1 WHERE encounter_id = king;
        SELECT * INTO hit FROM horde_strike(king, who);
        IF NOT hit.killed THEN
            RAISE EXCEPTION 'the killing blow did not kill';
        END IF;
        paid := hit.bounty;
        IF paid < 1000 THEN
            RAISE EXCEPTION 'felling the King paid % - still less than a spawn', paid;
        END IF;

        PERFORM horde_settle(tide);

        IF NOT horde_king_chest_due(tide, who) THEN
            RAISE EXCEPTION 'the cultivator who felled the King is owed nothing';
        END IF;
        IF horde_king_chest_due(tide, mate) THEN
            RAISE EXCEPTION 'somebody who never met the King is owed its chest';
        END IF;

        took := horde_chest_take(tide, who);
        IF NOT (took ->> 'king')::boolean THEN
            RAISE EXCEPTION 'the opening did not include the King chest';
        END IF;
        IF jsonb_array_length(took -> 'gu') < 1 THEN
            RAISE EXCEPTION 'the King chest held no Gu';
        END IF;

        -- And only once.
        IF horde_king_chest_due(tide, who) THEN
            RAISE EXCEPTION 'the King chest can be opened twice';
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
