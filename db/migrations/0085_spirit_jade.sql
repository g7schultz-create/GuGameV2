-- 0085_spirit_jade
--
-- The first money this game has ever had.
--
-- THERE WAS NO CURRENCY TO REPLACE. The design document is inherited from v1
-- and opens by contrasting Spirit Jade with "Spirit Stones, the ordinary
-- progression currency". In THIS schema `spirit_stone` is a common Qi-Path
-- gathering material that grows in the Central Continent, one of seventy-seven
-- such rows, and `players` has no balance column at all. So the document's
-- instruction to keep the two distinct costs nothing: they were never
-- competing, and this is the first currency rather than the second.
--
-- IT IS A MATERIAL, NOT A WALLET. A new category on `materials`, and the whole
-- economy arrives already built: `trade_offer_materials` moves it between
-- players, `/trade` already has a pile for it, `grant_material` and
-- `spend_material` are the faucet and the sink, and `/inventory` shelves it.
-- A wallet column would have meant a second inventory, a second trade table
-- and a second pair of spend/grant functions, and would have bought only the
-- ability to make money untradable - which is the opposite of the point.
--
-- AND THE GUARDS WERE ALREADY WRITTEN. `region_materials` refuses anything not
-- 'gathering', `creature_drops` refuses anything not 'beast', `ores` and
-- `beast_parts` refuse the same way, and a Gu recipe's base must be gathering.
-- Every one of those was written in 0017 or later for an unrelated reason, and
-- together they mean currency cannot become a crafting input by accident. The
-- one hole is a Gu refinement AUXILIARY, which accepts any material at all;
-- that is closed here.
--
-- THE LEDGER IS THE POINT OF THE DOCUMENT. "Approximate Jade generation per
-- active player should be measurable and controllable" is the sentence the
-- whole economy hangs on, and a balance alone cannot answer it. Every grant
-- and every spend writes a row saying where it came from, so faucet rates are
-- a query rather than a guess.
--
-- FAUCETS, and why these three. Weekly quests, sect wars and inheritance
-- grounds are named in the document and none of them exists. What exists and
-- is already recorded:
--
--   breakthrough  - twenty-six crossings in a character's whole life, entirely
--                   predictable, and already a function that reports what it
--                   granted.
--   first kill    - `player_bestiary.times_defeated` rolling 0 to 1 is a
--                   first-time achievement this game has recorded since 0017.
--                   Sixty-two of them, once each.
--   a rogue purse - rogues are people and already carry manual pages. This is
--                   the only repeatable faucet and therefore the inflation
--                   risk, so it is the smallest.
--
-- World bosses are the document's best faucet and `world_boss_instances` has
-- no rows and no system behind it. It is left for when there is one.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- A third category
-- ---------------------------------------------------------------------------

ALTER TABLE materials DROP CONSTRAINT materials_category_check;
ALTER TABLE materials ADD CONSTRAINT materials_category_check
    CHECK (category IN ('gathering', 'beast', 'currency'));

COMMENT ON TABLE materials IS
    'Three economies in one table: gathering materials feed Gu refinement and alchemy, beast materials feed physiques and forging, and currency buys none of them directly.';

INSERT INTO materials (code, name, category, rarity, emoji, description) VALUES
    ('spirit_jade', 'Spirit Jade', 'currency', 'rare', '💚',
     'Cut from a vein nobody has ever found twice. It cultivates nothing and refines into nothing, which is exactly why everyone will take it.');

-- Deliberately no `path_code`. A material with a Path has an opinion about
-- what it belongs in, and money is supposed to belong in everything equally.


-- ---------------------------------------------------------------------------
-- The one hole in the existing guards
-- ---------------------------------------------------------------------------
-- Auxiliary materials on a Gu bench are the only place that takes ANY
-- material, so it is the only place currency could have been burned for
-- power. Everything else was already closed by a trigger written for the
-- gathering/beast split.

CREATE FUNCTION check_material_is_not_currency()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF (SELECT category FROM materials WHERE code = NEW.material_code) = 'currency' THEN
        RAISE EXCEPTION 'money is not an ingredient';
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION check_material_is_not_currency() IS
    'Guards the tables that accept any material at all. The gathering/beast triggers already cover the rest.';


-- ---------------------------------------------------------------------------
-- jade_ledger
-- ---------------------------------------------------------------------------
-- Where it came from and where it went, for every last coin.

CREATE TABLE jade_ledger (
    entry_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    player_id  BIGINT NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,

    -- Positive is a faucet, negative is a sink. A trade between players moves
    -- material without writing here: it changes who holds the money, not how
    -- much of it exists, and conflating the two would make the metrics lie.
    delta      BIGINT NOT NULL CHECK (delta <> 0),
    reason     TEXT   NOT NULL,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX jade_ledger_player_idx ON jade_ledger (player_id);
CREATE INDEX jade_ledger_reason_idx ON jade_ledger (reason, created_at);
CREATE INDEX jade_ledger_when_idx   ON jade_ledger (created_at);

COMMENT ON TABLE jade_ledger IS
    'Every coin created and destroyed, with the reason. Faucet rates are a query rather than a guess - which is the only way the document''s "measurable and controllable" is true.';

CREATE FUNCTION grant_jade(p_player_id BIGINT, p_amount BIGINT, p_reason TEXT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    held BIGINT;
BEGIN
    IF p_amount <= 0 THEN
        RETURN COALESCE((SELECT pm.quantity FROM player_materials pm
                         WHERE pm.player_id = p_player_id
                           AND pm.material_code = 'spirit_jade'), 0);
    END IF;

    held := grant_material(p_player_id, 'spirit_jade', p_amount);
    INSERT INTO jade_ledger (player_id, delta, reason)
    VALUES (p_player_id, p_amount, p_reason);
    RETURN held;
END;
$$;

CREATE FUNCTION spend_jade(p_player_id BIGINT, p_amount BIGINT, p_reason TEXT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    held BIGINT;
BEGIN
    IF p_amount <= 0 THEN
        RETURN 0;
    END IF;

    -- `spend_material` raises if there is not enough, which is the refusal
    -- this wants: a sink must never be able to run a balance negative.
    held := spend_material(p_player_id, 'spirit_jade', p_amount);
    INSERT INTO jade_ledger (player_id, delta, reason)
    VALUES (p_player_id, -p_amount, p_reason);
    RETURN held;
END;
$$;

CREATE FUNCTION jade_held(p_player_id BIGINT)
RETURNS BIGINT
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE((SELECT pm.quantity FROM player_materials pm
                     WHERE pm.player_id = p_player_id
                       AND pm.material_code = 'spirit_jade'), 0);
$$;


-- ---------------------------------------------------------------------------
-- The metrics the document asks for
-- ---------------------------------------------------------------------------

CREATE VIEW jade_economy AS
SELECT
    COALESCE(sum(l.delta) FILTER (WHERE l.delta > 0), 0)   AS generated,
    COALESCE(-sum(l.delta) FILTER (WHERE l.delta < 0), 0)  AS destroyed,
    (SELECT COALESCE(sum(pm.quantity), 0) FROM player_materials pm
     WHERE pm.material_code = 'spirit_jade')               AS held,
    (SELECT count(DISTINCT jl.player_id) FROM jade_ledger jl) AS earners
FROM jade_ledger l;

COMMENT ON VIEW jade_economy IS
    'Generated, destroyed and currently held. If generated minus destroyed drifts far from held, something is moving jade without saying so.';

CREATE VIEW jade_faucets AS
SELECT l.reason,
       sum(l.delta) FILTER (WHERE l.delta > 0)  AS generated,
       -sum(l.delta) FILTER (WHERE l.delta < 0) AS destroyed,
       count(*)                                 AS entries,
       count(DISTINCT l.player_id)              AS players
FROM jade_ledger l
GROUP BY l.reason;

COMMENT ON VIEW jade_faucets IS
    'Which faucet is actually producing the money, and which sink is actually taking it back.';


-- ---------------------------------------------------------------------------
-- The dials
-- ---------------------------------------------------------------------------

INSERT INTO game_config (key, value, description) VALUES
    ('jade_per_realm', 3,
     'PLACEHOLDER - Spirit Jade for crossing a realm. Twenty-six crossings in a whole character.'),
    ('jade_first_kill', 1,
     'PLACEHOLDER - Spirit Jade the first time a species is killed. Sixty-two of them, once each.'),
    ('jade_rogue_purse', 1,
     'PLACEHOLDER - Spirit Jade off a beaten rogue cultivator. The only repeatable faucet, and therefore the smallest.'),
    ('jade_rogue_chance', 0.35,
     'PLACEHOLDER - chance a beaten rogue was carrying any at all.');
