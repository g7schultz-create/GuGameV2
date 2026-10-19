-- 0476_a_delve_you_can_read_catch_your_breath_in_and_mend
--
-- Four things a delve was missing.
--
-- WHAT YOU PICKED UP, WITH ITS FACE ON. Every one of the three hundred and
-- seven materials in this game carries an emoji and the haul printed none of
-- them, so a tally read as a wall of names. The haul keeps the glyph now. It
-- is looked up by name rather than carried down from the three verbs that
-- found the thing, because material names are unique - checked, all 307 of
-- them - and threading a column through `mine`, `gather` and `explore` to
-- decorate a receipt is three changes to pay for one.
--
-- A MEND THAT MENDS. `player_swing` has always written a technique's regen
-- into `battle_effects` at the delve's scope, and nothing in the delve ever
-- read it back. A dungeon does:
--
--     current_hp + max_hp * effect_value('dungeon', run, player, 'regen')
--
-- so a support technique in a delve applied an effect that sat there and
-- expired. The same line, in the same place in the round, and from here a
-- mend is a thing worth throwing - which is also what makes the technique
-- picker worth opening at all.
--
-- A BREATH, FOR AN ACTION. `Rest` costs one action and returns the whole
-- body. That is a real price: an action is a tile you will not reach, and a
-- delve has sixteen against thirty tiles. It is refused mid-fight, because a
-- full heal in front of something that is hitting you is not a breather, it
-- is immortality.
--
-- AND A PILL FOR NOTHING. Pills cost no action. They are finite, somebody
-- brewed them, and making a cultivator spend a tile to swallow one they are
-- already carrying would simply mean nobody carries one. `take_pill` is the
-- authority on what may be taken and says so in its own words, so this hands
-- straight to it rather than deciding again.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('delve_rest_actions', 1,
     'What catching your breath costs. One action - a tile you will not reach - which is the whole price of a full body.')
ON CONFLICT (key) DO UPDATE
SET value = EXCLUDED.value, description = EXCLUDED.description;


-- ---------------------------------------------------------------------------
-- What you picked up, with its face on
-- ---------------------------------------------------------------------------

ALTER TABLE delve_haul ADD COLUMN emoji TEXT;

COMMENT ON COLUMN delve_haul.emoji IS
    'The material''s own glyph, so a tally reads as things rather than as a list of names. Looked up by name, which is unique across all 307 materials.';

UPDATE delve_haul h SET emoji = m.emoji
FROM materials m WHERE m.name = h.what AND h.emoji IS NULL;


CREATE OR REPLACE FUNCTION delve_record(p_delve_id bigint, p_found jsonb)
RETURNS void
LANGUAGE sql
AS $fn$
    INSERT INTO delve_haul (delve_id, what, how_many, emoji)
    SELECT p_delve_id, e ->> 'what', sum((e ->> 'how_many')::bigint),
           max(m.emoji)
    FROM jsonb_array_elements(COALESCE(p_found, '[]'::jsonb)) e
    LEFT JOIN materials m ON m.name = e ->> 'what'
    WHERE e ->> 'what' IS NOT NULL
      AND COALESCE((e ->> 'how_many')::bigint, 0) > 0
    GROUP BY e ->> 'what'
    ON CONFLICT (delve_id, what) DO UPDATE
    SET how_many = delve_haul.how_many + EXCLUDED.how_many,
        emoji = COALESCE(delve_haul.emoji, EXCLUDED.emoji);
$fn$;


CREATE OR REPLACE FUNCTION delve_haul_of(p_delve_id bigint)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $fn$
    SELECT string_agg(COALESCE(h.emoji || ' ', '') || h.how_many || 'x ' || h.what,
                      chr(10) ORDER BY h.how_many DESC, h.what)
    FROM delve_haul h WHERE h.delve_id = p_delve_id;
$fn$;


-- ---------------------------------------------------------------------------
-- A breath, and a pill
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION delve_rest(p_player_id bigint)
RETURNS TABLE(delve_id bigint, healed bigint, my_hp bigint, my_max bigint,
              actions_left integer, status text, outcome text)
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_id   BIGINT;
    d      RECORD;
    v_was  BIGINT;
    v_max  BIGINT;
BEGIN
    v_id := delve_of(p_player_id);
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'you are not down a delve' USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO d FROM delve_runs r WHERE r.delve_id = v_id FOR UPDATE;
    IF d.status = 'fighting' THEN
        RAISE EXCEPTION 'there is something standing over you'
            USING ERRCODE = 'check_violation';
    END IF;
    IF d.actions_left < game_config_value('delve_rest_actions')::int THEN
        RAISE EXCEPTION 'you have not the strength left to stop'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT GREATEST(0, COALESCE(pp.current_hp, 0)),
           GREATEST(1, COALESCE(pp.max_hp, 1))
    INTO v_was, v_max
    FROM player_physique pp WHERE pp.player_id = p_player_id;

    UPDATE player_physique pp SET current_hp = GREATEST(1, v_max)
    WHERE pp.player_id = p_player_id;

    UPDATE delve_runs r
    SET actions_left = GREATEST(0, r.actions_left
                                   - game_config_value('delve_rest_actions')::int)
    WHERE r.delve_id = v_id;

    SELECT * INTO d FROM delve_runs r WHERE r.delve_id = v_id;
    IF d.actions_left <= 0 THEN
        PERFORM delve_end(v_id, 'spent');
        SELECT * INTO d FROM delve_runs r WHERE r.delve_id = v_id;
    END IF;

    RETURN QUERY SELECT v_id, GREATEST(0, v_max - COALESCE(v_was, 0)),
        v_max, v_max, d.actions_left::int, d.status, d.outcome;
END;
$fn$;

COMMENT ON FUNCTION delve_rest(bigint) IS
    'Stops for breath. One action for the whole body, and refused while something is standing over you - a full heal mid-fight is not a breather.';


CREATE OR REPLACE FUNCTION delve_swallow(p_player_id bigint, p_pill_id bigint)
RETURNS TABLE(pill_name text, kind text, granted bigint, detail text,
              remaining smallint, my_hp bigint, my_max bigint)
LANGUAGE plpgsql
AS $fn$
DECLARE
    took RECORD;
BEGIN
    IF delve_of(p_player_id) IS NULL THEN
        RAISE EXCEPTION 'you are not down a delve' USING ERRCODE = 'check_violation';
    END IF;

    -- No action is spent. `take_pill` is the authority on whether this pill
    -- may be taken at all and refuses in its own words; deciding again here
    -- would be a second opinion to keep in step with the first.
    SELECT * INTO took FROM take_pill(p_player_id, p_pill_id, NULL);

    RETURN QUERY
    SELECT took.pill_name, took.kind, took.granted, took.detail, took.remaining,
           GREATEST(0, COALESCE(pp.current_hp, 0)),
           GREATEST(1, COALESCE(pp.max_hp, 1))
    FROM player_physique pp WHERE pp.player_id = p_player_id;
END;
$fn$;

COMMENT ON FUNCTION delve_swallow(bigint, bigint) IS
    'Takes a pill while underground, at no cost in actions. Pills are finite and somebody brewed them; charging a tile to swallow one would mean nobody ever carries one down.';


-- ---------------------------------------------------------------------------
-- And a mend that mends
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'delve_act' AND pronamespace = 'public'::regnamespace;
    IF body IS NULL THEN
        RAISE EXCEPTION 'delve_act is missing';
    END IF;

    anchor := concat(
'    UPDATE player_physique pp SET current_hp = v_hp', chr(10),
'    WHERE pp.player_id = p_player_id;');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'delve_act no longer writes the body where it did';
    END IF;

    EXECUTE replace(body, anchor, concat(
'    -- 0476: whatever is mending you. A dungeon has read this back every', chr(10),
'    -- round since it had rounds; a delve wrote the effect and never looked.', chr(10),
'    IF effect_value(''delve'', v_delve, p_player_id, ''regen'') > 0 THEN', chr(10),
'        v_heal := v_heal + GREATEST(1, floor(v_max', chr(10),
'            * effect_value(''delve'', v_delve, p_player_id, ''regen'')))::bigint;', chr(10),
'        v_hp := LEAST(v_max, v_hp + GREATEST(1, floor(v_max', chr(10),
'            * effect_value(''delve'', v_delve, p_player_id, ''regen''))))::bigint;', chr(10),
'    END IF;', chr(10),
'', chr(10),
anchor));
END;
$patch$;


-- ---------------------------------------------------------------------------
-- The haul reads, the breath costs, the pill does not, and a mend mends
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_p    BIGINT;
    v_id   BIGINT;
    at     RECORD;
    dr     RECORD;
    got    RECORD;
    v_tech BIGINT;
    v_hp0  BIGINT;
    v_hp1  BIGINT;
    v_left INTEGER;
BEGIN
    -- Every material can be shown. If one could not, the tally would print a
    -- bare name beside twenty decorated ones.
    IF EXISTS (SELECT 1 FROM materials WHERE emoji IS NULL OR emoji = '') THEN
        RAISE EXCEPTION 'some material has no face to show';
    END IF;

    BEGIN
        SELECT p.player_id INTO v_p FROM players p
        JOIN player_location pl ON pl.player_id = p.player_id
        JOIN player_physique pp ON pp.player_id = p.player_id
        WHERE p.deleted_at IS NULL AND delve_of(p.player_id) IS NULL
          AND EXISTS (SELECT 1 FROM player_techniques pt
                      WHERE pt.player_id = p.player_id)
          AND EXISTS (SELECT 1 FROM region_veins v
                      WHERE v.region_code = pl.region_code)
          AND EXISTS (SELECT 1 FROM creature_regions cr
                      WHERE cr.region_code = pl.region_code)
        ORDER BY player_realm_rank(p.player_id) DESC, p.player_id LIMIT 1;
        IF v_p IS NULL THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        DELETE FROM player_cooldowns WHERE player_id = v_p AND action = 'delve';
        v_id := delve_open(v_p);
        SELECT dr2.at_x, dr2.at_y INTO at FROM delve_runs dr2
        WHERE dr2.delve_id = v_id;

        -- ---- the haul wears its glyphs -------------------------------------
        UPDATE delve_tiles t SET kind = 'seam', spent = FALSE
        WHERE t.delve_id = v_id AND t.x = at.at_x AND t.y = at.at_y - 1;
        PERFORM delve_step(v_p, 'up');

        IF EXISTS (SELECT 1 FROM delve_haul h
                   WHERE h.delve_id = v_id AND h.emoji IS NULL) THEN
            RAISE EXCEPTION 'something came up out of the stone with no face';
        END IF;
        RAISE NOTICE 'the haul reads:%', chr(10) || delve_haul_of(v_id);

        -- ---- a breath costs an action and gives the body back --------------
        UPDATE player_physique pp SET current_hp = 1 WHERE pp.player_id = v_p;
        SELECT dr2.actions_left INTO v_left FROM delve_runs dr2
        WHERE dr2.delve_id = v_id;

        SELECT * INTO got FROM delve_rest(v_p);
        IF got.my_hp <> got.my_max THEN
            RAISE EXCEPTION 'resting left % of %', got.my_hp, got.my_max;
        END IF;
        IF got.actions_left <> v_left - game_config_value('delve_rest_actions')::int THEN
            RAISE EXCEPTION 'resting cost % actions',
                v_left - got.actions_left;
        END IF;

        -- ---- and is refused with something standing over you ---------------
        UPDATE delve_tiles t SET kind = 'beast', spent = FALSE
        WHERE t.delve_id = v_id AND t.x = at.at_x AND t.y = at.at_y - 2;
        PERFORM delve_step(v_p, 'up');
        IF (SELECT dr2.status FROM delve_runs dr2 WHERE dr2.delve_id = v_id)
           <> 'fighting' THEN
            RAISE EXCEPTION 'the probe never got into a fight';
        END IF;

        BEGIN
            PERFORM delve_rest(v_p);
            RAISE EXCEPTION 'you can stop for breath mid-fight';
        EXCEPTION WHEN check_violation THEN
            NULL;
        END;

        -- ---- a mend mends --------------------------------------------------
        UPDATE player_physique pp SET current_hp = GREATEST(1, pp.max_hp / 2)
        WHERE pp.player_id = v_p;
        SELECT pp.current_hp INTO v_hp0 FROM player_physique pp
        WHERE pp.player_id = v_p;

        -- Put a real regen on them, the way a support technique would.
        PERFORM effect_apply('delve', v_id, v_p, 'regen', 0.10, 3, NULL, FALSE);
        UPDATE delve_fights x SET coming = 'circle' WHERE x.delve_id = v_id
          AND x.status = 'fighting';

        SELECT * INTO got FROM delve_act(v_p, 'guard', NULL);
        SELECT pp.current_hp INTO v_hp1 FROM player_physique pp
        WHERE pp.player_id = v_p;

        IF got.healed <= 0 THEN
            RAISE EXCEPTION 'a regen on the board healed nothing';
        END IF;
        RAISE NOTICE 'a mend returned % of a body of %', got.healed, got.my_max;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- A pill costs no action, which is the whole of what was asked for.
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'delve_swallow'
        AND pronamespace = 'public'::regnamespace) LIKE '%actions_left%' THEN
        RAISE EXCEPTION 'swallowing a pill spends something';
    END IF;
END;
$probe$;
