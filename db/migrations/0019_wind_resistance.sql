-- 0019_wind_resistance
--
-- One row. Wind came out of 0018 with three advantages but only one
-- resistance, because that migration dropped the generated
-- `wind -> lightning: resistance` to stop the Storm Eagle - a Wind/Lightning
-- creature - resisting its own Path.
--
-- Dropping it was right; leaving Wind at 1 resistance was not. The rule from
-- 0002 is that every Path deals roughly 2-3 advantages AND 2-3 resistances, so
-- that no single type is strictly best. A Path that is resisted by only one
-- thing is quietly stronger than the chart intends.
--
-- Earth is the replacement, and a better fit than Lightning was: a gale has
-- never once moved a mountain. It also carries no co-typing hazard - the only
-- Wind creature in the design is the Storm Eagle, which is Wind/Lightning, so
-- nothing that is Wind is also Earth.
--
-- Note this is the reverse direction of `earth -> wind: advantage` from 0018,
-- and the two are independent facts: the chart is directed, and Earth beating
-- Wind says nothing about how Wind fares into Earth. Here they happen to
-- agree, which is what a genuinely one-sided matchup looks like.
--
-- Forward-only. Do not edit once applied.

INSERT INTO path_matchups (attacker_path, defender_path, interaction, flavour_text) VALUES
    ('wind', 'earth', 'resistance', 'A gale has never once moved a mountain.');
