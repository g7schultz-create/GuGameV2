-- 0277_the_beast_at_heel_swings_too
--
-- Five lanes land a cultivator's blow - the hunt duel, a dungeon round, a
-- gauntlet wave, a channel beast and the world boss - and every one of them
-- does it by calling `player_swing`. 0243 and 0247 spent two migrations making
-- that true, so a pet joining the fight is one change here rather than five
-- copies of the same edit in five different screens.
--
-- The beast at heel swings after its owner, at the same target, and what it
-- takes off is added to the same wound. Everything a lane already does with
-- `dealt` - contribution, the pot, whether the thing falls over - counts it
-- without knowing pets exist.
--
-- It comes back as its own column as well, because a screen that says "you
-- dealt 3,400,000" when a fifth of it was the wolf is lying to the player
-- about their build. Lanes may report it separately; none of them has to.
--
-- Appended to the end of the return, so `SELECT * INTO swung` in all five
-- callers keeps working untouched.
--
-- ONE THING THIS DELIBERATELY BREAKS AND THEN MENDS: `boss_hp_pool` sizes a
-- world beast by summing what every cultivator can deal, straight from
-- `compute_technique_damage`. A pet's blow is not in there, so bosses would
-- have been undersized by exactly the amount pets contribute - invisibly,
-- because the pool would still look right. It counts them now.
--
-- Forward-only. Do not edit once applied.


DROP FUNCTION player_swing(BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, INTEGER);

CREATE FUNCTION player_swing(
    p_player_id     BIGINT,
    p_technique_id  BIGINT,
    p_species_id    BIGINT,
    p_target_hp     BIGINT,
    p_target_def    BIGINT,
    p_player_hp     BIGINT DEFAULT NULL,
    p_player_max_hp BIGINT DEFAULT NULL,
    p_turn          INTEGER DEFAULT 0
)
RETURNS TABLE (
    dealt     BIGINT,
    strikes   SMALLINT,
    crits     SMALLINT,
    healed    BIGINT,
    hp_left   BIGINT,
    blows     JSONB,
    pet_dealt BIGINT,
    pet_name  TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    pen       NUMERIC;
    mh        NUMERIC;
    crit_pct  NUMERIC;
    crit_mult NUMERIC;
    steal     NUMERIC;
    mom       NUMERIC := 0;
    wounded   NUMERIC := 0;
    external  NUMERIC;
    eff_def   BIGINT;
    n_strikes SMALLINT;
    n_crits   SMALLINT := 0;
    out_dmg   BIGINT := 0;
    left_hp   BIGINT := p_target_hp;
    got_back  BIGINT := 0;
    landed    INTEGER := 0;
    log       JSONB := '[]'::jsonb;
    hit       RECORD;
    one_hit   BIGINT;
    strike    INTEGER;
    beast     BIGINT;
    beast_hit BIGINT := 0;
    beast_nm  TEXT;
BEGIN
    pen       := player_stat(p_player_id, 'armor_pen');
    mh        := player_stat(p_player_id, 'multi_hit');
    crit_pct  := player_stat(p_player_id, 'crit_rate');
    crit_mult := 1 + game_config_value('gu_crit_damage_base')
                   + player_stat(p_player_id, 'crit_damage');
    steal     := player_stat(p_player_id, 'lifesteal');

    eff_def := GREATEST(0, round(COALESCE(p_target_def, 0) * (1 - pen)));

    n_strikes := (1 + floor(mh)::int
                  + CASE WHEN random() < (mh - floor(mh)) THEN 1 ELSE 0 END)::smallint;

    mom := player_stat(p_player_id, 'momentum');
    IF mom > 0 AND p_turn > 0 THEN
        mom := mom * LEAST(p_turn, game_config_value('momentum_turn_cap'));
    ELSE
        mom := 0;
    END IF;

    IF p_player_hp IS NOT NULL AND p_player_max_hp IS NOT NULL
       AND p_player_max_hp > 0
       AND p_player_hp::numeric / p_player_max_hp
           <= game_config_value('cornered_threshold') THEN
        wounded := player_stat(p_player_id, 'cornered');
    END IF;

    external := player_external_multiplier(p_player_id, p_technique_id)
                + mom + wounded;

    FOR strike IN 1..n_strikes LOOP
        EXIT WHEN left_hp <= 0;
        landed := landed + 1;

        SELECT * INTO hit FROM compute_technique_damage(
            p_player_id, p_technique_id, p_species_id, external, eff_def);

        one_hit := hit.final_damage;

        IF strike > 1 THEN
            one_hit := GREATEST(1, round(
                one_hit * game_config_value('gu_multi_hit_power')))::bigint;
        END IF;

        IF random() < crit_pct THEN
            one_hit := GREATEST(1, round(one_hit * crit_mult))::bigint;
            n_crits := n_crits + 1;
        END IF;

        out_dmg := out_dmg + one_hit;
        left_hp := GREATEST(0, left_hp - one_hit);

        log := log || jsonb_build_object(
            'strike', strike,
            'damage', one_hit,
            'crit', n_crits > 0 AND strike = n_strikes,
            'base_power', hit.base_power,
            'attainment_bonus', hit.attainment_bonus,
            'matchup_modifier', hit.matchup_modifier,
            'external', external,
            'armor_pen', pen,
            'target_hp_after', left_hp);
    END LOOP;

    -- ---- and the beast beside them ---------------------------------------
    -- After its owner, at the same target, and only if there is anything left
    -- standing to bite. Its blow is its own - its species, its tier, its Path
    -- against the defender's - and it is added to the same wound so every
    -- lane counts it without knowing pets exist.
    beast := pet_at_heel(p_player_id);
    IF beast IS NOT NULL AND left_hp > 0 THEN
        beast_hit := pet_blow(beast, p_species_id, eff_def);
        IF beast_hit > 0 THEN
            beast_hit := LEAST(beast_hit, left_hp);
            out_dmg   := out_dmg + beast_hit;
            left_hp   := GREATEST(0, left_hp - beast_hit);

            SELECT b.name INTO beast_nm FROM player_beasts b
            WHERE b.beast_id = beast;

            log := log || jsonb_build_object(
                'strike', 'pet',
                'damage', beast_hit,
                'pet', beast_nm,
                'target_hp_after', left_hp);
        END IF;
    END IF;

    IF steal > 0 AND landed > 0 THEN
        got_back := GREATEST(landed, floor(
            COALESCE(p_player_max_hp,
                     (SELECT pp.max_hp FROM player_physique pp
                      WHERE pp.player_id = p_player_id), 0)
            * steal * game_config_value('life_on_hit_rate') * landed));
        IF p_player_hp IS NOT NULL AND p_player_max_hp IS NOT NULL THEN
            got_back := LEAST(got_back, GREATEST(0, p_player_max_hp - p_player_hp));
        END IF;
    END IF;

    RETURN QUERY SELECT out_dmg, n_strikes, n_crits, got_back, left_hp, log,
                        beast_hit, beast_nm;
END;
$$;

COMMENT ON FUNCTION player_swing(BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, INTEGER) IS
    'One blow, wherever it is thrown, and the beast at heel swinging after it. Every lane calls this, which is why a pet joining the fight was one change rather than five.';


-- ---------------------------------------------------------------------------
-- A world beast is sized against the pets as well
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src
    FROM pg_proc WHERE proname = 'boss_hp_pool';

    old := '            SELECT sum(best.dealt * player_blow_multiple(p.player_id))';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'boss_hp_pool no longer sums what the roster deals';
    END IF;

    src := replace(src, old,
'            -- Plus whatever walks in beside them. A pet''s blow is not in
            -- `player_usable_techniques`, so without this a beast would be
            -- sized against the roster''s techniques alone and come out short
            -- by exactly what the pets add - invisibly, because the pool
            -- would still look right.
            SELECT sum(best.dealt * player_blow_multiple(p.player_id)
                       + COALESCE(pet_blow(pet_at_heel(p.player_id),
                                           p_species_id, 0), 0))');

    EXECUTE src;
END;
$$;


-- ---------------------------------------------------------------------------
-- The beast is felt in every lane, because there is only one place to feel it
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    who    BIGINT;
    beast  BIGINT;
    move   BIGINT;
    target BIGINT;
    alone  RECORD;
    withit RECORD;
BEGIN
    SELECT b.owner_id, b.beast_id INTO who, beast
    FROM player_beasts b
    JOIN players p ON p.player_id = b.owner_id
    WHERE b.at_heel AND p.deleted_at IS NULL
      AND dungeon_default_move(b.owner_id) IS NOT NULL
    LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'nobody has a beast at heel yet; the tests carry this';
        RETURN;
    END IF;

    BEGIN
        move   := dungeon_default_move(who);
        SELECT cs.species_id INTO target
        FROM creature_species cs WHERE cs.kind = 'beast' ORDER BY cs.rank LIMIT 1;

        SELECT * INTO withit FROM player_swing(
            who, move, target, 99999999999::bigint, 0::bigint, NULL, NULL, 0);

        IF withit.pet_dealt <= 0 THEN
            RAISE EXCEPTION 'the beast at heel did not swing';
        END IF;
        IF withit.pet_name IS NULL THEN
            RAISE EXCEPTION 'the blow came from nobody';
        END IF;

        -- Sent away, and the swing is the cultivator's alone again.
        UPDATE player_beasts SET at_heel = FALSE WHERE beast_id = beast;

        SELECT * INTO alone FROM player_swing(
            who, move, target, 99999999999::bigint, 0::bigint, NULL, NULL, 0);

        IF alone.pet_dealt <> 0 THEN
            RAISE EXCEPTION 'a beast that was sent away still swung';
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
