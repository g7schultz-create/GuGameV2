-- 0435_eleven_ores_still_signing_in_the_old_currency
--
-- 0434 said it had found "the last four places that still mint a percent".
-- It had found four of six. The test suite named the fifth:
--
--     test_a_forge_only_grants_effects_something_reads  ->  ['max_hp']
--
-- That test asks a better question than 0434 did. It does not look at the two
-- share tables I happened to think of; it looks at every route a forge has
-- into an effect - `slot_effects`, `part_effects`, `ores.signature` and
-- `forge_reactions` - and refuses any of them that names something the game
-- has stopped reading. Eleven ores carry `max_hp` as their signature, from
-- Cloudborn Soil at tier 1 up to the Eight-Sided Diamond Star Fragment at
-- tier 8, and every one of them would have gone on stamping a retired effect
-- onto newly forged armour.
--
-- `forge_reactions` is the sixth route and is already clean - it has no max_hp
-- row - which is the only reason this migration is eleven lines of data and
-- not another rewrite.
--
-- NOTHING MOVES, and this time that is a fact about the shape of the change
-- rather than a ledger keeping it true: an ore's signature decides what a
-- FUTURE forging stamps. It is not consulted when a piece that already exists
-- is worn, so no cultivator's numbers can shift. The probe asserts that too
-- rather than asserting it here, because "this cannot possibly move anybody"
-- is exactly the sentence that precedes somebody moving.
--
-- The magnitude takes care of itself. `forge` multiplies by
-- `gu_effects.unit_scale` since 0434, so an ore that used to stamp +40% now
-- stamps +48 flesh through the same 120x every other grant took. The signature
-- is the only thing that has to change.
--
-- Forward-only. Do not edit once applied.


UPDATE ores SET signature = 'base_hp' WHERE signature = 'max_hp';


-- ---------------------------------------------------------------------------
-- Every road into the forge now names something the game still reads
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_bad TEXT;
    v_n   INTEGER;
BEGIN
    -- The test's own question, asked here so the migration cannot land
    -- half-done: all four routes, not the two that were easy to remember.
    SELECT string_agg(DISTINCT ef.code, ', ') INTO v_bad
    FROM gu_effects ef
    WHERE ef.is_live = FALSE AND (
             ef.code IN (SELECT effect_code FROM slot_effects)
          OR ef.code IN (SELECT effect_code FROM part_effects)
          OR ef.code IN (SELECT signature    FROM ores)
          OR ef.code IN (SELECT effect_code FROM forge_reactions));
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION
            'the forge can still stamp these retired effects: %', v_bad;
    END IF;

    -- And the ores really landed somewhere the realm multiplies.
    SELECT count(*) INTO v_n FROM ores WHERE signature = 'base_hp';
    IF v_n < 11 THEN
        RAISE EXCEPTION 'expected at least 11 ores signing in flesh, found %', v_n;
    END IF;

    -- Nobody's body changed, because a signature is a fact about the next
    -- forging rather than about a piece somebody is already wearing.
    SELECT string_agg(p.discord_name, ', ') INTO v_bad
    FROM stat_conversion_snapshot s
    JOIN player_physique pp ON pp.player_id = s.player_id
    JOIN players p ON p.player_id = s.player_id
    WHERE s.migration = '0434' AND p.deleted_at IS NULL
      AND (abs(pp.max_hp - s.max_hp) > 1
           OR pp.strength <> s.strength
           OR pp.defense <> s.defense);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'an ore signature moved these cultivators: %', v_bad;
    END IF;

    RAISE NOTICE
        '% ores now sign in flesh; no live effect is mintable and unread', v_n;
END;
$probe$;
