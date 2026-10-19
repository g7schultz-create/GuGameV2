-- 0363_hard_is_a_race_not_a_loss
--
-- 0362 sized the immortal rooms off a measurement and the measurement was
-- taken against the wrong end of the spread. The five immortals on this server
-- swing for between 125 and 772 million; I anchored on the average of 315
-- million and then checked the result against the TOUGHEST body, which is not
-- the strongest hitter. Driven afterwards, the Dewberry room came out at:
--
--     kill it in 22 rounds  |  it kills you in 10
--
-- That is not a hard room. That is a room nobody finishes, because the fight
-- ends nine rounds before the boss does. Hard means the two numbers are close
-- enough that healing, Life on Hit and bringing people matter. A room you
-- cannot finish solo at your own realm on Normal is a wall, and the ladder
-- already has walls.
--
-- Retuned so the Dewberry room is a race: about twelve rounds to kill against
-- about fourteen to die, for a middling build fighting alone. A strong build
-- wins comfortably, a weak one needs a party or a better Gu set, and Hell and
-- Insane remain what they are - group work.
--
--   health  4.00 -> 2.20 billion   (about twelve rounds for a middling build)
--   attack  8.00 -> 3.20 million   (about fifteen rounds to die, from ten)
--
-- The per-realm curves are untouched: health still x2.1 a realm against a
-- cultivator's x2 so the climb is felt, attack still x2.0 so time-to-die stays
-- flat. Lowering the attack floor also buys back headroom against the INTEGER
-- wall in `compute_creature_damage` - the Yellow Apricot room now sits at 819
-- million against the 2.147 billion ceiling, 38 percent rather than 95.
--
-- The first draft of this migration set attack at 5.5 million and its own
-- probe rejected it: ten rounds to kill against nine to die, still a loss.
-- The number below is what survived being driven.
--
-- THE PROBE IS THE POINT OF THIS MIGRATION. 0362 asserted the room was
-- dangerous and never asserted it was winnable, so a room that kills you
-- faster than you can kill it passed clean. This one drives real swings
-- through `player_swing` and requires BOTH: not trivial, and not a loss.
--
-- Forward-only. Do not edit once applied.


UPDATE creature_species s
SET base_hp      = round(2200000000::numeric * power(2.1, s.immortal_rank - 10))::bigint,
    base_attack  = round(   3200000::numeric * power(2.0, s.immortal_rank - 10))::bigint,
    base_defense = round(   4000000::numeric * power(2.0, s.immortal_rank - 10))::bigint
WHERE s.kind = 'dungeon' AND s.immortal_rank IS NOT NULL;


-- ---------------------------------------------------------------------------
-- The Dewberry room is a race, and it is close
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    who     BIGINT;
    hp      BIGINT;
    def     BIGINT;
    tech    BIGINT;
    boss    BIGINT;
    bhp     BIGINT;
    bdef    BIGINT;
    sw      RECORD;
    tot     BIGINT := 0;
    swings  INTEGER := 60;
    per     BIGINT;
    to_kill NUMERIC;
    to_die  NUMERIC;
    dealt   BIGINT;
    bad     TEXT;
BEGIN
    -- Deliberately the MEDIAN body rather than the toughest: the toughest is
    -- the one 0362 measured, and measuring the outlier is how it got this
    -- wrong in the first place.
    SELECT pc.player_id, pp.max_hp, pp.defense INTO who, hp, def
    FROM player_cultivation pc
    JOIN realms r ON r.realm_id = pc.realm_id
    JOIN player_physique pp ON pp.player_id = pc.player_id
    WHERE r.rank >= 10
    ORDER BY pp.max_hp
    OFFSET (SELECT count(*) / 2 FROM player_cultivation pc2
            JOIN realms r2 ON r2.realm_id = pc2.realm_id WHERE r2.rank >= 10)
    LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'no immortal to race - the tuning is unmeasured';
        RETURN;
    END IF;

    SELECT u.technique_id INTO tech
    FROM player_usable_techniques u
    JOIN techniques t ON t.technique_id = u.technique_id
    WHERE u.player_id = who ORDER BY t.base_power DESC LIMIT 1;

    SELECT d.species_id, s.base_hp, s.base_defense INTO boss, bhp, bdef
    FROM dungeons d JOIN creature_species s ON s.species_id = d.species_id
    WHERE d.realm_rank = 10;

    IF tech IS NULL THEN
        RAISE NOTICE 'that immortal has no technique to swing';
        RETURN;
    END IF;

    -- Real swings through the whole build - criticals, extra strikes,
    -- penetration - because that is what the room will actually face, and
    -- reading `base_power` instead is how a room gets mis-sized.
    BEGIN
        FOR i IN 1..swings LOOP
            SELECT * INTO sw FROM player_swing(
                who, tech, boss, bhp, bdef, hp, hp, 1, 'dungeon', 0::bigint);
            tot := tot + GREATEST(0, sw.dealt);
        END LOOP;
        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    per     := GREATEST(1, tot / swings);
    to_kill := ceil(bhp::numeric / per);

    SELECT final_damage INTO dealt FROM compute_creature_damage(boss, who, 1, def);
    to_die  := floor(hp::numeric / GREATEST(dealt, 1));

    RAISE NOTICE
        'Dewberry room: kill in % rounds, die in % rounds (% a swing, % a blow)',
        to_kill, to_die, per, dealt;

    -- Not a wall. The whole reason this migration exists.
    IF to_kill + 3 > to_die THEN
        RAISE EXCEPTION
            'the Dewberry room still cannot be finished solo: % to kill, % to die',
            to_kill, to_die;
    END IF;

    -- And not a formality either, which is the other half of 'hard'.
    IF to_kill < 6 THEN
        RAISE EXCEPTION
            'the Dewberry room falls in % rounds - that is not hard', to_kill;
    END IF;

    -- The headroom claim, so the next realm band does not discover the wall
    -- the hard way.
    SELECT string_agg(s.code || ' (' || s.base_attack || ')', ', ') INTO bad
    FROM creature_species s WHERE s.base_attack > 2147483647;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these overflow compute_creature_damage: %', bad;
    END IF;

    RAISE NOTICE 'deepest room attack is % against a ceiling of 2147483647',
        (SELECT max(base_attack) FROM creature_species);
END;
$probe$;
