-- 0395_a_technique_is_worth_what_it_hits_for_today
--
-- `techniques.base_power` is a souvenir of the day a technique was made. What
-- a forged or fated technique actually hits for is recomputed from its grade
-- against the owner's CURRENT `player_power_multiple` every single swing -
-- that is the whole point of routing them through `technique_forges`, and 0370
-- says so out loud.
--
-- Five screens print the souvenir.
--
-- Measured across every forged technique alive right now, filed against live:
--
--     Ascendant Refinement Art   filed 28,663,349   hits 3,668,908,704   x128
--     Lesser Soul Art            filed 11,672,748   hits   747,055,874    x64
--     Crude Illusion Art         filed  3,780,487   hits   165,257,501    x44
--     Borrowed Flame             filed 1,852,204,646 hits 3,704,409,293    x2
--
-- So pashu0 opening the technique picker in a fight sees "power 28,663,349"
-- beside "power 1,852,204,646" and concludes the second is sixty-five times
-- the first. It is in fact the weaker of the two. Every one of those screens
-- is a choice being made on a number that has not been true since the day it
-- was written.
--
-- ONE DEFINITION, NOT SIX. The obvious fix is to paste the COALESCE out of
-- `compute_technique_damage` into five queries, and that is how a display and
-- an engine start disagreeing - the exact failure this migration exists to
-- undo. So the expression comes OUT of the damage function into
-- `technique_power_for`, and the damage function then calls it. There is one
-- place that knows what a technique is worth to somebody, and the screens and
-- the swing both ask it.
--
-- WHY IT TAKES A PLAYER. Because the answer depends on who is holding it. The
-- same row in `techniques` is worth 3.7 billion to pashu0 and nothing like it
-- to anybody else, and a function that took only a technique_id would be
-- answering a question nobody asked.
--
-- A canonical technique - one nobody forged - has no `technique_forges` row
-- and falls back to its written figure, which for those IS the true number and
-- always was. Nothing about Sovereign Immortal Killer Move changes.
--
-- Forward-only. Do not edit once applied.


CREATE FUNCTION technique_power_for(p_player_id BIGINT, p_technique_id BIGINT)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    -- Lifted verbatim out of `compute_technique_damage`, which now calls this
    -- rather than keeping its own copy. A forged or fated technique stores a
    -- GRADE; what it hits for is that grade against the realm and body of
    -- whoever is holding it right now. Anything nobody forged has no row here
    -- and is worth exactly what is written on it.
    SELECT COALESCE((
        SELECT LEAST(1000000000000000::numeric, round(
            game_config_value('technique_forge_power_base')
            * player_power_multiple(p_player_id) * f.power_grade))
        FROM technique_forges f
        WHERE f.technique_id = p_technique_id
    ), (SELECT t.base_power FROM techniques t
        WHERE t.technique_id = p_technique_id))::bigint;
$$;

COMMENT ON FUNCTION technique_power_for(BIGINT, BIGINT) IS
    'What a technique is worth to a particular cultivator today. The one place that knows; both the damage pipeline and every screen that prints a power ask it.';


-- ---------------------------------------------------------------------------
-- And the engine stops keeping its own copy
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'compute_technique_damage';

    IF body IS NULL THEN
        RAISE EXCEPTION 'compute_technique_damage is missing';
    END IF;

    anchor := concat(
'    tech_base := COALESCE((', chr(10),
'        SELECT LEAST(1000000000000000::numeric, round(', chr(10),
'            game_config_value(''technique_forge_power_base'')', chr(10),
'            * player_power_multiple(p_attacker_player_id) * f.power_grade))', chr(10),
'        FROM technique_forges f', chr(10),
'        WHERE f.technique_id = p_technique_id', chr(10),
'    ), tech_base)::bigint;');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION
            'compute_technique_damage no longer recomputes a forged power where it did';
    END IF;

    -- The STRICT read of `t.base_power` above this stays exactly where it is:
    -- it is what raises on a technique that does not exist, and this line only
    -- ever overwrote the value it found.
    EXECUTE replace(body, anchor,
        '    tech_base := technique_power_for(p_attacker_player_id, p_technique_id);');
END;
$patch$;


-- ---------------------------------------------------------------------------
-- The screens and the swing agree, on every technique anybody holds
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    r      RECORD;
    v_prey BIGINT;
    v_n    INTEGER := 0;
    v_lied INTEGER := 0;
    v_max  NUMERIC := 0;
BEGIN
    SELECT species_id INTO v_prey FROM creature_species
    WHERE kind = 'beast' ORDER BY rank LIMIT 1;

    -- THE INVARIANT: what the screens will now print is what the engine uses.
    -- Driven on every technique every live cultivator can actually swing,
    -- because "it agrees on the one I tried" is what the old code could also
    -- have claimed.
    FOR r IN
        SELECT p.player_id, p.discord_name, t.technique_id, t.name,
               t.base_power AS filed
        FROM players p
        JOIN player_usable_techniques u ON u.player_id = p.player_id
        JOIN techniques t ON t.technique_id = u.technique_id
        WHERE p.deleted_at IS NULL AND t.base_power > 0
    LOOP
        v_n := v_n + 1;

        IF technique_power_for(r.player_id, r.technique_id)
           <> (SELECT cd.base_power FROM compute_technique_damage(
                   r.player_id, r.technique_id, v_prey, 1::numeric, 0) cd) THEN
            RAISE EXCEPTION
                'the screen and the swing disagree about % for %',
                r.name, r.discord_name;
        END IF;

        -- And how far the old number was out, for the record.
        IF technique_power_for(r.player_id, r.technique_id) <> r.filed THEN
            v_lied := v_lied + 1;
            v_max := GREATEST(v_max,
                technique_power_for(r.player_id, r.technique_id)::numeric
                / GREATEST(1, r.filed));
        END IF;
    END LOOP;

    RAISE NOTICE
        '% held techniques checked; % were filed at the wrong figure, the worst by %x',
        v_n, v_lied, round(v_max, 1);

    -- A canonical technique is worth what is written on it, to anybody.
    FOR r IN
        SELECT t.technique_id, t.name, t.base_power
        FROM techniques t
        WHERE t.created_by IS NULL AND t.base_power > 0
        ORDER BY t.base_power DESC LIMIT 5
    LOOP
        IF technique_power_for(
               (SELECT player_id FROM players WHERE deleted_at IS NULL LIMIT 1),
               r.technique_id) <> r.base_power THEN
            RAISE EXCEPTION
                'a technique nobody forged stopped being worth what it says: %',
                r.name;
        END IF;
    END LOOP;

    RAISE NOTICE 'and a technique nobody forged still reads as written';
END;
$probe$;
