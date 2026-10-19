-- 0143_a_technique_you_both_own_and_borrow
--
-- `player_usable_techniques` is a UNION of what you have learned and what your
-- equipped manuals lend. UNION removes duplicate ROWS, and the two halves put
-- different values in `source` and `manual_id` - so a technique you have both
-- learned AND have a manual for comes back TWICE, with the same technique_id.
--
-- The battle screen builds its move select from that list. Two options with
-- the same value is not something Discord accepts:
--
--     400 Bad Request (50035): In components.0.components.0.options.1:
--     The specified option value is already used
--
-- The message is refused whole, so the fight cannot be drawn at all. pashu0
-- has been stuck against a live creature since this morning, told to resume
-- with /battle by a command that then could not render.
--
-- Worth being clear about whose fault the flow is: 0130 tells a player, on
-- learning a technique their manual was lending them, "A manual was lending
-- you this one. You can unequip that manual now without losing it." That is
-- the exact sequence that produces the duplicate. The feature encouraged it.
--
-- One row per cultivator per technique, preferring the learned one, because
-- that is the one that survives unequipping the book. Every consumer is fixed
-- by this rather than the two list queries that happened to notice.
--
-- (The subquery is aliased `held` rather than the obvious `both`: BOTH is a
-- reserved word in Postgres - it is the keyword in trim(both '.' from x).)
--
-- Forward-only. Do not edit once applied.


CREATE OR REPLACE VIEW player_usable_techniques AS
SELECT DISTINCT ON (held.player_id, held.technique_id)
       held.player_id, held.technique_id, held.source, held.manual_id
FROM (
    SELECT pt.player_id, pt.technique_id, 'learned'::text AS source,
           NULL::bigint AS manual_id
    FROM player_techniques pt
    JOIN techniques t ON t.technique_id = pt.technique_id
    LEFT JOIN player_cultivation pc ON pc.player_id = pt.player_id
    LEFT JOIN realms r ON r.realm_id = pc.realm_id
    WHERE t.rank <= COALESCE(r.rank, 1)

    UNION ALL

    SELECT s.player_id, mt.technique_id, 'manual'::text, m.manual_id
    FROM player_manual_slots s
    JOIN manuals m ON m.manual_id = s.manual_id
    JOIN manual_techniques mt ON mt.manual_id = m.manual_id
    JOIN techniques t ON t.technique_id = mt.technique_id
    LEFT JOIN player_cultivation pc ON pc.player_id = s.player_id
    LEFT JOIN realms r ON r.realm_id = pc.realm_id
    WHERE t.rank <= COALESCE(r.rank, 1)
) held
-- 'learned' sorts before 'manual', which is the order we want and not a
-- coincidence worth relying on, so it is spelled out.
ORDER BY held.player_id, held.technique_id,
         (held.source = 'learned') DESC, held.manual_id;

COMMENT ON VIEW player_usable_techniques IS
    'Learned techniques plus those an equipped manual lends, gated by realm rank, ONE ROW EACH. A technique both learned and lent reports as learned, because that is the one that survives unequipping the book.';


DO $$
DECLARE
    doubled INTEGER;
    lost    INTEGER;
BEGIN
    SELECT count(*) INTO doubled FROM (
        SELECT u.player_id, u.technique_id
        FROM player_usable_techniques u
        GROUP BY u.player_id, u.technique_id
        HAVING count(*) > 1
    ) _;

    IF doubled > 0 THEN
        RAISE EXCEPTION '% technique(s) are still listed twice', doubled;
    END IF;

    -- And nobody may lose access on the way through. The view got narrower;
    -- it must not have got shorter in the ways that matter.
    SELECT count(*) INTO lost
    FROM players p
    WHERE EXISTS (
        SELECT 1 FROM player_techniques pt WHERE pt.player_id = p.player_id
    )
    AND NOT EXISTS (
        SELECT 1 FROM player_usable_techniques u WHERE u.player_id = p.player_id
    );

    IF lost > 0 THEN
        RAISE EXCEPTION '% player(s) hold a technique they can no longer use', lost;
    END IF;
END;
$$;
