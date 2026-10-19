-- 0306_a_technique_can_declare_what_it_leaves_behind
--
-- 0298 through 0304 built somewhere to put a lasting effect and taught all
-- five lanes to read it. Nothing could still PUT one there except a hand
-- written call to `effect_apply`. This is the bridge: `techniques.effects`,
-- the jsonb column that has been `{}` on all 205 techniques and consulted by
-- nothing since the table was made, becomes the declaration.
--
-- THE SHAPE.
--
--     {"apply": [{"code": "defence_up", "magnitude": 0.25,
--                 "turns": 3, "target": "party"}]}
--
-- `target` is 'self' or 'party' and defaults to self. Party means every
-- cultivator in the same fight, which is only ever more than one person in a
-- dungeon - so a party buff in a duel is a self buff, silently and correctly,
-- rather than an error about a room that is not there.
--
-- WHY IT LANDS IN `player_swing`. Every lane already hands that function the
-- player, the technique and the scope; it is the one place all five agree on.
-- The alternative is five call sites that must each remember to cast, and the
-- history of this schema is that five call sites become four the first time
-- somebody adds a lane. It is a write inside a function that used only to
-- read, which is a real change of character and the reason it is written down
-- here rather than left to be discovered.
--
-- A DECLARATION IS CHECKED WHEN IT IS WRITTEN, not when it is swung. The
-- constraint refuses an effect code that does not exist, a magnitude that is
-- not a positive number, or turns that are not a positive whole one - so a
-- typo in a content migration fails there, loudly, instead of silently doing
-- nothing in combat for a month.
--
-- Forward-only. Do not edit once applied.


CREATE FUNCTION technique_effects_well_formed(p_effects JSONB)
RETURNS BOOLEAN
LANGUAGE sql
IMMUTABLE
AS $$
    -- Nothing declared is fine. Anything declared must be a list of entries
    -- naming a real kind, a positive magnitude and a whole number of turns.
    SELECT CASE
        WHEN p_effects IS NULL OR p_effects = '{}'::jsonb THEN TRUE
        WHEN NOT (p_effects ? 'apply') THEN TRUE
        WHEN jsonb_typeof(p_effects -> 'apply') <> 'array' THEN FALSE
        ELSE NOT EXISTS (
            SELECT 1
            FROM jsonb_array_elements(p_effects -> 'apply') AS e
            WHERE NOT EXISTS (SELECT 1 FROM battle_effect_kinds k
                              WHERE k.code = e ->> 'code')
               OR (e ->> 'magnitude') IS NULL
               OR (e ->> 'magnitude')::numeric <= 0
               OR (e ->> 'turns') IS NULL
               OR (e ->> 'turns')::numeric <= 0
               OR (e ->> 'turns')::numeric <> floor((e ->> 'turns')::numeric)
               OR COALESCE(e ->> 'target', 'self') NOT IN ('self', 'party')
        )
    END;
$$;

COMMENT ON FUNCTION technique_effects_well_formed(JSONB) IS
    'Whether a technique''s declared effects name real kinds with sane magnitudes and turns.';

ALTER TABLE techniques
    ADD CONSTRAINT techniques_effects_well_formed
    CHECK (technique_effects_well_formed(effects));


CREATE FUNCTION technique_cast_effects(
    p_player_id BIGINT, p_technique_id BIGINT,
    p_scope TEXT, p_scope_id BIGINT
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    spec    JSONB;
    one     JSONB;
    landed  INTEGER := 0;
    who     BIGINT;
BEGIN
    IF p_scope IS NULL OR p_scope_id IS NULL OR p_technique_id IS NULL THEN
        RETURN 0;
    END IF;

    SELECT effects INTO spec FROM techniques
    WHERE technique_id = p_technique_id;

    IF spec IS NULL OR NOT (spec ? 'apply') THEN
        RETURN 0;
    END IF;

    FOR one IN SELECT * FROM jsonb_array_elements(spec -> 'apply') LOOP
        IF COALESCE(one ->> 'target', 'self') = 'party' AND p_scope = 'dungeon' THEN
            -- Everybody still standing in the room, the caster included.
            FOR who IN
                SELECT x.player_id FROM dungeon_raiders x
                WHERE x.run_id = p_scope_id AND x.current_hp > 0
            LOOP
                PERFORM effect_apply(p_scope, p_scope_id, who,
                                     one ->> 'code',
                                     (one ->> 'magnitude')::numeric,
                                     (one ->> 'turns')::integer,
                                     p_technique_id);
                landed := landed + 1;
            END LOOP;
        ELSE
            -- Self, and also party-in-a-lane-with-no-party: a rally shouted
            -- in a duel still rallies the one person who heard it.
            PERFORM effect_apply(p_scope, p_scope_id, p_player_id,
                                 one ->> 'code',
                                 (one ->> 'magnitude')::numeric,
                                 (one ->> 'turns')::integer,
                                 p_technique_id);
            landed := landed + 1;
        END IF;
    END LOOP;

    RETURN landed;
END;
$$;

COMMENT ON FUNCTION technique_cast_effects(BIGINT, BIGINT, TEXT, BIGINT) IS
    'Applies whatever a technique declares in its effects, to the caster or to the whole room.';


-- ---------------------------------------------------------------------------
-- Swinging a technique casts what it declares
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    body   TEXT;
    anchor TEXT :=
'    external := player_external_multiplier(p_player_id, p_technique_id)
                + mom + wounded;';
BEGIN
    SELECT pg_get_functiondef(oid) INTO body
    FROM pg_proc WHERE proname = 'player_swing';

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'the external stack is not where 0299 left it';
    END IF;

    -- BEFORE the stack is read, so a technique that rallies also swings
    -- rallied. A buff that took effect only from the next turn would make
    -- every opener strictly worse than casting it a turn earlier, which is
    -- not a decision, just a tax on not knowing.
    body := replace(body, anchor,
'    -- Whatever this technique leaves behind, left behind now: before the
    -- stack below is read, so a technique that rallies swings rallied too.
    PERFORM technique_cast_effects(p_player_id, p_technique_id,
                                   p_scope, p_scope_id);

' || anchor);

    EXECUTE body;
END;
$$;


-- ---------------------------------------------------------------------------
-- A malformed declaration is refused when it is written
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    t BIGINT;
BEGIN
    SELECT technique_id INTO t FROM techniques WHERE created_by IS NULL LIMIT 1;

    BEGIN
        -- A kind that does not exist.
        BEGIN
            UPDATE techniques
            SET effects = '{"apply":[{"code":"nonsense","magnitude":0.2,"turns":3}]}'
            WHERE technique_id = t;
            RAISE EXCEPTION 'a technique declared an effect kind that does not exist';
        EXCEPTION
            WHEN check_violation THEN NULL;
        END;

        -- Turns that are not whole.
        BEGIN
            UPDATE techniques
            SET effects = '{"apply":[{"code":"regen","magnitude":0.2,"turns":2.5}]}'
            WHERE technique_id = t;
            RAISE EXCEPTION 'a technique declared two and a half turns';
        EXCEPTION
            WHEN check_violation THEN NULL;
        END;

        -- A magnitude of nothing.
        BEGIN
            UPDATE techniques
            SET effects = '{"apply":[{"code":"regen","magnitude":0,"turns":3}]}'
            WHERE technique_id = t;
            RAISE EXCEPTION 'a technique declared an effect worth nothing';
        EXCEPTION
            WHEN check_violation THEN NULL;
        END;

        -- And a good one is accepted.
        UPDATE techniques
        SET effects = '{"apply":[{"code":"regen","magnitude":0.05,"turns":3}]}'
        WHERE technique_id = t;

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
-- And swinging one actually leaves it behind
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    who  BIGINT;
    move BIGINT;
    sp   BIGINT;
    held NUMERIC;
BEGIN
    SELECT p.player_id, dungeon_default_move(p.player_id) INTO who, move
    FROM players p
    WHERE p.deleted_at IS NULL AND dungeon_default_move(p.player_id) IS NOT NULL
    ORDER BY p.player_id LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'nobody can swing; the tests carry this';
        RETURN;
    END IF;

    SELECT species_id INTO sp FROM creature_species
    WHERE kind = 'beast' ORDER BY rank DESC LIMIT 1;

    BEGIN
        UPDATE techniques
        SET effects = '{"apply":[{"code":"defence_up","magnitude":0.25,"turns":3}]}'
        WHERE technique_id = move;

        PERFORM player_swing(who, move, sp, 1000000::bigint, 0::bigint,
                             NULL, NULL, 0, 'battle', -7);

        held := effect_value('battle', -7, who, 'defence_up');
        IF held <> 0.25 THEN
            RAISE EXCEPTION
                'swinging a warding technique left % behind, not 0.25', held;
        END IF;

        -- And a swing with no scope leaves nothing anywhere.
        PERFORM effect_clear('battle', -7);
        PERFORM player_swing(who, move, sp, 1000000::bigint, 0::bigint);
        IF EXISTS (SELECT 1 FROM battle_effects WHERE scope_id = -7) THEN
            RAISE EXCEPTION 'an unscoped swing left an effect somewhere';
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
