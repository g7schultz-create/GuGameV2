-- 0402_fortune_finds_you_better_things_not_more_things
--
-- Fortune does nothing for immortal essence. Measured on clearwest, whose
-- whole build is fortune - forty thousand real explores, rolled back:
--
--     essence on 4,713 of 40,000 explores      11.78 per cent
--     `explore_essence_chance`                 0.12
--
-- Their 0.75 explore luck moved it by nothing measurable, because the essence
-- roll is a bare `random() < 0.12` and the tier ladder above it is a bare
-- `random() < 0.10` per rung. Fortune appears exactly once in `explore`,
-- weighting `nothing` down in the outcome draw - which it does well: only
-- 1,866 of those 40,000 came up empty. It simply never touches the rarest
-- currency in the game.
--
-- So a player who built the stat called Fortune has the same odds on a Yellow
-- Apricot as a player who did not, and that is the wrong answer to the
-- question the stat's name asks.
--
-- IT BUYS DEPTH, NOT FREQUENCY. The base twelve per cent is left exactly
-- alone; the STEP UP the ladder is what fortune improves. Fortune should find
-- you better things rather than more things - that is what the word means,
-- it is the more interesting lever of the two, and it leaves the shape of
-- 0371's compounding ladder intact rather than flattening it.
--
--     step = explore_essence_step_chance x (1 + luck x explore_essence_luck_weight)
--
-- At weight 1.0 and clearwest's 0.75 luck the rung chance goes 0.10 -> 0.175.
-- Compounded four rungs that is eight times the odds on the top of the ladder,
-- which is a real reward for a real build and still leaves Yellow Apricot a
-- rumour. For pashu0 at realm 14 with 0.78 luck:
--
--     White Litchi     1 in 9,259   ->  1 in about 1,100
--     Yellow Apricot   1 in 83,333  ->  1 in about 10,000
--
-- CAPPED, because `explore_fortune` is itself two terms and the second one is
-- a Gu effect that can climb. A rung chance past `explore_essence_step_ceiling`
-- would start turning the ladder upside down, handing out more of the top
-- tiers than the bottom ones.
--
-- Nothing for a mortal, nothing for a cultivator standing outside a heaven,
-- and nothing at all to the twelve per cent. The only thing that changes is
-- how far up the ladder a lucky walker climbs once the essence has already
-- been found.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('explore_essence_luck_weight', 1.0,
     'How much a walker''s explore fortune lifts the chance of stepping ONE MORE RUNG up the essence ladder. At 1.0 a maxed fortune build roughly doubles the rung chance, which compounds to about eight times the odds on the deepest essence. Deliberately on the step rather than on the base chance: fortune should find you better things, not more things.'),
    ('explore_essence_step_ceiling', 0.35,
     'The most a rung of the essence ladder may ever be. explore_fortune is two terms and the second is a Gu effect that can climb; past this the ladder would start handing out more of the top tiers than the bottom ones.');


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'explore';

    IF body IS NULL THEN
        RAISE EXCEPTION 'explore is missing';
    END IF;

    anchor := concat(
'            WHILE tier < top', chr(10),
'                  AND random() < game_config_value(''explore_essence_step_chance'')', chr(10),
'            LOOP');

    swap := concat(
'            -- `luck` is the same explore fortune the outcome draw above uses,', chr(10),
'            -- and until 0402 it was the only place it appeared - so a fortune', chr(10),
'            -- build had exactly the odds on a Yellow Apricot that anybody', chr(10),
'            -- else did. It lifts the RUNG rather than the twelve per cent:', chr(10),
'            -- fortune finds you better things, not more things.', chr(10),
'            WHILE tier < top', chr(10),
'                  AND random() < LEAST(', chr(10),
'                      game_config_value(''explore_essence_step_ceiling''),', chr(10),
'                      game_config_value(''explore_essence_step_chance'')', chr(10),
'                      * (1 + luck', chr(10),
'                             * game_config_value(''explore_essence_luck_weight'')))', chr(10),
'            LOOP');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'explore no longer climbs its essence ladder where it did';
    END IF;

    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- A fortune build finds deeper essence, and the base chance did not move
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who    BIGINT;
    v_luck   NUMERIC;
    v_step   NUMERIC;
    v_base   NUMERIC := game_config_value('explore_essence_step_chance');
    v_ceil   NUMERIC := game_config_value('explore_essence_step_ceiling');
    r        RECORD;
BEGIN
    -- The ladder must still climb, never invert. A rung chance over a half
    -- would hand out more of the top tiers than the bottom.
    IF v_ceil >= 0.5 THEN
        RAISE EXCEPTION
            'a ceiling of % would turn the essence ladder upside down', v_ceil;
    END IF;

    -- Nobody's rung got worse, and nobody without fortune got better.
    FOR r IN
        SELECT p.discord_name, p.player_id, rr.rank,
               explore_fortune(p.player_id) AS luck
        FROM players p
        JOIN player_cultivation pc ON pc.player_id = p.player_id
        JOIN realms rr ON rr.realm_id = pc.realm_id
        WHERE p.deleted_at IS NULL AND rr.rank >= 10
        ORDER BY rr.rank DESC
    LOOP
        v_step := LEAST(v_ceil, v_base * (1 + r.luck
                  * game_config_value('explore_essence_luck_weight')));

        IF v_step < v_base THEN
            RAISE EXCEPTION
                '%''s rung got worse: % against a base of %',
                r.discord_name, v_step, v_base;
        END IF;

        RAISE NOTICE
            '% (realm %, luck %) : rung % -> %, top of the ladder 1 in % -> 1 in %',
            rpad(r.discord_name, 14), r.rank, round(r.luck, 2),
            v_base, round(v_step, 3),
            round(1 / (game_config_value('explore_essence_chance')
                       * power(v_base, 18 - r.rank))),
            round(1 / (game_config_value('explore_essence_chance')
                       * power(v_step, 18 - r.rank)));
    END LOOP;

    -- And the twelve per cent is untouched, which is the half that keeps this
    -- a change to WHAT you find rather than HOW OFTEN.
    IF game_config_value('explore_essence_chance') <> 0.12 THEN
        RAISE EXCEPTION 'the base essence chance moved after all';
    END IF;

    SELECT p.player_id, explore_fortune(p.player_id) INTO v_who, v_luck
    FROM players p WHERE p.deleted_at IS NULL
    ORDER BY explore_fortune(p.player_id) DESC LIMIT 1;

    IF v_luck IS NOT NULL AND v_luck > 0 THEN
        IF LEAST(v_ceil, v_base * (1 + v_luck
                 * game_config_value('explore_essence_luck_weight'))) <= v_base THEN
            RAISE EXCEPTION 'the luckiest walker in the game gained nothing';
        END IF;
    END IF;
END;
$probe$;
