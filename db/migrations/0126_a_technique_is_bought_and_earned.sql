-- 0126_a_technique_is_bought_and_earned
--
-- `/learn` cost nothing. It checked one thing - is this technique's rank at or
-- below your realm's - and inserted the row. So the correct play was to learn
-- every technique at your rank the moment you arrived, which is not a decision,
-- and unsurprisingly nobody bothered: six of the ten live cultivators have
-- learned none at all, and the most anyone holds is two.
--
-- A thing that is free and unbounded is not a reward. Two gates, and they are
-- deliberately different in kind:
--
--   MONEY - Spirit Stones, 25 at rank 1 and triple a rank after: 25, 75, 225,
--   675, 2,025, 6,075, 18,225, 54,675, 164,025. Stones are the currency the
--   Broker pays in and the one thing this game generates plenty of and had
--   almost nothing to spend on. This is the sink.
--
--   EARNING - attainment in the technique's own dominant Path, one tier below
--   its rank. Rank 1 asks for nothing. Rank 2 asks only that you have trained
--   the Path at all. Rank 3 wants Expert, rank 6 wants Quasi-Grandmaster,
--   rank 9 wants Great Grandmaster. This is the half money cannot buy, and it
--   is what stops a rich cultivator at Nascent Soul owning every rank 4
--   technique in the game the afternoon they arrive.
--
-- WHY NOT INSIGHT AS THE PRICE. Because insight is not a balance, it is a
-- lifetime total, and `attainment_tier_for_insight` reads it to decide your
-- tier. Spending it would demote you - paying for a stronger technique by
-- getting worse at the Path it belongs to. So insight is the qualification and
-- stones are the fee, which is also how it reads in the fiction.
--
-- NOBODY LOSES ANYTHING. Techniques already learned stay learned; this prices
-- the next one, not the last one. And every character is handed an equipped
-- starter manual that lends a rank 1 technique (0029), so a cultivator with no
-- stones on their first day can still hunt - they simply cannot yet buy.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('technique_learn_base', 25,
     'Spirit Stones for a rank 1 technique.'),
    ('technique_learn_growth', 3,
     'How much dearer a technique gets per rank. 25 at rank 1 reaches 164,025 at rank 9.')
ON CONFLICT (key) DO UPDATE SET
    value = EXCLUDED.value, description = EXCLUDED.description;


-- ---------------------------------------------------------------------------
-- What a technique costs, and what it asks of you
-- ---------------------------------------------------------------------------
-- Both take the rank rather than the technique, because `/techniques` prices a
-- whole shelf at once and a per-row function call would be forty lookups of
-- two config keys.

CREATE FUNCTION technique_stone_cost(p_rank SMALLINT)
RETURNS BIGINT
LANGUAGE sql STABLE
AS $$
    SELECT round(game_config_value('technique_learn_base')
                 * power(game_config_value('technique_learn_growth'),
                         GREATEST(0, p_rank - 1)))::bigint;
$$;

COMMENT ON FUNCTION technique_stone_cost(SMALLINT) IS
    'Spirit Stones to learn a technique of this rank. Triples a rank, so the fee keeps pace with what a realm can earn.';


CREATE FUNCTION technique_required_tier(p_rank SMALLINT)
RETURNS SMALLINT
LANGUAGE sql IMMUTABLE
AS $$
    SELECT GREATEST(0, LEAST(10, p_rank - 1))::smallint;
$$;

COMMENT ON FUNCTION technique_required_tier(SMALLINT) IS
    'Attainment tier the technique''s dominant Path must have reached. One below its rank, so rank 1 asks for nothing.';


-- ---------------------------------------------------------------------------
-- technique_shelf
-- ---------------------------------------------------------------------------
-- Everything canonical, priced and judged against one cultivator. This is the
-- only place that decides whether a technique may be learned - `/techniques`
-- draws it, `/learn` enforces it, and there is therefore no way for the screen
-- to promise something the command then refuses.
--
-- The dominant Path is the highest-weighted one; a 50/50 move like Stolen
-- Years is judged on whichever of its two the cultivator is BETTER at, which
-- is generous on purpose. A dual-Path technique is meant to be the answer to
-- being blocked, not a second lock.

CREATE FUNCTION technique_shelf(p_player_id BIGINT)
RETURNS TABLE (
    technique_id   BIGINT,
    code           TEXT,
    name           TEXT,
    tech_rank      SMALLINT,
    category       TEXT,
    base_power     INTEGER,
    typing         TEXT,
    path_code      TEXT,
    path_name      TEXT,
    need_tier      SMALLINT,
    need_tier_name TEXT,
    have_tier      SMALLINT,
    stone_cost     BIGINT,
    stones_held    BIGINT,
    known          BOOLEAN,
    on_loan        BOOLEAN,
    realm_ok       BOOLEAN,
    tier_ok        BOOLEAN,
    stones_ok      BOOLEAN,
    ready          BOOLEAN
)
LANGUAGE sql STABLE
AS $$
    WITH me AS (
        SELECT
            COALESCE((SELECT r.rank FROM player_cultivation pc
                      JOIN realms r ON r.realm_id = pc.realm_id
                      WHERE pc.player_id = p_player_id), 0)::smallint AS realm_rank,
            COALESCE((SELECT pm.quantity FROM player_materials pm
                      WHERE pm.player_id = p_player_id
                        AND pm.material_code = 'spirit_stone'), 0)::bigint AS stones
    )
    SELECT
        t.technique_id,
        t.code,
        t.name,
        t.rank,
        t.category,
        t.base_power,
        typed.typing,
        dom.path_code,
        dom.path_name,
        technique_required_tier(t.rank),
        tiers.name,
        dom.have_tier,
        technique_stone_cost(t.rank),
        me.stones,
        mine.player_id IS NOT NULL,
        mine.player_id IS NULL AND loan.technique_id IS NOT NULL,
        t.rank <= me.realm_rank,
        dom.have_tier >= technique_required_tier(t.rank),
        me.stones >= technique_stone_cost(t.rank),
        mine.player_id IS NULL
            AND t.rank <= me.realm_rank
            AND dom.have_tier >= technique_required_tier(t.rank)
            AND me.stones >= technique_stone_cost(t.rank)
    FROM techniques t
    CROSS JOIN me
    JOIN attainment_tiers tiers ON tiers.tier = technique_required_tier(t.rank)
    LEFT JOIN player_techniques mine
           ON mine.player_id = p_player_id AND mine.technique_id = t.technique_id
    LEFT JOIN LATERAL (
        SELECT DISTINCT u.technique_id
        FROM player_usable_techniques u
        WHERE u.player_id = p_player_id AND u.technique_id = t.technique_id
    ) loan ON TRUE
    LEFT JOIN LATERAL (
        SELECT tp.path_code,
               p.name AS path_name,
               COALESCE(ppa.tier, 0)::smallint AS have_tier
        FROM technique_paths tp
        JOIN paths p ON p.code = tp.path_code
        LEFT JOIN player_path_attainment ppa
               ON ppa.player_id = p_player_id AND ppa.path_code = tp.path_code
        WHERE tp.technique_id = t.technique_id
        ORDER BY tp.weight DESC, COALESCE(ppa.tier, 0) DESC, p.sort_order
        LIMIT 1
    ) dom ON TRUE
    LEFT JOIN LATERAL (
        SELECT string_agg(p.name, ' + ' ORDER BY tp.weight DESC, p.sort_order)
                   AS typing
        FROM technique_paths tp
        JOIN paths p ON p.code = tp.path_code
        WHERE tp.technique_id = t.technique_id
    ) typed ON TRUE
    WHERE t.created_by IS NULL
    ORDER BY t.rank, t.base_power DESC, t.name;
$$;

COMMENT ON FUNCTION technique_shelf(BIGINT) IS
    'Every canonical technique priced and judged against one cultivator: what it costs, what Path tier it asks for, and whether they already know it or are only borrowing it from a manual.';


-- ---------------------------------------------------------------------------
-- learn_technique
-- ---------------------------------------------------------------------------
-- Reads the shelf rather than re-deciding anything, so a refusal here and a
-- greyed-out row there can never disagree. `spend_material` is what actually
-- takes the stones, in one statement, so two /learn commands racing cannot
-- both spend the last of them.

CREATE FUNCTION learn_technique(p_player_id BIGINT, p_technique_id BIGINT)
RETURNS TABLE (
    learned_name  TEXT,
    stones_spent  BIGINT,
    stones_left   BIGINT,
    dominant_path TEXT,
    was_on_loan   BOOLEAN
)
LANGUAGE plpgsql
AS $$
DECLARE
    shelf    RECORD;
    realm    TEXT;
    leftover BIGINT;
BEGIN
    SELECT * INTO shelf FROM technique_shelf(p_player_id) s
    WHERE s.technique_id = p_technique_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'there is no such technique to learn'
            USING ERRCODE = 'check_violation';
    END IF;

    IF shelf.known THEN
        RAISE EXCEPTION 'you already know %', shelf.name
            USING ERRCODE = 'check_violation';
    END IF;

    IF NOT shelf.realm_ok THEN
        SELECT r.name INTO realm
        FROM player_cultivation pc
        JOIN realms r ON r.realm_id = pc.realm_id
        WHERE pc.player_id = p_player_id;

        RAISE EXCEPTION '% is a rank % technique and you are at %',
            shelf.name, shelf.tech_rank, COALESCE(realm, 'no realm at all')
            USING ERRCODE = 'check_violation';
    END IF;

    IF NOT shelf.tier_ok THEN
        RAISE EXCEPTION '% asks for % in the %, and you are %',
            shelf.name, shelf.need_tier_name, shelf.path_name,
            (SELECT at.name FROM attainment_tiers at WHERE at.tier = shelf.have_tier)
            USING ERRCODE = 'check_violation';
    END IF;

    -- Last, so a cultivator is never charged for something a later check
    -- would have refused. spend_material raises its own shortfall message.
    leftover := spend_material(p_player_id, 'spirit_stone', shelf.stone_cost);

    INSERT INTO player_techniques (player_id, technique_id)
    VALUES (p_player_id, p_technique_id);

    RETURN QUERY SELECT shelf.name, shelf.stone_cost, leftover,
                        shelf.path_name, shelf.on_loan;
END;
$$;

COMMENT ON FUNCTION learn_technique(BIGINT, BIGINT) IS
    'Buys a technique: checks the shelf, takes the Spirit Stones, records it. Raises with the reason if any gate is shut.';


-- ---------------------------------------------------------------------------
-- The prices have to be reachable
-- ---------------------------------------------------------------------------
-- A ladder that outruns the game is the same bug as one that ends early, and
-- it would be just as invisible. Rank 1 has to be affordable to somebody who
-- has done a little exploring; every rank has to cost more than the one below.

DO $$
DECLARE
    r          INTEGER;
    prev       BIGINT := 0;
    this       BIGINT;
    explore_lo NUMERIC := game_config_value('explore_spirit_stone_min');
BEGIN
    FOR r IN 1..9 LOOP
        this := technique_stone_cost(r::smallint);
        IF this <= prev THEN
            RAISE EXCEPTION 'rank % costs % and rank % costs %',
                r, this, r - 1, prev;
        END IF;
        prev := this;
    END LOOP;

    IF technique_stone_cost(1::smallint) > explore_lo * 20 THEN
        RAISE EXCEPTION
            'a first technique costs % stones, more than twenty of the leanest explorations',
            technique_stone_cost(1::smallint);
    END IF;
END;
$$;
