-- 0309_a_technique_says_what_it_does
--
-- `/techniques` prints "N power" for anything with power and the bare word
-- "support" for anything without. That was a fair summary when the only thing
-- a technique could do was damage. It is now actively misleading: thirty-two
-- techniques mend, ward, set, rally and mark, and every one of them reads on
-- that screen as the word "support" and nothing else.
--
-- This renders the declaration into a sentence. One function, so the shelf,
-- the detail card and anything written later all say the same thing about the
-- same technique - a second renderer is a second answer waiting to disagree.
--
-- IT READS THE KIND'S OWN NAME rather than restating it. `battle_effect_kinds`
-- already calls them Rallied, Warded, Set, Marked and Mending; a summary that
-- hard-coded "Defence" would start lying the moment a kind was renamed.
--
-- `technique_shelf` IS NOT TOUCHED. Adding a column to it means dropping and
-- rebuilding the function every screen in this cog reads, to carry a string
-- none of them compute. The caller joins this on instead, which is a change
-- to one query rather than to the shape everything shares.
--
-- Forward-only. Do not edit once applied.


CREATE FUNCTION technique_effect_summary(p_technique_id BIGINT)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
    SELECT string_agg(
        k.name
        || ' ' || round(100 * (e ->> 'magnitude')::numeric) || '%'
        || ' for ' || (e ->> 'turns')
        || CASE WHEN (e ->> 'turns') = '1' THEN ' turn' ELSE ' turns' END
        || CASE WHEN COALESCE(e ->> 'target', 'self') = 'party'
                THEN ', whole party' ELSE '' END,
        ' * '
        ORDER BY (e ->> 'code')
    )
    FROM techniques t
    CROSS JOIN LATERAL jsonb_array_elements(t.effects -> 'apply') AS e
    JOIN battle_effect_kinds k ON k.code = e ->> 'code'
    WHERE t.technique_id = p_technique_id
      AND t.effects ? 'apply';
$$;

COMMENT ON FUNCTION technique_effect_summary(BIGINT) IS
    'What a technique leaves behind, in words, or NULL if it only deals damage.';


-- ---------------------------------------------------------------------------
-- It says something true about each of them
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    said TEXT;
    n    INTEGER;
BEGIN
    -- Everything that declares an effect renders to something.
    SELECT count(*) INTO n
    FROM techniques t
    WHERE t.effects ? 'apply' AND technique_effect_summary(t.technique_id) IS NULL;
    IF n > 0 THEN
        RAISE EXCEPTION '% techniques declare an effect and render to nothing', n;
    END IF;

    -- And everything that does not declare one renders to NULL rather than
    -- an empty string, so a caller can test it plainly.
    SELECT count(*) INTO n
    FROM techniques t
    WHERE NOT (t.effects ? 'apply')
      AND technique_effect_summary(t.technique_id) IS NOT NULL;
    IF n > 0 THEN
        RAISE EXCEPTION '% plain techniques rendered an effect they do not have', n;
    END IF;

    said := technique_effect_summary(
        (SELECT technique_id FROM techniques WHERE code = 'sovereigns_regard'));
    IF said IS NULL OR position('*' IN said) = 0 THEN
        RAISE EXCEPTION
            'a technique with two effects summarised as: %', COALESCE(said, 'nothing');
    END IF;

    RAISE NOTICE 'Sovereign''s Regard reads: %', said;

    said := technique_effect_summary(
        (SELECT technique_id FROM techniques WHERE code = 'bulwark_formation'));
    IF said NOT LIKE '%whole party%' THEN
        RAISE EXCEPTION 'a party technique does not say so: %', said;
    END IF;

    RAISE NOTICE 'Bulwark Formation reads: %', said;
END;
$$;
