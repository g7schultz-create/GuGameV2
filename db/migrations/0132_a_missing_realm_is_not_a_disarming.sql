-- 0132_a_missing_realm_is_not_a_disarming
--
-- 0130 put a realm gate on `player_usable_techniques` and wrote it as an INNER
-- JOIN onto `player_cultivation`. That is correct for everyone who has a row
-- there and catastrophic for anyone who does not: no row, no join, no
-- techniques at all - and `hunt` answers "You know no technique that could
-- hurt anything", which is a sentence about the player rather than about the
-- database losing them.
--
-- Two kinds of account are in exactly that state. The Auction House is one,
-- and it never fights. The other is a character between /register and its
-- confirmation, which is a real person, mid-onboarding, being told they own
-- nothing. The command test that plays the game in order is what caught it.
--
-- A missing realm now reads as rank 1 rather than as rank 0. Rank 1 is what a
-- character has the moment they exist, so the starter manual keeps working and
-- the gate still refuses everything above it.
--
-- The lesson, written down because this schema keeps re-teaching it: an INNER
-- JOIN inside a view that decides what a player MAY DO turns a missing row
-- into a silent revocation. `player_stat`, `dwelling_next` and
-- `player_manual_bonuses` all COALESCE a missing row for the same reason.
--
-- Forward-only. Do not edit once applied.


CREATE OR REPLACE VIEW player_usable_techniques AS
SELECT pt.player_id, pt.technique_id, 'learned'::text AS source,
       NULL::bigint AS manual_id
FROM player_techniques pt
JOIN techniques t ON t.technique_id = pt.technique_id
LEFT JOIN player_cultivation pc ON pc.player_id = pt.player_id
LEFT JOIN realms r ON r.realm_id = pc.realm_id
WHERE t.rank <= COALESCE(r.rank, 1)

UNION

SELECT s.player_id, mt.technique_id, 'manual'::text, m.manual_id
FROM player_manual_slots s
JOIN manuals m ON m.manual_id = s.manual_id
JOIN manual_techniques mt ON mt.manual_id = m.manual_id
JOIN techniques t ON t.technique_id = mt.technique_id
LEFT JOIN player_cultivation pc ON pc.player_id = s.player_id
LEFT JOIN realms r ON r.realm_id = pc.realm_id
WHERE t.rank <= COALESCE(r.rank, 1);

COMMENT ON VIEW player_usable_techniques IS
    'Learned techniques plus those an equipped manual lends, both gated by realm rank - and a cultivator with no realm row reads as rank 1 rather than as disarmed.';


-- Nobody may be left with less than they had. This counts every player who
-- can use nothing at all despite owning or borrowing something, which is the
-- shape the bug took.
DO $$
DECLARE
    stranded INTEGER;
BEGIN
    SELECT count(*) INTO stranded
    FROM players p
    WHERE (
        EXISTS (SELECT 1 FROM player_techniques pt WHERE pt.player_id = p.player_id)
     OR EXISTS (SELECT 1 FROM player_manual_slots s
                JOIN manual_techniques mt ON mt.manual_id = s.manual_id
                WHERE s.player_id = p.player_id)
    )
    AND NOT EXISTS (
        SELECT 1 FROM player_usable_techniques u WHERE u.player_id = p.player_id
    );

    IF stranded > 0 THEN
        RAISE EXCEPTION
            '% player(s) hold a technique the view will not let them use', stranded;
    END IF;
END;
$$;
