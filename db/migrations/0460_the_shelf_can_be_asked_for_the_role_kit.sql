-- 0460_the_shelf_can_be_asked_for_the_role_kit
--
-- 0459 put a pull, a mend and a hardening within reach of every realm. They
-- are nine rows in a catalogue of two hundred and forty, sorted by rank, and
-- the four ways to narrow that catalogue are All, Can learn now, Not yours
-- yet, and Advanced. None of those finds them.
--
-- So the party screen says "no one here can pull a blow", and the player who
-- wants to fix that has no way to ask the shelf which techniques pull. A kit
-- nobody can find is the same problem as a kit nobody can buy, one step later.
--
-- ONE DEFINITION. Three places now have an opinion about which effects answer
-- which threat - `trial_resolve_round` deciding whether a round was covered,
-- `trial_party_roster` reporting what the party can do, and from here the
-- shelf. That is exactly the arrangement that drifts, so the mapping becomes a
-- function and the probe below checks the roster still agrees with it.
--
-- `trial_party_roster` is left reading its own copy rather than rewritten.
-- Patching a working function that four screens depend on, to save one
-- duplicated CASE, is a trade worth refusing; what is not worth refusing is
-- being told when the two stop matching.
--
-- Forward-only. Do not edit once applied.


CREATE OR REPLACE FUNCTION technique_trial_answers(p_technique_id bigint)
RETURNS TEXT[]
LANGUAGE sql
STABLE
AS $fn$
    SELECT COALESCE(array_agg(DISTINCT x.answer), ARRAY[]::text[])
    FROM techniques t
    CROSS JOIN LATERAL jsonb_array_elements(
        COALESCE(t.effects -> 'apply', '[]'::jsonb)) e
    CROSS JOIN LATERAL (
        SELECT CASE e ->> 'code'
            WHEN 'taunt'      THEN 'pull'
            WHEN 'regen'      THEN 'mend'
            WHEN 'defence_up' THEN 'harden'
            WHEN 'block_up'   THEN 'harden'
        END
    ) AS x (answer)
    WHERE t.technique_id = p_technique_id AND x.answer IS NOT NULL;
$fn$;

COMMENT ON FUNCTION technique_trial_answers(bigint) IS
    'Which of a Peer Trial''s threats this technique answers, as pull / harden / mend. The one place that mapping is written down for anything that needs to ask a technique rather than a player.';


-- ---------------------------------------------------------------------------
-- The shelf and the party screen mean the same thing by "can pull"
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_player BIGINT;
    v_bad    TEXT;
    r        RECORD;
BEGIN
    -- The nine from 0459 each answer exactly what they were seeded to answer.
    FOR r IN
        SELECT * FROM (VALUES
            ('step_into_the_gap',         'pull'),
            ('bared_edge',                'pull'),
            ('the_struck_bell',           'pull'),
            ('first_to_draw_the_sky',     'pull'),
            ('heaven_marks_the_standing', 'pull'),
            ('even_breath',               'mend'),
            ('hands_that_knit',           'mend'),
            ('a_moment_returned',         'mend'),
            ('rime_guard',                'harden')
        ) AS t (code, answer)
    LOOP
        IF NOT (r.answer = ANY (technique_trial_answers(
                    (SELECT technique_id FROM techniques WHERE code = r.code)))) THEN
            RAISE EXCEPTION '% does not answer %, which is what it is for',
                r.code, r.answer;
        END IF;
    END LOOP;

    -- An attack answers nothing, or the filter would show the whole catalogue.
    IF EXISTS (
        SELECT 1 FROM techniques t
        WHERE t.category = 'attack'
          AND NOT (t.effects ? 'apply')
          AND array_length(technique_trial_answers(t.technique_id), 1) > 0
    ) THEN
        RAISE EXCEPTION 'a plain attack is being counted as an answer';
    END IF;

    -- And the party screen's own reckoning still matches this one. Checked
    -- against a real roster rather than by reading the two sources side by
    -- side, because what matters is that they agree about a person.
    BEGIN
        SELECT p.player_id INTO v_player FROM players p
        WHERE p.deleted_at IS NULL AND trial_party_of(p.player_id) IS NULL
          AND EXISTS (SELECT 1 FROM player_techniques pt
                      WHERE pt.player_id = p.player_id)
        ORDER BY p.player_id LIMIT 1;
        IF v_player IS NULL THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        PERFORM trial_party_open(v_player);

        SELECT string_agg(bad.said, '; ') INTO v_bad
        FROM (
            SELECT format('%s: roster says pull=%s mend=%s harden=%s, '
                          'techniques say %s',
                          ros.discord_name, ros.can_pull, ros.can_mend,
                          ros.can_shield, mine.answers) AS said
            FROM trial_party_roster(trial_party_of(v_player)) ros
            CROSS JOIN LATERAL (
                SELECT COALESCE(array_agg(DISTINCT a), ARRAY[]::text[]) AS answers
                FROM player_techniques pt
                CROSS JOIN LATERAL unnest(
                    technique_trial_answers(pt.technique_id)) AS u (a)
                WHERE pt.player_id = ros.player_id
            ) mine
            WHERE ros.can_pull   <> ('pull'   = ANY (mine.answers))
               OR ros.can_mend   <> ('mend'   = ANY (mine.answers))
               OR ros.can_shield <> ('harden' = ANY (mine.answers))
        ) bad;

        IF v_bad IS NOT NULL THEN
            RAISE EXCEPTION
                'the party screen and the shelf disagree - %', v_bad;
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;
END;
$probe$;
