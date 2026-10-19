-- 0284_a_lesser_beast_raises_a_greater_one
--
-- The egg shelf is bottom-heavy and always will be: 59 of the 139 waiting are
-- tier 3, 32 are tier 4, and two are tier 1. A tier 3 beast is not going to be
-- anybody's companion when they are holding a tier 9, so hatching one is a
-- thing you do once out of curiosity and then never again - which leaves the
-- commonest drop in the game with no use at all.
--
-- So a lesser beast raises a greater one. It is fed to it, the way ore and
-- bone and pills are, and what it is worth has two parts:
--
--     what it is    tier x pet_render_per_tier, lifted by its shell
--     what it cost  half of everything ever fed into it
--
-- The first part is why a tier 3 out of the shell is worth something at all -
-- about 36, so seven of them carry a tier 9 through its first stage. The
-- second is why raising one and then rendering it is a real choice rather
-- than a mistake: you get half your feed back, so fodder can be grown when
-- there is nothing better to do with the ore, and it is still a loss, so it
-- is never better than feeding the beast you meant to raise.
--
-- TWO THINGS IT WILL NOT DO. It will not eat the beast at your heel - that is
-- the one you chose, and losing it to a misclick is not a thing this should
-- be able to do. And it will not eat itself, which is worth a line of code to
-- refuse rather than a strange row in the table.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('pet_render_per_tier', 12,
     'What a beast is worth as food, per tier, before its shell and before '
     'anything it was fed. Set so about seven tier 3 hatchlings carry a tier '
     '9 through one stage - enough that the shallow end of the egg shelf is '
     'worth hatching.'),
    ('pet_render_share', 0.5,
     'How much of what was fed into a beast comes back when it is fed to '
     'another. Half: growing fodder is a real choice and still a loss, so it '
     'never beats feeding the beast you meant to raise.');


CREATE FUNCTION beast_invested(p_beast_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    -- Everything that has gone into it: the stages it climbed, at what they
    -- cost this beast's tier, plus whatever is banked toward the next.
    SELECT COALESCE((
        SELECT sum(st.feed_per_tier) * b.tier
        FROM beast_stages st
        JOIN beast_stages here ON here.code = b.stage
        WHERE st.sort_order <= here.sort_order
    ), 0) + b.fed
    FROM player_beasts b
    WHERE b.beast_id = p_beast_id;
$$;

COMMENT ON FUNCTION beast_invested(BIGINT) IS
    'Total nourishment a beast has absorbed - the stages it climbed plus what is banked toward the next.';


CREATE FUNCTION beast_render_value(p_beast_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    SELECT b.tier * game_config_value('pet_render_per_tier')
           * (1 + game_config_value('pet_rarity_step')
                  * (SELECT count(*) FROM rarities r2
                     WHERE r2.sort_order < r.sort_order))
         + beast_invested(p_beast_id) * game_config_value('pet_render_share')
    FROM player_beasts b
    JOIN rarities r ON r.code = b.rarity
    WHERE b.beast_id = p_beast_id;
$$;

COMMENT ON FUNCTION beast_render_value(BIGINT) IS
    'What one beast is worth fed to another: what it is, plus half of everything it was ever fed.';


CREATE FUNCTION feed_beast_beast(
    p_player_id BIGINT, p_beast_id BIGINT, p_eaten_id BIGINT
)
RETURNS TABLE (fed NUMERIC, stage TEXT, grew_to TEXT, still_wants NUMERIC,
               worth NUMERIC, eaten_name TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    eaten RECORD;
    value NUMERIC;
    grown TEXT;
BEGIN
    IF p_beast_id = p_eaten_id THEN
        RAISE EXCEPTION 'a beast cannot be fed to itself'
            USING ERRCODE = 'check_violation';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM player_beasts
        WHERE beast_id = p_beast_id AND owner_id = p_player_id
    ) THEN
        RAISE EXCEPTION 'that is not your beast' USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO eaten FROM player_beasts
    WHERE beast_id = p_eaten_id AND owner_id = p_player_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'that is not your beast' USING ERRCODE = 'check_violation';
    END IF;
    IF eaten.at_heel THEN
        RAISE EXCEPTION
            'that one walks at your heel - send another out first'
            USING ERRCODE = 'check_violation';
    END IF;
    IF beast_feed_needed(p_beast_id) IS NULL THEN
        RAISE EXCEPTION 'an elder has nothing left to grow into'
            USING ERRCODE = 'check_violation';
    END IF;

    value := beast_render_value(p_eaten_id);

    DELETE FROM player_beasts WHERE beast_id = p_eaten_id;

    grown := beast_grow(p_beast_id, value);

    RETURN QUERY
    SELECT b.fed, b.stage, grown, beast_feed_needed(p_beast_id),
           value, eaten.name
    FROM player_beasts b WHERE b.beast_id = p_beast_id;
END;
$$;

COMMENT ON FUNCTION feed_beast_beast(BIGINT, BIGINT, BIGINT) IS
    'Renders one beast down to raise another. Refuses the one at your heel, and refuses to feed a beast to itself.';


CREATE OR REPLACE VIEW player_beast_shelf AS
SELECT b.beast_id, b.owner_id, b.name, b.tier, b.rarity, b.at_heel,
       b.hatched_at,
       cs.name AS species, cs.rank AS species_rank, cs.kind AS species_kind,
       q.emoji, q.word AS shell,
       r.sort_order AS rarity_order,
       p.name AS path_name, p.emoji AS path_emoji,
       round(pet_attack(b.beast_id)) AS attack,
       reg.name AS found_in_name,
       b.stage, b.fed,
       st.name AS stage_name, st.sort_order AS stage_order, st.power AS stage_power,
       beast_feed_needed(b.beast_id) AS wants,
       round(beast_render_value(b.beast_id)) AS worth_as_food
FROM player_beasts b
JOIN creature_species cs ON cs.species_id = b.species_id
JOIN rarities r ON r.code = b.rarity
JOIN beast_stages st ON st.code = b.stage
LEFT JOIN egg_qualities q ON q.rarity = b.rarity
LEFT JOIN paths p ON p.code = pet_path(b.beast_id)
LEFT JOIN player_beast_eggs e ON e.egg_id = b.egg_id
LEFT JOIN regions reg ON reg.code = e.found_in;


-- ---------------------------------------------------------------------------
-- A lesser beast is worth something, and the greater one grows on it
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    who    BIGINT;
    big    BIGINT;
    small  BIGINT;
    e1     BIGINT;
    e2     BIGINT;
    got    RECORD;
    before NUMERIC;
BEGIN
    SELECT e.owner_id INTO who
    FROM player_beast_eggs e
    JOIN players p ON p.player_id = e.owner_id
    WHERE e.hatched_at IS NULL AND p.deleted_at IS NULL AND p.discord_id <> 0
    GROUP BY e.owner_id HAVING count(*) >= 2
    LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'nobody holds two eggs; the tests carry this';
        RETURN;
    END IF;

    BEGIN
        SELECT egg_id INTO e1 FROM player_beast_eggs
        WHERE owner_id = who AND hatched_at IS NULL ORDER BY tier DESC LIMIT 1;
        SELECT egg_id INTO e2 FROM player_beast_eggs
        WHERE owner_id = who AND hatched_at IS NULL AND egg_id <> e1
        ORDER BY tier LIMIT 1;

        big   := hatch_egg(who, e1);
        small := hatch_egg(who, e2);

        -- Neither may be walking, or the refusal below is the one that fires.
        UPDATE player_beasts SET at_heel = FALSE
        WHERE beast_id IN (big, small);

        IF beast_render_value(small) <= 0 THEN
            RAISE EXCEPTION 'a hatchling is worth nothing as food';
        END IF;

        before := (SELECT fed FROM player_beasts WHERE beast_id = big);
        SELECT * INTO got FROM feed_beast_beast(who, big, small);

        IF EXISTS (SELECT 1 FROM player_beasts WHERE beast_id = small) THEN
            RAISE EXCEPTION 'the beast that was eaten is still standing there';
        END IF;
        IF got.worth <= 0 THEN
            RAISE EXCEPTION 'it was rendered for nothing';
        END IF;

        -- Itself, never.
        BEGIN
            PERFORM feed_beast_beast(who, big, big);
            RAISE EXCEPTION 'a beast ate itself';
        EXCEPTION
            WHEN SQLSTATE '23514' THEN NULL;
        END;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;


-- ---------------------------------------------------------------------------
-- The shallow end of the shelf is worth hatching
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    lesser NUMERIC;
    step   NUMERIC;
BEGIN
    -- A tier 3 hatchling in common shell, which is what the egg shelf is
    -- mostly made of, against one stage of a tier 9.
    lesser := 3 * game_config_value('pet_render_per_tier');
    step   := (SELECT feed_per_tier FROM beast_stages WHERE code = 'juvenile') * 9;

    IF lesser <= 0 THEN
        RAISE EXCEPTION 'a tier 3 hatchling is worth nothing';
    END IF;

    IF step / lesser > 20 THEN
        RAISE EXCEPTION
            'it takes % tier 3 beasts to move a tier 9 one stage',
            round(step / lesser);
    END IF;

    RAISE NOTICE 'a tier 9 moves one stage on % tier 3 hatchlings',
        round(step / lesser);
END;
$$;
