-- 0073_the_bodies_that_were_still_owed
--
-- Ten more promises kept, and five admitted to properly.
--
-- 0070 left seventeen bodies owing a clause and called eleven of them blocked
-- on systems that do not exist. That was too pessimistic by ten: what most of
-- them were actually blocked on was a WORD, and 0071 wrote the words. The
-- magnitudes come off the same `physique_power` ladder as everything else, so
-- nothing here is a hand-set number.
--
-- BLAZING GLORY WAS ALREADY PAID and nobody noticed. Its clause reads "Fire +
-- Lightning dual-Path damage +25%", and it has carried `physique_path_bonuses`
-- rows for BOTH Fire and Lightning since 0012 - while
-- `player_external_multiplier` sums that bonus across every Path a technique
-- is typed with, weighted. A technique typed both therefore already collects
-- both, which is exactly the clause. It is cleared here with no new row at
-- all; the promise was kept by a function written four years of migrations
-- before the promise was made.
--
-- WHAT IS LEFT, and why each one, because "not yet" is only honest when it
-- says what it is waiting for:
--
--   Heaven Defying   - breakthrough backlash. There is no tribulation to be
--                      spared; `breakthrough()` still has the roll marked as a
--                      comment rather than code.
--   Puppet Array     - a bound creature and a formation held at once. Neither
--                      enslavement nor formations exist as systems.
--   Ink Skin         - a wound redrawn rather than healed. There is no wound
--                      to redraw: damage is a number, not a thing with a state.
--   Heaven and Earth - armour penetration against this body capped. Creatures
--                      have no penetration, so there is nothing to cap.
--   Carefree Wisdom  - comprehending a technique by watching it used. Nothing
--                      in this game learns by observation.
--   Phoenix Rebirth  - Qi returned on a kill. A kill ends the encounter and
--                      battle Qi does not outlive it.
--   Celestial Emperor- the lowest foundation stat raised. HP, defence and
--                      strength are on different scales, so "lowest" always
--                      means defence and the sentence stops meaning what it
--                      says. It needs a decision, not a consumer.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- What the last ten spend their steps on
-- ---------------------------------------------------------------------------
-- These are IN ADDITION to what 0070 gave the same bodies. A body carrying two
-- effects is not splitting one budget across them - it is a body that does two
-- things, and the ladder is per effect.

INSERT INTO physique_effects (physique_id, effect_code, magnitude)
SELECT p.physique_id, v.effect, round(e.step * pw.ranks * v.weight, 4)
FROM (VALUES
    ('orchard_body',            'pill_potency',    1.00),
    ('heavenly_battle_body',    'beast_damage',    1.00),
    ('mountain_king_body',      'braced',          1.00),
    ('endless_ocean_body',      'guard_qi',        1.00),
    ('phoenix_rebirth_body',    'wounded_power',   1.00),
    ('celestial_sovereign_body','foresight',       1.00),
    ('chaos_immortal_body',     'matchup_relief',  1.00),
    ('eternal_dragon_body',     'momentum',        1.00),
    ('infinite_immortal_body',  'death_ward',      1.00),
    ('primordial_origin_body',  'realm_tempering', 1.00)
) AS v (code, effect, weight)
JOIN physiques p       ON p.code = v.code
JOIN physique_power pw ON pw.tier = p.tier
JOIN gu_effects e      ON e.code = v.effect;


-- ---------------------------------------------------------------------------
-- Saying so
-- ---------------------------------------------------------------------------
-- Where the modelled version differs from what was written, the writing moves.
-- 0053 set that rule when it modelled Supreme Dao, and it is the reason none
-- of these bodies now claims something narrower or wider than it does.

UPDATE physiques SET special_text = v.txt
FROM (VALUES
    ('orchard_body',
     'Grown rather than tempered. There is more of it than there was, and it takes more out of everything it swallows.'),
    ('endless_ocean_body',
     'Qi comes back the way a tide does - not quickly, and not once. Every brace draws it further in.'),
    ('heavenly_battle_body',
     'A body that finds the rhythm of a fight and then keeps it. Beasts are what it learned the rhythm on.'),
    ('mountain_king_body',
     'While it is still mostly whole, very little gets through. Once it is not, it is a mountain like any other.'),
    ('phoenix_rebirth_body',
     'The worse it is going, the harder this body hits. Half dead is where it starts being dangerous.'),
    ('celestial_sovereign_body',
     'The shape of a thing is legible before it moves. You have never had to watch one to know where it is soft.'),
    ('chaos_immortal_body',
     'Too unfinished a thing to be countered cleanly. What resists you resists less; what is immune to you is still immune.'),
    ('eternal_dragon_body',
     'Every exchange feeds it, and what it feeds keeps growing while the fight lasts. Long fights are its fights.'),
    ('infinite_immortal_body',
     'A killing blow lands where the body has already stopped being. Once per fight, and the fight goes on.'),
    ('primordial_origin_body',
     'Every pillar advances, and none of them leads. Crossing a realm tempers the body as surely as the years do.')
) AS v (code, txt)
WHERE physiques.code = v.code;


-- ---------------------------------------------------------------------------
-- What is still owed, after this
-- ---------------------------------------------------------------------------

UPDATE physiques SET unmodelled = '{}'::jsonb
WHERE code IN (
    'orchard_body', 'endless_ocean_body', 'heavenly_battle_body',
    'mountain_king_body', 'celestial_sovereign_body', 'chaos_immortal_body',
    'primordial_origin_body',
    -- Paid since 0012 by a function nobody had checked against the promise.
    'blazing_glory_lightning_brilliance'
);

UPDATE physiques SET unmodelled = v.left_owing::jsonb
FROM (VALUES
    ('phoenix_rebirth_body',
     '{"On a kill": "5% battle Qi returned - but a kill ends the encounter and battle Qi does not outlive it"}'),
    ('eternal_dragon_body',
     '{"At full stacks": "Transformation techniques gain an effect"}'),
    ('infinite_immortal_body',
     '{"Space techniques": "a chance to cost no Qi"}')
) AS v (code, left_owing)
WHERE physiques.code = v.code;
