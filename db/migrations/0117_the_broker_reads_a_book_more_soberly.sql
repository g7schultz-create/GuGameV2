-- 0117_the_broker_reads_a_book_more_soberly
--
-- 0116 set `broker_manual_rate` at 20, which prices a Tier 1 manual at 120
-- spirit stones. An explore cache pays two to nine, so that is roughly
-- twenty-four explores for one book - and a Tier 1 book is two pages and a
-- press of Refine. It would have made refining junk manuals the best income
-- in the game, which is the opposite of the problem the Binder was built for.
--
-- Five puts a Tier 1 at thirty stones - about six explores, and about thirty
-- common materials. A manual is worth more than a handful of grass and less
-- than an afternoon, which is where a floor price belongs.
--
-- The Binder and the Broker now sit at comparable value, which is the point:
-- unbinding a book for pages and selling it for stones should be a choice
-- about what you need, not a calculation about which pays better.
--
-- Forward-only. Do not edit once applied.


UPDATE game_config
SET value = 5.0,
    description = 'Spirit stones per point of a manual tier''s bonus budget, times one hundred. A Tier 1 book is thirty stones - about six explore caches.'
WHERE key = 'broker_manual_rate';
