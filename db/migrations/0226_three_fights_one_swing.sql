-- 0226_three_fights_one_swing
--
-- 0225 built `player_swing`. This is the part that matters: the three places
-- that hit things all call it, so there is one implementation rather than one
-- good one and two that quietly drop half the build.
--
-- `battle_act` keeps its per-strike `battle_actions` rows - it just writes
-- them from the blow-by-blow the swing hands back instead of from its own
-- loop. The duel's numbers do not change; the same reads happen in the same
-- order behind one door instead of two.
--
-- `dungeon_resolve_round` gains all six axes at once. A raider with Life Steal
-- now takes health back off a boss, and a multi-hit build strikes more than
-- once in a room it was built for.
--
-- `horde_strike` gains five of them and turns the sixth into contribution: a
-- channel has no body to drain, so life steal is recorded as healing done,
-- which the roll already counts at double.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- The duel
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    src TEXT;
    old TEXT;
    new TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc WHERE proname = 'battle_act';

    old := '        pen       := player_stat(me.player_id, ''armor_pen'');
        mh        := player_stat(me.player_id, ''multi_hit'');
        crit_pct  := player_stat(me.player_id, ''crit_rate'');
        crit_mult := 1 + game_config_value(''gu_crit_damage_base'')
                       + player_stat(me.player_id, ''crit_damage'');
        steal     := player_stat(me.player_id, ''lifesteal'');';

    new := '        -- Everything a blow does now lives in `player_swing`, so the
        -- dungeon and the horde read the same six axes this does. What is
        -- left here is the duel''''s own business: qi, the log, the reply.
        SELECT * INTO swung FROM player_swing(
            me.player_id, p_technique_id, it.species_id,
            c_hp, (it.snapshot ->> ''base_defense'')::bigint,
            p_hp, me.max_hp, fight.turn_number);

        pen       := (swung.blows -> 0 ->> ''armor_pen'')::numeric;
        n_strikes := swung.strikes;
        n_crits   := swung.crits;
        external  := COALESCE((swung.blows -> 0 ->> ''external'')::numeric, 0);
        dmg_out   := swung.dealt;
        c_hp      := swung.hp_left;
        steal     := player_stat(me.player_id, ''lifesteal'');';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'battle_act no longer reads the build the old way';
    END IF;
    src := replace(src, old, new);

    -- The loop becomes a walk over what the swing already did.
    old := '        -- Penetration is applied to the defence the pipeline subtracts, which
        -- is why it matters most to a build that strikes several times.
        eff_def := GREATEST(0, round((it.snapshot ->> ''base_defense'')::numeric * (1 - pen)));

        -- One strike, plus a whole one per point of multi-hit, plus a roll for
        -- the remainder.
        n_strikes := 1 + floor(mh)::int + CASE WHEN random() < (mh - floor(mh)) THEN 1 ELSE 0 END;

        -- Momentum builds with the fight and a cornered body hits harder.
        -- Both join the external stack, which is a sum.
        mom := player_stat(me.player_id, ''momentum'');
        IF mom > 0 THEN
            mom := LEAST((SELECT ef.cap FROM gu_effects ef WHERE ef.code = ''momentum''),
                         mom * GREATEST(0, fight.turn_number - 1));
        END IF;
        IF p_hp * 2 <= me.max_hp THEN
            wounded := player_stat(me.player_id, ''wounded_power'');
        END IF;

        external := player_external_multiplier(me.player_id, p_technique_id)
                    + mom + wounded;

        FOR strike IN 1..n_strikes LOOP
            EXIT WHEN c_hp <= 0;

            SELECT * INTO hit FROM compute_technique_damage(
                me.player_id, p_technique_id, it.species_id, external, eff_def);

            one_hit := hit.final_damage;
            IF strike > 1 THEN
                one_hit := GREATEST(0, floor(one_hit * game_config_value(''gu_multi_hit_power'')));
            END IF;
            IF random() < crit_pct THEN
                one_hit := floor(one_hit * crit_mult);
                n_crits := n_crits + 1;
            END IF;

            c_hp    := GREATEST(0, c_hp - one_hit);
            dmg_out := dmg_out + one_hit;

            INSERT INTO battle_actions
                (battle_id, actor_no, turn_number, action, technique_id, technique_name,
                 target_no, base_power, attainment_bonus, matchup_modifier, damage, detail)
            VALUES (p_battle_id, 0, fight.turn_number, ''technique'', p_technique_id,
                    tech.name, 1,
                    hit.base_power, hit.attainment_bonus, hit.matchup_modifier, one_hit,
                    jsonb_build_object(''external'', external, ''qi_spent'',
                                       CASE WHEN strike = 1 THEN cost ELSE 0 END,
                                       ''strike'', strike, ''of'', n_strikes,
                                       ''armor_pen'', pen,
                                       ''target_hp_after'', c_hp));
        END LOOP;';

    new := '        -- One row a strike, written from the blow-by-blow rather than
        -- from a second loop that would have to stay in step with the first.
        INSERT INTO battle_actions
            (battle_id, actor_no, turn_number, action, technique_id, technique_name,
             target_no, base_power, attainment_bonus, matchup_modifier, damage, detail)
        SELECT p_battle_id, 0, fight.turn_number, ''technique'', p_technique_id,
               tech.name, 1,
               (b ->> ''base_power'')::integer,
               (b ->> ''attainment_bonus'')::numeric,
               (b ->> ''matchup_modifier'')::numeric,
               (b ->> ''damage'')::bigint,
               b || jsonb_build_object(''qi_spent'',
                        CASE WHEN (b ->> ''strike'')::int = 1 THEN cost ELSE 0 END)
        FROM jsonb_array_elements(swung.blows) AS b;';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'battle_act no longer strikes the old way';
    END IF;
    src := replace(src, old, new);

    -- And the life steal it already had, taken from the same result.
    old := '        IF steal > 0 AND dmg_out > 0 THEN
            healed_by := LEAST(
                floor(dmg_out * steal),
                GREATEST(0, me.max_hp - p_hp)
            );
            p_hp := p_hp + healed_by;
        END IF;';
    new := '        healed_by := swung.healed;
        p_hp := p_hp + healed_by;';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'battle_act no longer steals the old way';
    END IF;
    src := replace(src, old, new);

    -- The one new local it needs.
    old := '    one_hit    BIGINT;';
    new := '    one_hit    BIGINT;
    swung      RECORD;';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'battle_act no longer declares its per-strike damage';
    END IF;
    src := replace(src, old, new);

    EXECUTE src;
END;
$$;


-- ---------------------------------------------------------------------------
-- The dungeon
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    src TEXT;
    old TEXT;
    new TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'dungeon_resolve_round';

    old := '        SELECT * INTO hit FROM compute_technique_damage(
            one.player_id, move, run.species_id,
            player_external_multiplier(one.player_id, move),
            (SELECT s.base_defense FROM creature_species s
             WHERE s.species_id = run.species_id)::bigint);

        dealt := GREATEST(0, hit.final_damage);';

    new := '        -- The whole build, not just the technique. Before 0226 this
        -- called `compute_technique_damage` straight and a raider''''s Life
        -- Steal, extra strikes, criticals and penetration did nothing at all
        -- in the room they were assembled for.
        SELECT * INTO swung FROM player_swing(
            one.player_id, move, run.species_id,
            run.boss_hp,
            (SELECT s.base_defense FROM creature_species s
             WHERE s.species_id = run.species_id)::bigint,
            one.current_hp, one.max_hp, run.round_no::integer);

        dealt := GREATEST(0, swung.dealt);

        -- What the blow took back. A raider at full health steals nothing,
        -- which is the same rule a duel keeps.
        IF swung.healed > 0 THEN
            UPDATE dungeon_raiders x
            SET current_hp = LEAST(x.max_hp, x.current_hp + swung.healed)
            WHERE x.run_id = p_run_id AND x.player_id = one.player_id;
        END IF;';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'dungeon_resolve_round no longer computes damage the old way';
    END IF;
    src := replace(src, old, new);

    -- The loop never read a body. Life steal has to be capped by the room
    -- there is in one, and a cornered raider hits harder.
    old := '        SELECT x.player_id, x.intent_id, p.discord_name';
    new := '        SELECT x.player_id, x.intent_id, x.current_hp, x.max_hp,
               p.discord_name';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'dungeon_resolve_round no longer reads its raiders the old way';
    END IF;
    src := replace(src, old, new);

    old := '    hit     RECORD;';
    new := '    hit     RECORD;
    swung   RECORD;';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'dungeon_resolve_round no longer declares its hit';
    END IF;

    EXECUTE replace(src, old, new);
END;
$$;


-- ---------------------------------------------------------------------------
-- The horde
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION horde_strike(p_encounter_id BIGINT, p_player_id BIGINT)
RETURNS TABLE (
    dealt      BIGINT,
    hp_left    BIGINT,
    max_hp     BIGINT,
    killed     BOOLEAN,
    beast_name TEXT,
    kind       TEXT,
    bounty     BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    met    RECORD;
    move   BIGINT;
    swung  RECORD;
    hurt   BIGINT;
    down   BOOLEAN := FALSE;
    paid   BIGINT := 0;
    drain  BIGINT := 0;
BEGIN
    SELECT e.*, cs.name AS species_name, cs.base_defense, cs.rank AS species_rank,
           h.status AS tide_status
    INTO met
    FROM horde_encounters e
    JOIN creature_species cs ON cs.species_id = e.species_id
    JOIN beast_hordes h ON h.horde_id = e.horde_id
    WHERE e.encounter_id = p_encounter_id
    FOR UPDATE OF e;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'there is nothing there' USING ERRCODE = 'check_violation';
    END IF;
    IF met.status <> 'alive' THEN
        RAISE EXCEPTION 'that one is already down' USING ERRCODE = 'check_violation';
    END IF;
    IF met.tide_status <> 'fighting' THEN
        RAISE EXCEPTION 'the tide has broken off' USING ERRCODE = 'check_violation';
    END IF;
    IF met.expires_at <= now() THEN
        RAISE EXCEPTION 'it is already through the line'
            USING ERRCODE = 'check_violation';
    END IF;

    move := dungeon_default_move(p_player_id);
    IF move IS NULL THEN
        RAISE EXCEPTION 'you have nothing to swing - learn a technique with /learn first'
            USING ERRCODE = 'check_violation';
    END IF;

    -- The same swing a duel and a dungeon round make. No body is passed
    -- because nobody has one in a channel; the steal comes back uncapped and
    -- is counted rather than healed.
    SELECT * INTO swung FROM player_swing(
        p_player_id, move, met.species_id, met.hp, met.base_defense::bigint);

    hurt  := GREATEST(1, swung.dealt);
    drain := swung.healed;
    down  := hurt >= met.hp;

    UPDATE horde_encounters e
    SET hp = GREATEST(0, e.hp - hurt),
        status = CASE WHEN down THEN 'slain' ELSE e.status END,
        slain_by = CASE WHEN down THEN p_player_id ELSE e.slain_by END,
        settled_at = CASE WHEN down THEN now() ELSE e.settled_at END
    WHERE e.encounter_id = p_encounter_id;

    IF down THEN
        paid := round(game_config_value('horde_slay_bounty')
                      * GREATEST(1, met.species_rank))::bigint;

        UPDATE beast_hordes h
        SET beasts_slain = h.beasts_slain + 1
        WHERE h.horde_id = met.horde_id;
    END IF;

    INSERT INTO horde_contributions
        (horde_id, player_id, damage_dealt, healing_done, beasts_slain,
         elites_slain, last_swing_at)
    VALUES (met.horde_id, p_player_id, hurt + paid, drain,
            CASE WHEN down AND met.kind = 'normal' THEN 1 ELSE 0 END,
            CASE WHEN down AND met.kind = 'elite'  THEN 1 ELSE 0 END,
            now())
    ON CONFLICT (horde_id, player_id) DO UPDATE
        SET damage_dealt  = horde_contributions.damage_dealt + hurt + paid,
            healing_done  = horde_contributions.healing_done + drain,
            beasts_slain  = horde_contributions.beasts_slain
                            + CASE WHEN down AND met.kind = 'normal' THEN 1 ELSE 0 END,
            elites_slain  = horde_contributions.elites_slain
                            + CASE WHEN down AND met.kind = 'elite' THEN 1 ELSE 0 END,
            last_swing_at = now();

    RETURN QUERY SELECT hurt,
                        GREATEST(0, met.hp - hurt), met.max_hp, down,
                        met.species_name, met.kind, paid;
END;
$$;


-- ---------------------------------------------------------------------------
-- Asking all three whether they know about the build now
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    n INTEGER;
BEGIN
    -- Nothing but the swing may read these six. A second reader is a second
    -- opinion, which is how this bug happened in the first place.
    SELECT count(*) INTO n
    FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
    WHERE ns.nspname = 'public'
      AND p.proname NOT IN ('player_swing', 'player_gu_stats')
      AND (p.prosrc LIKE '%''multi_hit''%' OR p.prosrc LIKE '%''crit_rate''%');
    IF n > 0 THEN
        RAISE EXCEPTION '% functions besides the swing still read the build', n;
    END IF;

    -- And all three fights call it.
    FOR n IN
        SELECT 1 FROM (VALUES ('battle_act'), ('dungeon_resolve_round'),
                              ('horde_strike')) AS f(name)
        WHERE NOT EXISTS (
            SELECT 1 FROM pg_proc p
            WHERE p.proname = f.name AND p.prosrc LIKE '%player_swing(%')
    LOOP
        RAISE EXCEPTION 'a fight still swings on its own';
    END LOOP;
END;
$$;
