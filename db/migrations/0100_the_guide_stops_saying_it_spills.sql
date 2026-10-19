-- 0100_the_guide_stops_saying_it_spills
--
-- 0099 gave the bottleneck a reserve. The tutorial still tells new players
-- "It does not spill over", which was true when it was written and is now the
-- one sentence in the guide that would cost somebody real progress: a player
-- who believes it has every reason to log in anxiously rather than trust the
-- game to hold what they earn.
--
-- The share is substituted rather than written, the way every other number on
-- these pages is, so moving the dial moves the guide.
--
-- Forward-only. Do not edit once applied.


UPDATE tutorial_pages
SET body = replace(
    body,
    '**Cultivation stops at the next realm''s door.** It does not spill over. '
    || '**/breakthrough** is what takes the realm',
    '**Cultivation stops at the next realm''s door** - but it is not wasted '
    || 'there. Everything you earn past the door is held in a **reserve**, up '
    || 'to one realm''s worth, and pours in the moment you cross. '
    || '**/breakthrough** is what takes the realm'
)
WHERE code = 'cultivation';

-- The page must actually have changed. A silent no-op here would leave the
-- guide contradicting the game with nothing to show for the migration.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM tutorial_pages
        WHERE code = 'cultivation' AND body LIKE '%reserve%'
    ) THEN
        RAISE EXCEPTION 'the cultivation page was not rewritten - the anchor moved';
    END IF;
END;
$$;

UPDATE tutorial_pages
SET body = body || E'\n\n**/breakthrough** the moment it opens. The reserve '
    || 'holds one realm''s worth of overflow and no more - past that, time at '
    || 'the door really is spent.'
WHERE code = 'waiting';
