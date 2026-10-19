-- 0144_a_trait_can_say_what_it_gives
--
-- `/reroll` shows a root's name, its rarity band and a line of flavour, and
-- then asks the player to spend Jade deciding between it and another one. It
-- has never said what either of them DOES. "Void Spirit Root (Epic) - occupies
-- rather less space than it appears to" is a decision made on vibes.
--
-- The character sheet can already answer this, but only for the trait a player
-- HOLDS - `fetch_traits` in bot/character.py keys off player_id. An offer is a
-- candidate nobody holds yet, so there was nothing to ask.
--
-- Two functions, keyed by the thing itself rather than by who has it, so the
-- current trait and the offered one are described by the same code and cannot
-- disagree about what a root is worth.
--
-- Path bonuses come back alongside the effects, because for a root they are
-- most of the point: Ember Root's three per cent to Fire damage is the reason
-- to want it, and it lives in a different table from its effects. A body also
-- reports how far it can be TEMPERED, from `physique_power` - which is what
-- its rarity band actually buys, and the only thing three of the common
-- bodies have to say at all.
--
-- Magnitudes are capped here exactly as `root_stat` and `physique_stat` cap
-- them at the point of use. A screen quoting the stored figure would be
-- quoting a number the game never applies - the same reason 0070's sheet caps
-- them.
--
-- Forward-only. Do not edit once applied.


CREATE FUNCTION root_grants(p_code TEXT)
RETURNS TABLE (
    kind      TEXT,
    name      TEXT,
    emoji     TEXT,
    magnitude NUMERIC
)
LANGUAGE sql STABLE
AS $$
    SELECT 'effect', ef.name, ef.emoji, LEAST(ef.cap, re.magnitude)
    FROM root_effects re
    JOIN gu_effects ef ON ef.code = re.effect_code
    WHERE re.root_code = p_code

    UNION ALL

    SELECT 'path', p.name || ' damage', p.emoji, rp.damage_bonus
    FROM root_path_bonuses rp
    JOIN paths p ON p.code = rp.path_code
    WHERE rp.root_code = p_code AND rp.damage_bonus > 0

    UNION ALL

    SELECT 'path', p.name || ' attainment', p.emoji, rp.attainment_bonus
    FROM root_path_bonuses rp
    JOIN paths p ON p.code = rp.path_code
    WHERE rp.root_code = p_code AND rp.attainment_bonus > 0

    ORDER BY 4 DESC, 2;
$$;

COMMENT ON FUNCTION root_grants(TEXT) IS
    'What a root is worth, keyed by the root rather than by who holds it - so an offer on the reroll screen can be described by the same code as the one in your chest.';


CREATE FUNCTION physique_grants(p_physique_id SMALLINT)
RETURNS TABLE (
    kind      TEXT,
    name      TEXT,
    emoji     TEXT,
    magnitude NUMERIC
)
LANGUAGE sql STABLE
AS $$
    SELECT 'effect', ef.name, ef.emoji, LEAST(ef.cap, pe.magnitude)
    FROM physique_effects pe
    JOIN gu_effects ef ON ef.code = pe.effect_code
    WHERE pe.physique_id = p_physique_id

    UNION ALL

    SELECT 'path', p.name || ' damage', p.emoji, pb.damage_bonus
    FROM physique_path_bonuses pb
    JOIN paths p ON p.code = pb.path_code
    WHERE pb.physique_id = p_physique_id AND pb.damage_bonus > 0

    UNION ALL

    SELECT 'path', p.name || ' attainment', p.emoji, pb.attainment_bonus
    FROM physique_path_bonuses pb
    JOIN paths p ON p.code = pb.path_code
    WHERE pb.physique_id = p_physique_id AND pb.attainment_bonus > 0

    UNION ALL

    SELECT 'path', p.name || ' resisted', p.emoji, pb.resistance
    FROM physique_path_bonuses pb
    JOIN paths p ON p.code = pb.path_code
    WHERE pb.physique_id = p_physique_id AND pb.resistance > 0

    UNION ALL

    -- How far the body can be tempered, which is what its rarity actually
    -- buys and the single most decision-relevant thing about it. Three of the
    -- common bodies have no effects and no Path bonuses at all, so without
    -- this row the screen would have nothing whatever to say about them.
    SELECT 'ceiling', 'Tempers to body rank ' || pw.ranks,
           '⬆', pw.ranks::numeric
    FROM physiques ph
    JOIN physique_power pw ON pw.tier = ph.tier
    WHERE ph.physique_id = p_physique_id

    ORDER BY 1, 4 DESC, 2;
$$;

COMMENT ON FUNCTION physique_grants(SMALLINT) IS
    'What a body is worth, keyed by the body rather than by who wears it. Includes the Paths it resists, which is half of what a physique is for.';


-- Every root and body a player can roll into has to have something to say, or
-- the screen this was written for will show a blank where the reason to want
-- it should be.
DO $$
DECLARE
    mute TEXT;
BEGIN
    SELECT r.name INTO mute
    FROM roots r
    WHERE NOT EXISTS (SELECT 1 FROM root_grants(r.code))
    ORDER BY r.name LIMIT 1;

    IF mute IS NOT NULL THEN
        RAISE EXCEPTION 'the root "%" grants nothing anybody can read', mute;
    END IF;

    SELECT ph.name INTO mute
    FROM physiques ph
    WHERE NOT EXISTS (SELECT 1 FROM physique_grants(ph.physique_id))
    ORDER BY ph.name LIMIT 1;

    IF mute IS NOT NULL THEN
        RAISE EXCEPTION 'the body "%" grants nothing anybody can read', mute;
    END IF;
END;
$$;
