-- 0247_the_world_boss_joins_the_rest
--
-- `/boss` is the fifth fight, and it got neither of the two fixes.
--
-- 0225 found six offensive axes read only by `battle_act` and made
-- `player_swing` the one blow; 0243 did the same for the four defensive ones
-- with `player_take`. Both migrations pointed the duel, the dungeon and the
-- two horde lanes at them. `strike_boss` was in neither list, and I did not
-- notice because I searched for functions that READ the effect names -
-- `strike_boss` reads none of them, which is exactly the symptom.
--
-- So on a world boss a cultivator gets Attack Power, their manual, their path
-- bonuses and their Strength, and none of: Extra Strikes, Criticals, Armour
-- Penetration, Life Steal, Momentum, Cornered Strength. The boss then hits
-- back for a raw number, so Evasion, Damage Reduction, Braced and the Death
-- Ward do nothing either. Half a build, on the one fight the whole server
-- turns up to.
--
-- THE POOL HAS TO MOVE WITH IT. `boss_hp_pool` sizes the boss by summing what
-- each active cultivator's best technique lands for, and it measures that with
-- `compute_technique_damage` - the number BEFORE the per-blow axes. Making
-- swings land half again as hard without telling the pool would just make
-- world bosses shorter. So the pool multiplies by what a blow is actually
-- worth now.
--
-- `player_blow_multiple` is that number, and it is deliberately an EXPECTATION
-- rather than a swing: the pool is STABLE and must not roll dice, and a boss
-- whose health depended on how somebody's criticals happened to land would be
-- a different size every time it was looked at.
--
-- THE PICK STAYS DETERMINISTIC. `strike_boss` chooses which technique to throw
-- by asking `compute_technique_damage` which lands hardest. That must not
-- become a dice roll or the game would pick a different move each press, so
-- the pick keeps the old call and only the blow itself changes.
--
-- Defence is passed as 0, exactly as before. A world boss has never subtracted
-- its own defence and this migration is not the place to decide it should -
-- which does mean Armour Penetration is still inert here specifically.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE boss_strikes ADD COLUMN ward_used BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN boss_strikes.ward_used IS
    'Death Ward fires once per encounter. Without somewhere to write that, it would fire on every blow of a fight that lasts hours.';


-- ---------------------------------------------------------------------------
-- What a blow is worth, in expectation
-- ---------------------------------------------------------------------------

CREATE FUNCTION player_blow_multiple(p_player_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    SELECT
        -- An extra strike per point of multi_hit, each landing at
        -- `gu_multi_hit_power` of the first.
        (1 + player_stat(p_player_id, 'multi_hit')
             * game_config_value('gu_multi_hit_power'))
        -- And every strike crits with this chance, for this much more.
        * (1 + player_stat(p_player_id, 'crit_rate')
               * (game_config_value('gu_crit_damage_base')
                  + player_stat(p_player_id, 'crit_damage')));
$$;

COMMENT ON FUNCTION player_blow_multiple(BIGINT) IS
    'How much more a blow is worth than the pipeline number, on average, once extra strikes and criticals are counted. An expectation on purpose - anything sizing a fight has to be STABLE and must not roll dice.';


-- ---------------------------------------------------------------------------
-- The boss is sized against what a blow now does
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION boss_hp_pool(p_species_id BIGINT)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT GREATEST(
        game_config_value('boss_hp_floor'),
        round(COALESCE((
            SELECT sum(best.dealt * player_blow_multiple(p.player_id))
            FROM players p
            JOIN LATERAL (
                -- The same pick `strike_boss` makes: the move that actually
                -- lands hardest, not the one with the biggest number on it.
                SELECT max(would.final_damage) AS dealt
                FROM player_usable_techniques u
                JOIN techniques t ON t.technique_id = u.technique_id
                CROSS JOIN LATERAL compute_technique_damage(
                    p.player_id, t.technique_id, p_species_id,
                    player_external_multiplier(p.player_id, t.technique_id),
                    0) AS would
                WHERE u.player_id = p.player_id AND t.base_power > 0
            ) best ON best.dealt IS NOT NULL AND best.dealt > 0
            WHERE p.deleted_at IS NULL
              AND p.last_seen_at >= now() - interval '7 days'
        ), 0)
        * game_config_value('boss_swings_expected')
        * game_config_value('boss_effort'))
    )::bigint;
$$;


-- ---------------------------------------------------------------------------
-- And the blow itself is the one every other fight makes
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc WHERE proname = 'strike_boss';

    -- ---- the swing ------------------------------------------------------
    old := '    SELECT * INTO hit FROM compute_technique_damage(
        p_player_id, move, live.species_id,
        player_external_multiplier(p_player_id, move), 0);

    IF hit.final_damage <= 0 THEN';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'strike_boss no longer swings the old way';
    END IF;

    src := replace(src, old,
'    -- The blow every other fight makes. Before 0247 this called the pipeline
    -- straight, so Extra Strikes, Criticals, Life Steal, Momentum and a
    -- cornered body did nothing at all against the one thing the whole server
    -- turns up for. Defence stays 0, as it always has been here.
    SELECT * INTO swung FROM player_swing(
        p_player_id, move, live.species_id, live.current_hp, 0::bigint,
        body.current_hp, body.max_hp, 1);

    hit := swung;

    IF swung.dealt <= 0 THEN');

    -- Everything downstream read hit.final_damage; it reads the swing now.
    src := replace(src, 'left_hp := GREATEST(0, live.current_hp - hit.final_damage);',
                        'left_hp := GREATEST(0, swung.hp_left);');
    src := replace(src, 'VALUES (live.encounter_id, p_player_id, 1, hit.final_damage, back)',
                        'VALUES (live.encounter_id, p_player_id, 1, swung.dealt, back)');
    src := replace(src, '        hit.final_damage, back, hit.matchup_modifier,',
                        '        swung.dealt, back, chosen_matchup,');

    -- ---- the answer ------------------------------------------------------
    old := '        SELECT LEAST(
                   gc.final_damage,
                   GREATEST(1, floor(body.max_hp
                                     * game_config_value(''boss_bite_cap'')))
               )::bigint
        INTO back
        FROM compute_creature_damage(live.species_id, p_player_id) gc;';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'strike_boss no longer takes the answer the old way';
    END IF;

    src := replace(src, old,
'        -- Through the cultivator''s own defences, which this fight ignored
        -- entirely: a raw number came off a body that had paid for Evasion,
        -- Damage Reduction and a Death Ward.
        SELECT LEAST(
                   gc.final_damage,
                   GREATEST(1, floor(body.max_hp
                                     * game_config_value(''boss_bite_cap'')))
               )::bigint
        INTO raw_bite
        FROM compute_creature_damage(live.species_id, p_player_id) gc;

        SELECT * INTO took FROM player_take(
            p_player_id, raw_bite, body.current_hp, body.max_hp, FALSE,
            NOT COALESCE((SELECT bs.ward_used FROM boss_strikes bs
                          WHERE bs.encounter_id = live.encounter_id
                            AND bs.player_id = p_player_id), FALSE));

        back := took.taken;

        IF took.warded THEN
            UPDATE boss_strikes bs SET ward_used = TRUE
            WHERE bs.encounter_id = live.encounter_id
              AND bs.player_id = p_player_id;
        END IF;');

    -- ---- and life steal has a body to give back to -----------------------
    old := '        UPDATE player_physique pp
        SET current_hp = GREATEST(0, pp.current_hp - back)
        WHERE pp.player_id = p_player_id
        RETURNING pp.current_hp INTO body.current_hp;';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'strike_boss no longer writes the body the old way';
    END IF;

    src := replace(src, old,
'        UPDATE player_physique pp
        SET current_hp = LEAST(pp.max_hp,
                               GREATEST(0, pp.current_hp - back) + swung.healed)
        WHERE pp.player_id = p_player_id
        RETURNING pp.current_hp INTO body.current_hp;');

    -- ---- the declarations it now needs ------------------------------------
    old := '    hit       RECORD;';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'strike_boss no longer declares its hit';
    END IF;
    src := replace(src, old,
'    hit       RECORD;
    swung     RECORD;
    took      RECORD;
    raw_bite  BIGINT := 0;
    chosen_matchup NUMERIC := 0;');

    -- The matchup is still worth reporting, and the swing does not carry it -
    -- so it is read off the same deterministic pick that chose the move.
    old := '    IF move IS NULL THEN';
    src := replace(src, old,
'    SELECT c.matchup_modifier INTO chosen_matchup
    FROM compute_technique_damage(
        p_player_id, move, live.species_id, 1, 0) c;

    IF move IS NULL THEN');

    EXECUTE src;
END;
$$;


DO $$
DECLARE
    body TEXT;
BEGIN
    SELECT prosrc INTO body FROM pg_proc WHERE proname = 'strike_boss';

    IF position('player_swing(' IN body) = 0 THEN
        RAISE EXCEPTION 'the world boss still swings on its own';
    END IF;
    IF position('player_take(' IN body) = 0 THEN
        RAISE EXCEPTION 'the world boss still takes a blow on its own';
    END IF;

    -- Every fight that can hurt a cultivator, through both halves.
    IF EXISTS (
        SELECT 1 FROM unnest(ARRAY['battle_act', 'dungeon_resolve_round',
                                   'horde_strike', 'horde_gauntlet_swing',
                                   'strike_boss']) f
        WHERE position('player_swing(' IN
                       (SELECT prosrc FROM pg_proc WHERE proname = f)) = 0
    ) THEN
        RAISE EXCEPTION 'a fight is still computing its own swing';
    END IF;

    -- And the pool measures what a blow is now worth.
    IF position('player_blow_multiple' IN
                (SELECT prosrc FROM pg_proc WHERE proname = 'boss_hp_pool')) = 0 THEN
        RAISE EXCEPTION 'the boss is still sized against the old blow';
    END IF;
END;
$$;
