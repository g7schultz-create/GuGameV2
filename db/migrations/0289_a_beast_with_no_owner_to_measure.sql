-- 0289_a_beast_with_no_owner_to_measure
--
-- `pet_max_hp` holds a beast's body against its owner's, which is the whole
-- point of it - but it did that with COALESCE(pp.max_hp, 0), and a cultivator
-- with no `player_physique` row therefore capped their beast at zero. The
-- GREATEST(1, ...) underneath then handed back a beast with one point of
-- health, which is not a beast, and nothing anywhere would have said why.
--
-- One live character has no physique row today - an account that never
-- finished being made - and none of the six beast owners is that account, so
-- nothing in the world is currently wrong. It would have gone wrong the first
-- time such an account hatched an egg, and it would have looked like the egg
-- was broken.
--
-- A cap needs something to measure against. Where there is nothing, there is
-- no cap: the beast is simply what its tier, shell and stage make it. That is
-- the honest reading of a missing row, and it fails toward a working beast
-- rather than a beast with one hit point.
--
-- Forward-only. Do not edit once applied.


CREATE OR REPLACE FUNCTION pet_max_hp(p_beast_id BIGINT)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    -- Built like pet_attack, then held against its owner's own body - when
    -- there is an owner's body to hold it against.
    SELECT GREATEST(1, round(LEAST(
        raw.pool,
        CASE WHEN raw.body IS NULL OR raw.body <= 0
             THEN raw.pool
             ELSE raw.body * game_config_value('pet_hp_cap')
        END
    )))::bigint
    FROM (
        SELECT cs.base_hp
               * power(game_config_value('creature_defense_scale_per_rank'),
                       GREATEST(0, b.tier - cs.rank))
               * (1 + game_config_value('pet_rarity_step')
                      * (SELECT count(*) FROM rarities r2
                         WHERE r2.sort_order < r.sort_order))
               * st.power
               * game_config_value('pet_hp_scale') AS pool,
               pp.max_hp::numeric AS body
        FROM player_beasts b
        JOIN creature_species cs ON cs.species_id = b.species_id
        JOIN rarities r ON r.code = b.rarity
        JOIN beast_stages st ON st.code = b.stage
        LEFT JOIN player_physique pp ON pp.player_id = b.owner_id
        WHERE b.beast_id = p_beast_id
    ) raw;
$$;

COMMENT ON FUNCTION pet_max_hp(BIGINT) IS
    'A beast''s body: its species lifted by tier, shell and stage, capped against its owner''s own maximum where there is one to measure against.';


-- ---------------------------------------------------------------------------
-- Nothing that exists moved, and a beast with no owner's body is still a beast
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    r      RECORD;
    capped INTEGER := 0;
BEGIN
    FOR r IN
        SELECT b.beast_id, b.name, pet_max_hp(b.beast_id) AS top, pp.max_hp AS body
        FROM player_beasts b
        LEFT JOIN player_physique pp ON pp.player_id = b.owner_id
    LOOP
        IF r.top IS NULL OR r.top < 1 THEN
            RAISE EXCEPTION 'beast % has no body at all', r.beast_id;
        END IF;

        IF r.body IS NOT NULL THEN
            IF r.top > ceil(r.body * game_config_value('pet_hp_cap')) THEN
                RAISE EXCEPTION 'beast % broke its owner''s cap', r.beast_id;
            END IF;
            IF r.top >= floor(r.body * game_config_value('pet_hp_cap')) THEN
                capped := capped + 1;
            END IF;
        ELSIF r.top <= 1 THEN
            RAISE EXCEPTION
                'beast % has an owner with no body and got one hit point',
                r.beast_id;
        END IF;
    END LOOP;

    RAISE NOTICE '% beasts sit at their owner''s cap', capped;
END;
$$;


-- ---------------------------------------------------------------------------
-- The case that would have broken: a body-less owner hatches an egg
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    who   BIGINT;
    egg   BIGINT;
    beast BIGINT;
    top   BIGINT;
    sp    BIGINT;
BEGIN
    SELECT p.player_id INTO who
    FROM players p
    LEFT JOIN player_physique pp ON pp.player_id = p.player_id
    WHERE p.deleted_at IS NULL AND pp.player_id IS NULL AND p.discord_id > 0
    LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'every cultivator has a body; the tests carry this';
        RETURN;
    END IF;

    BEGIN
        SELECT species_id INTO sp FROM creature_species
        WHERE kind = 'beast' ORDER BY rank LIMIT 1;

        egg   := grant_beast_egg(who, sp, 8::smallint, 'common', NULL);
        beast := hatch_egg(who, egg);
        top   := pet_max_hp(beast);

        IF top <= 1 THEN
            RAISE EXCEPTION
                'a beast hatched to % health for an owner with no body', top;
        END IF;

        RAISE NOTICE 'a body-less owner hatches a beast with % health', top;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
