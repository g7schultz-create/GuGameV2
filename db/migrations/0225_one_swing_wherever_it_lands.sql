-- 0225_one_swing_wherever_it_lands
--
-- Life steal does nothing in a dungeon. Neither does extra strikes, nor
-- criticals, nor armour penetration, nor momentum, nor cornered strength.
--
-- Six of the game's build axes are read in exactly one place - `battle_act` -
-- and every other thing a cultivator can hit calls `compute_technique_damage`
-- straight, which knows about none of them. So a Gu that says Life Steal 8%
-- steals nothing off a dungeon boss, and a build assembled around extra
-- strikes strikes once. The screens all promise it; two of the three fights in
-- this game quietly do not deliver it.
--
-- This is the failure this project keeps finding written a third time: two
-- places deciding one thing, and only one of them told. 0036 built the effects
-- as a vocabulary the combat code reads; the combat code turned out to be one
-- function, and the dungeon and the horde grew their own.
--
-- SO THE SWING IS ONE FUNCTION NOW. `player_swing` is what a cultivator's blow
-- does to something - penetration off the defence, the extra strikes, the
-- criticals, the life steal, momentum and a cornered body - and `battle_act`,
-- `dungeon_resolve_round` and `horde_strike` all call it. Adding a seventh
-- axis means editing one place and three fights gain it.
--
-- IT RETURNS ITS OWN LOG. `battle_act` writes a `battle_actions` row per
-- strike and would have had to keep its loop to do that, which would have left
-- two loops again. So the swing hands back a blow-by-blow and the duel writes
-- rows from it. The dungeon and the horde ignore it, which is what a log is
-- for.
--
-- WHAT LIFE STEAL DOES IN A CHANNEL. Nothing has a body to drain in a Beast
-- Horde - nobody takes damage there, on purpose, because a public two-hour
-- event that could cost a cultivator their progress is a trap rather than an
-- invitation. So a horde swing's life steal is recorded as healing done, which
-- is the axis contribution already counts at double. A Blood path defender is
-- paid for the same thing they would be paid for anywhere else.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- One swing
-- ---------------------------------------------------------------------------

CREATE FUNCTION player_swing(
    p_player_id     BIGINT,
    p_technique_id  BIGINT,
    p_species_id    BIGINT,
    p_target_hp     BIGINT,
    p_target_def    BIGINT,
    p_player_hp     BIGINT  DEFAULT NULL,
    p_player_max_hp BIGINT  DEFAULT NULL,
    p_turn          INTEGER DEFAULT 0
)
RETURNS TABLE (
    dealt    BIGINT,
    strikes  SMALLINT,
    crits    SMALLINT,
    healed   BIGINT,
    hp_left  BIGINT,
    blows    JSONB
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
    log       JSONB := '[]'::jsonb;
    hit       RECORD;
    one_hit   BIGINT;
    strike    INTEGER;
BEGIN
    pen       := player_stat(p_player_id, 'armor_pen');
    mh        := player_stat(p_player_id, 'multi_hit');
    crit_pct  := player_stat(p_player_id, 'crit_rate');
    crit_mult := 1 + game_config_value('gu_crit_damage_base')
                   + player_stat(p_player_id, 'crit_damage');
    steal     := player_stat(p_player_id, 'lifesteal');

    -- Penetration is applied to the defence the pipeline subtracts, which is
    -- why it matters most to a build that strikes several times.
    eff_def := GREATEST(0, round(COALESCE(p_target_def, 0) * (1 - pen)));

    -- One strike, plus a whole one per point of multi-hit, plus a roll for the
    -- remainder.
    n_strikes := (1 + floor(mh)::int
                  + CASE WHEN random() < (mh - floor(mh)) THEN 1 ELSE 0 END)::smallint;

    -- Momentum builds with the fight and a cornered body hits harder. Both
    -- join the external stack, which is a sum. A fight with no turn count -
    -- a horde beast, a dungeon round - simply has no momentum to build.
    mom := player_stat(p_player_id, 'momentum');
    IF mom > 0 AND p_turn > 0 THEN
        mom := LEAST((SELECT ef.cap FROM gu_effects ef WHERE ef.code = 'momentum'),
                     mom * GREATEST(0, p_turn - 1));
    ELSE
        mom := 0;
    END IF;

    -- And a body that is not being tracked cannot be cornered.
    IF p_player_hp IS NOT NULL AND p_player_max_hp IS NOT NULL
       AND p_player_hp * 2 <= p_player_max_hp THEN
        wounded := player_stat(p_player_id, 'wounded_power');
    END IF;

    external := player_external_multiplier(p_player_id, p_technique_id)
                + mom + wounded;

    FOR strike IN 1..n_strikes LOOP
        EXIT WHEN left_hp <= 0;

        SELECT * INTO hit FROM compute_technique_damage(
            p_player_id, p_technique_id, p_species_id, external, eff_def);

        one_hit := hit.final_damage;
        IF strike > 1 THEN
            one_hit := GREATEST(0,
                floor(one_hit * game_config_value('gu_multi_hit_power')));
        END IF;
        IF random() < crit_pct THEN
            one_hit := floor(one_hit * crit_mult);
            n_crits := n_crits + 1;
        END IF;

        left_hp := GREATEST(0, left_hp - one_hit);
        out_dmg := out_dmg + one_hit;

        log := log || jsonb_build_object(
            'strike', strike, 'of', n_strikes,
            'damage', one_hit,
            'base_power', hit.base_power,
            'attainment_bonus', hit.attainment_bonus,
            'matchup_modifier', hit.matchup_modifier,
            'external', external,
            'armor_pen', pen,
            'target_hp_after', left_hp);
    END LOOP;

    -- What comes back. Capped by the room there is in the body, and by
    -- nothing when there is no body being tracked - the caller decides what
    -- to do with it then.
    IF steal > 0 AND out_dmg > 0 THEN
        got_back := floor(out_dmg * steal);
        IF p_player_hp IS NOT NULL AND p_player_max_hp IS NOT NULL THEN
            got_back := LEAST(got_back, GREATEST(0, p_player_max_hp - p_player_hp));
        END IF;
    END IF;

    RETURN QUERY SELECT out_dmg, n_strikes, n_crits, got_back, left_hp, log;
END;
$$;

COMMENT ON FUNCTION player_swing(BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, INTEGER) IS
    'Everything one blow from a cultivator does. The only place penetration, extra strikes, criticals, life steal, momentum and cornered strength are read - a duel, a dungeon round and a horde swing all come through here.';
