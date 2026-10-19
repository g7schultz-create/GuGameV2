-- 0149_the_house_and_its_edge
--
-- A table where a cultivator can stake Spirit Jade against the house.
--
-- THE HOUSE HAS INFINITE JADE, WHICH MAKES THE ODDS THE ONLY THING HOLDING
-- THE ECONOMY UP. Jade is the scarce currency in this game on purpose - a
-- settled day pays eight to twenty, a reroll is five, a Grotto-Heaven is six
-- hundred and forty. An opponent who can never run out is either a slow drain
-- or an unbounded faucet, and which one it is depends entirely on the payout
-- table below. There is no third possibility and no way to fix it later
-- without taking Jade off people.
--
-- So the house keeps four per cent, and this migration refuses to apply if the
-- table it is given says otherwise. The bands are DATA rather than a formula
-- precisely so somebody can retune them - and so the arithmetic gets checked
-- when they do.
--
--     roll     outcome      pays    weight   contributes
--     1-42     nothing      0x       42%      0.00
--     43-68    a push       1x       26%      0.26
--     69-96    doubled      2x       28%      0.56
--     97-99    tripled      3x        3%      0.09
--     100      the vault    5x        1%      0.05
--                                            -----
--                                             0.96
--
-- Twenty-six per cent of rolls hand the stake straight back, which matters
-- more than it looks: a game that took the stake three times in five would
-- feel like a mugging however good the tail is.
--
-- A ceiling on the stake is not about the house's purse - it has none - but
-- about variance. One cultivator turning forty Jade into two hundred in a
-- night distorts a currency this scarce more than the four per cent recovers.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('gamble_min_stake', 1,
     'Least Spirit Jade a wager may be for.'),
    ('gamble_max_stake', 25,
     'Most Spirit Jade one wager may be for. A ceiling on variance rather than on the house, which has no purse to protect.'),
    ('gamble_house_take', 0.04,
     'What the house keeps, as a fraction of everything staked against it. The payout table must add up to exactly this and the schema checks that it does.')
ON CONFLICT (key) DO UPDATE SET
    value = EXCLUDED.value, description = EXCLUDED.description;


-- ---------------------------------------------------------------------------
-- gamble_bands
-- ---------------------------------------------------------------------------
-- One row per outcome, keyed by the lowest roll that reaches it. A d100 lands
-- in exactly one band, found by taking the highest `min_roll` at or below it -
-- the same shape `attainment_tiers` and `equipment_qualities` use, so there is
-- one way to read a ladder in this schema rather than three.

CREATE TABLE gamble_bands (
    min_roll   SMALLINT PRIMARY KEY CHECK (min_roll BETWEEN 1 AND 100),

    name       TEXT NOT NULL,
    emoji      TEXT NOT NULL DEFAULT '🎲',
    -- What the stake comes back multiplied by. 0 loses it, 1 hands it back,
    -- 2 doubles it. NUMERIC so a half-back band is possible without a
    -- migration to widen the column.
    multiplier NUMERIC(6, 2) NOT NULL CHECK (multiplier >= 0),

    flavour    TEXT NOT NULL DEFAULT ''
);

INSERT INTO gamble_bands (min_roll, name, emoji, multiplier, flavour) VALUES
    (1,   'Nothing',    '💨', 0,  'The dice say what the dice say.'),
    (43,  'A push',     '🤝', 1,  'Your stake back, and no worse for it.'),
    (69,  'Doubled',    '✨', 2,  'The house counts it out without comment.'),
    (97,  'Tripled',    '🌟', 3,  'A few heads turn.'),
    (100, 'The vault',  '💎', 5,  'The house opens the vault. It does not enjoy this.');

COMMENT ON TABLE gamble_bands IS
    'What a d100 against the house pays. Data rather than a formula so it can be retuned - and so the house edge is checked when it is.';


-- ---------------------------------------------------------------------------
-- house_wagers
-- ---------------------------------------------------------------------------
-- Every roll against the house, kept. `jade_ledger` records the movement but
-- not the roll, and without the roll nobody can ever answer "is the table
-- paying what it says it pays" from live data rather than from arithmetic.

CREATE TABLE house_wagers (
    wager_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    player_id BIGINT NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,

    stake     BIGINT   NOT NULL CHECK (stake > 0),
    roll      SMALLINT NOT NULL CHECK (roll BETWEEN 1 AND 100),
    band      SMALLINT NOT NULL REFERENCES gamble_bands (min_roll)
              ON DELETE RESTRICT,
    paid      BIGINT   NOT NULL CHECK (paid >= 0),

    played_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX house_wagers_player_idx ON house_wagers (player_id, played_at DESC);
CREATE INDEX house_wagers_band_idx ON house_wagers (band);
CREATE INDEX house_wagers_when_idx ON house_wagers (played_at DESC);

COMMENT ON TABLE house_wagers IS
    'Every roll staked against the house. Kept so the realised edge can be measured against the intended one from live play rather than trusted.';


-- ---------------------------------------------------------------------------
-- play_house
-- ---------------------------------------------------------------------------

CREATE FUNCTION play_house(p_player_id BIGINT, p_stake BIGINT)
RETURNS TABLE (
    stake      BIGINT,
    roll       SMALLINT,
    band_name  TEXT,
    emoji      TEXT,
    flavour    TEXT,
    multiplier NUMERIC,
    paid       BIGINT,
    net        BIGINT,
    jade_left  BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    lo    BIGINT := game_config_value('gamble_min_stake')::bigint;
    hi    BIGINT := game_config_value('gamble_max_stake')::bigint;
    fell  SMALLINT;
    band  RECORD;
    back  BIGINT;
    held  BIGINT;
BEGIN
    IF p_stake < lo OR p_stake > hi THEN
        RAISE EXCEPTION 'a wager is between % and % Spirit Jade', lo, hi
            USING ERRCODE = 'check_violation';
    END IF;

    -- Taken first, and it refuses rather than going negative. Everything below
    -- is the house paying back out of nothing, which is what a house is.
    PERFORM spend_jade(p_player_id, p_stake, 'gamble_stake');

    fell := 1 + floor(random() * 100);

    SELECT gb.min_roll, gb.name, gb.emoji, gb.multiplier, gb.flavour
    INTO band
    FROM gamble_bands gb
    WHERE gb.min_roll <= fell
    ORDER BY gb.min_roll DESC
    LIMIT 1;

    back := floor(p_stake * band.multiplier);

    IF back > 0 THEN
        PERFORM grant_jade(p_player_id, back, 'gamble_payout');
    END IF;

    INSERT INTO house_wagers (player_id, stake, roll, band, paid)
    VALUES (p_player_id, p_stake, fell, band.min_roll, back);

    held := jade_held(p_player_id);

    RETURN QUERY SELECT p_stake, fell, band.name, band.emoji, band.flavour,
                        band.multiplier, back, back - p_stake, held;
END;
$$;

COMMENT ON FUNCTION play_house(BIGINT, BIGINT) IS
    'One d100 against the house. Takes the stake before rolling, so a refusal for want of Jade happens before anything is decided.';


-- ---------------------------------------------------------------------------
-- The edge has to be what it says it is
-- ---------------------------------------------------------------------------
-- The whole safety of an opponent with infinite Jade rests on this sum. A band
-- retuned by a point in the wrong direction turns the house from a slow drain
-- into a faucet nobody notices until the currency is worthless.

DO $$
DECLARE
    ev     NUMERIC;
    want   NUMERIC := 1 - game_config_value('gamble_house_take');
    covers INTEGER;
    ghost  BIGINT;
    got    RECORD;
BEGIN
    -- Every roll from 1 to 100 must land in exactly one band.
    SELECT count(*) INTO covers
    FROM generate_series(1, 100) AS r (roll)
    WHERE NOT EXISTS (
        SELECT 1 FROM gamble_bands gb WHERE gb.min_roll <= r.roll
    );
    IF covers > 0 THEN
        RAISE EXCEPTION '% roll(s) fall through every band', covers;
    END IF;

    -- The expected return per Jade staked, over a flat d100.
    SELECT sum(band.multiplier) / 100 INTO ev
    FROM generate_series(1, 100) AS r (roll)
    CROSS JOIN LATERAL (
        SELECT gb.multiplier FROM gamble_bands gb
        WHERE gb.min_roll <= r.roll
        ORDER BY gb.min_roll DESC LIMIT 1
    ) band;

    IF abs(ev - want) > 0.0001 THEN
        RAISE EXCEPTION
            'the table returns % per Jade staked and the house means to keep %; it should return %',
            ev, game_config_value('gamble_house_take'), want;
    END IF;

    IF ev >= 1 THEN
        RAISE EXCEPTION
            'the house loses % per Jade staked and has infinite Jade to lose it with',
            ev - 1;
    END IF;

    -- A game that took the stake outright most of the time would be correct
    -- and unplayable.
    SELECT count(*) INTO covers
    FROM generate_series(1, 100) AS r (roll)
    CROSS JOIN LATERAL (
        SELECT gb.multiplier FROM gamble_bands gb
        WHERE gb.min_roll <= r.roll
        ORDER BY gb.min_roll DESC LIMIT 1
    ) band
    WHERE band.multiplier = 0;
    IF covers > 50 THEN
        RAISE EXCEPTION 'the stake is lost outright on % rolls in a hundred', covers;
    END IF;

    RAISE NOTICE 'the house returns % per Jade staked, keeping %', ev, 1 - ev;

    -- And it has to survive being called.
    INSERT INTO players (discord_id, discord_name)
    VALUES (-999149, 'migration 0149 probe') RETURNING player_id INTO ghost;
    PERFORM grant_jade(ghost, 500, 'probe');

    FOR i IN 1..50 LOOP
        SELECT * INTO got FROM play_house(ghost, 1);
        IF got.roll < 1 OR got.roll > 100 THEN
            RAISE EXCEPTION 'a d100 came out at %', got.roll;
        END IF;
    END LOOP;

    BEGIN
        PERFORM play_house(ghost, 999999);
        RAISE EXCEPTION 'a wager past the ceiling was accepted';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;

    DELETE FROM house_wagers WHERE player_id = ghost;
    DELETE FROM jade_ledger WHERE player_id = ghost;
    DELETE FROM player_materials WHERE player_id = ghost;
    DELETE FROM players WHERE player_id = ghost;
END;
$$;
