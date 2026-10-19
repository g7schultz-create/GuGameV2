-- 0130_the_manual_that_is_the_move
--
-- A new kind of manual, for the advanced techniques 0129 added.
--
-- Every manual until now was a training aid: you equip it and some rate goes
-- up. Ten of them also happened to teach a technique, and all ten taught a
-- BASIC one - something /learn would have sold you for stones. The payload was
-- decoration on a stat stick.
--
-- `archetype = 'technique'` is the manual whose payload IS the move. It exists
-- to carry one advanced technique; the modest attack bonus it also grants is
-- there so the slot is not a pure sacrifice, not because the bonus is the
-- point. Eighteen of them, one per advanced technique, tier and required rank
-- tracking what they teach.
--
-- THE RANK GATE MOVES INTO THE VIEW. `manuals.required_rank` has never been
-- enforced anywhere - the equip picker hides a manual above your rank and the
-- database was happy to let a traded one through. That was survivable when the
-- worst case was borrowing a rank 6 move at 10,000 power. It is not survivable
-- now that a rank 9 technique manual exists and is tradeable, so
-- `player_usable_techniques` - which is what combat validates against, and the
-- only thing that does - now refuses a technique above the wielder's realm
-- whatever is lending it.
--
-- No live cultivator loses access to anything: this was checked against every
-- equipped manual in the database before the view was replaced.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE manuals DROP CONSTRAINT manuals_archetype_check;
ALTER TABLE manuals ADD CONSTRAINT manuals_archetype_check
    CHECK (archetype IN ('cultivation', 'offensive', 'defensive', 'movement',
                         'body', 'gathering', 'refinement', 'essence',
                         'breakthrough', 'hybrid', 'technique'));


-- ---------------------------------------------------------------------------
-- The eighteen
-- ---------------------------------------------------------------------------
-- tier is rank + 1, capped at the ten `manual_tiers` defines. required_rank is
-- the technique's own rank, because a manual you cannot use the move out of is
-- a manual that lies about what it is for.
--
-- The attack bonus is half the tier's budget. Half rather than all because the
-- other half was spent on the technique - which is the whole trade this
-- archetype exists to make.

INSERT INTO manuals
    (code, name, tier, required_rank, archetype, attack_bonus, description)
SELECT
    t.code || '_manual',
    v.manual_name,
    LEAST(10, t.rank + 1)::smallint,
    t.rank,
    'technique',
    round(mt.bonus_budget * 0.5, 4),
    v.blurb
FROM (VALUES
    ('blood_drinking_awl', 'Awl of the Drinking Vein',
     'The technique, and a great deal about where to put it.'),
    ('hoarfrost_execution_form', 'Hoarfrost Execution Scroll',
     'Eleven pages. Nine of them are about standing still.'),

    ('wolf_tide_charge', 'Wolf Tide Canon',
     'Written by someone who watched, from a tree, for two days.'),
    ('creeping_rot_sigil', 'Creeping Rot Sigil Record',
     'The sigil is on the last page. The first forty are what happens if you draw it wrong.'),

    ('thunder_gale_dismemberment', 'Thunder Gale Butchery Manual',
     'It is not called a butchery manual as a metaphor.'),
    ('hungry_shade_grasp', 'Record of the Hungry Shade',
     'Recovered from a grave that had been opened from the inside.'),

    ('iron_river_severance', 'Iron River Severance Art',
     'A smith''s notes and a boatman''s notes, bound together by someone who was both.'),
    ('pyre_of_borrowed_years', 'Pyre of Borrowed Years',
     'The ledger at the back is the important part, and it is written in a shakier hand than the rest.'),

    ('mountain_swallowing_maw', 'Mountain-Swallowing Scripture',
     'Heavier than a book its size has any business being.'),
    ('crimson_moth_requiem', 'Crimson Moth Requiem',
     'Score and technique in the same notation, because to its author they were the same thing.'),

    ('heaven_defying_edge', 'Heaven-Defying Edge Canon',
     'Six cultivators are known to have finished it. Two are known to have survived finishing it.'),
    ('bone_tide_annihilation', 'Bone Tide Annihilation Record',
     'Salt-stained through, and none of the stains are from the sea.'),

    ('star_severing_palm', 'Star-Severing Palm Scripture',
     'The diagrams are of distances, not of hands.'),
    ('dream_thief_verdict', 'Verdict of the Dream Thief',
     'Read it before sleeping and you will be told what you are charged with.'),

    ('light_devouring_formation', 'Light-Devouring Formation Plates',
     'Nine hundred plates, numbered, and the numbering is not the order.'),
    ('ten_thousand_shapes_undone', 'Ten Thousand Shapes Undone',
     'Every page is the same page, and it is a different page every time.'),

    ('sovereign_immortal_killer_move', 'Sovereign Immortal Killer Move',
     'Not a manual so much as a signature, left where the next one would find it.'),
    ('eternal_hunger_of_the_nine', 'Canon of the Eternal Hunger',
     'It is still hungry. That is the first line and it is not a figure of speech.')
) AS v (technique_code, manual_name, blurb)
JOIN techniques t ON t.code = v.technique_code
JOIN manual_tiers mt ON mt.tier = LEAST(10, t.rank + 1);


INSERT INTO manual_techniques (manual_id, technique_id)
SELECT m.manual_id, t.technique_id
FROM manuals m
JOIN techniques t ON m.code = t.code || '_manual'
WHERE m.archetype = 'technique';


INSERT INTO manual_paths (manual_id, path_code, weight)
SELECT m.manual_id, tp.path_code, tp.weight
FROM manuals m
JOIN techniques t ON m.code = t.code || '_manual'
JOIN technique_paths tp ON tp.technique_id = t.technique_id
WHERE m.archetype = 'technique';


-- ---------------------------------------------------------------------------
-- player_usable_techniques, with the rank gate it never had
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW player_usable_techniques AS
SELECT pt.player_id, pt.technique_id, 'learned'::text AS source,
       NULL::bigint AS manual_id
FROM player_techniques pt
JOIN techniques t ON t.technique_id = pt.technique_id
JOIN player_cultivation pc ON pc.player_id = pt.player_id
JOIN realms r ON r.realm_id = pc.realm_id
WHERE t.rank <= r.rank

UNION

SELECT s.player_id, mt.technique_id, 'manual'::text, m.manual_id
FROM player_manual_slots s
JOIN manuals m ON m.manual_id = s.manual_id
JOIN manual_techniques mt ON mt.manual_id = m.manual_id
JOIN techniques t ON t.technique_id = mt.technique_id
JOIN player_cultivation pc ON pc.player_id = s.player_id
JOIN realms r ON r.realm_id = pc.realm_id
WHERE t.rank <= r.rank;

COMMENT ON VIEW player_usable_techniques IS
    'Learned techniques plus those an equipped manual lends, both gated by realm rank. Unequipping withdraws access with no bookkeeping; so does a technique that outranks its wielder.';


-- ---------------------------------------------------------------------------
-- The shelf learns the difference
-- ---------------------------------------------------------------------------
-- Dropped and recreated rather than replaced: a returned column is being
-- added, and CREATE OR REPLACE cannot change a return type. `learn_technique`
-- resolves it at call time, so it needs no attention beyond the refusal added
-- below.
--
-- An advanced technique still APPEARS on the shelf, priced at nothing and
-- named with the manual that carries it. Hiding it would leave a player with
-- no way to find out that the thing exists, which is the failure /gurefine had
-- before it learned to show recipes you cannot yet make.

DROP FUNCTION technique_shelf(BIGINT);

CREATE FUNCTION technique_shelf(p_player_id BIGINT)
RETURNS TABLE (
    technique_id   BIGINT,
    code           TEXT,
    name           TEXT,
    tech_rank      SMALLINT,
    grade          TEXT,
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
    manual_name    TEXT,
    manual_held    BOOLEAN,
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
        t.grade,
        t.category,
        t.base_power,
        typed.typing,
        dom.path_code,
        dom.path_name,
        technique_required_tier(t.rank),
        tiers.name,
        dom.have_tier,
        -- An advanced technique has no price, and 0 is how the screen knows
        -- not to quote one. It is never bought at any figure.
        CASE WHEN t.grade = 'advanced' THEN 0::bigint
             ELSE technique_stone_cost(t.rank) END,
        me.stones,
        book.manual_name,
        book.held,
        mine.player_id IS NOT NULL,
        mine.player_id IS NULL AND loan.technique_id IS NOT NULL,
        t.rank <= me.realm_rank,
        dom.have_tier >= technique_required_tier(t.rank),
        t.grade = 'advanced' OR me.stones >= technique_stone_cost(t.rank),
        -- Ready means /learn will take it. An advanced technique never is.
        t.grade = 'basic'
            AND mine.player_id IS NULL
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
        SELECT m.name AS manual_name,
               EXISTS (SELECT 1 FROM player_manuals pm
                       WHERE pm.player_id = p_player_id
                         AND pm.manual_id = m.manual_id) AS held
        FROM manual_techniques mtq
        JOIN manuals m ON m.manual_id = mtq.manual_id
        WHERE mtq.technique_id = t.technique_id
          AND m.archetype = 'technique'
        ORDER BY EXISTS (SELECT 1 FROM player_manuals pm
                         WHERE pm.player_id = p_player_id
                           AND pm.manual_id = m.manual_id) DESC,
                 m.manual_id
        LIMIT 1
    ) book ON TRUE
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
    ORDER BY t.rank, t.grade DESC, t.base_power DESC, t.name;
$$;

COMMENT ON FUNCTION technique_shelf(BIGINT) IS
    'Every canonical technique judged against one cultivator. Basic ones carry a price; advanced ones carry the name of the manual that teaches them, and no price at all.';


-- ---------------------------------------------------------------------------
-- learn_technique will not sell what is not for sale
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION learn_technique(p_player_id BIGINT, p_technique_id BIGINT)
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

    -- First, because it is the one refusal that is not about the cultivator
    -- falling short. No amount of realm, attainment or money buys this.
    IF shelf.grade = 'advanced' THEN
        RAISE EXCEPTION
            '% is an advanced technique and cannot be learned at any price. It is carried by %, and only while that manual is equipped',
            shelf.name, COALESCE(shelf.manual_name, 'a manual')
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

    leftover := spend_material(p_player_id, 'spirit_stone', shelf.stone_cost);

    INSERT INTO player_techniques (player_id, technique_id)
    VALUES (p_player_id, p_technique_id);

    RETURN QUERY SELECT shelf.name, shelf.stone_cost, leftover,
                        shelf.path_name, shelf.on_loan;
END;
$$;


-- ---------------------------------------------------------------------------
-- Every advanced technique must be reachable, and nobody may lose a move
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    orphan TEXT;
    lost   INTEGER;
BEGIN
    SELECT t.name INTO orphan
    FROM techniques t
    WHERE t.created_by IS NULL AND t.grade = 'advanced'
      AND NOT EXISTS (
          SELECT 1 FROM manual_techniques mt
          JOIN manuals m ON m.manual_id = mt.manual_id
          WHERE mt.technique_id = t.technique_id AND m.archetype = 'technique'
      )
    LIMIT 1;

    IF orphan IS NOT NULL THEN
        RAISE EXCEPTION 'no manual teaches %, so nothing in the game does', orphan;
    END IF;

    -- The rank gate is new. If it takes a technique away from somebody who is
    -- using one today, that is a regression and not a tightening.
    SELECT count(*) INTO lost
    FROM player_manual_slots s
    JOIN manual_techniques mt ON mt.manual_id = s.manual_id
    JOIN techniques t ON t.technique_id = mt.technique_id
    JOIN player_cultivation pc ON pc.player_id = s.player_id
    JOIN realms r ON r.realm_id = pc.realm_id
    WHERE t.rank > r.rank;

    IF lost > 0 THEN
        RAISE EXCEPTION
            'the new rank gate would withdraw % technique(s) somebody has equipped today', lost;
    END IF;
END;
$$;
