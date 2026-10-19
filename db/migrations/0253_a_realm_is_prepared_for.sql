-- 0253_a_realm_is_prepared_for
--
-- Crossing a major realm was `/cultivate` until a number was large enough.
--
-- That is the one moment in this game everybody is working toward, and it
-- asked for nothing but patience. Meanwhile there are dungeons, world beasts,
-- Beast Hordes, an auction house, alchemy and eight professions, and none of
-- them are on the path to it - a cultivator can reach the Ancient Realm having
-- never opened any of them.
--
-- SO A MAJOR REALM IS PREPARED FOR. Entering a new great realm now wants
-- Spirit Stones, a Heaven and Earth Treasure, and a pill somebody had to brew.
-- Nothing new is invented to fill it: the treasures are beast materials, which
-- the Horde now pays out by the hundred and which had no sink beyond crafting,
-- and the pill is the one an alchemist already makes. This is connective
-- tissue, not content.
--
-- THE STAGES STAY FREE. Early to Mid to Late to Peak is the rhythm of ordinary
-- play and gating all thirty-five of them would make the game a shopping list.
-- Only the eight crossings that change your RANK ask for anything, which is
-- also the only place the doubling in 0248 applies.
--
-- The treasures rise with the realm: uncommon parts through the middle realms,
-- rare ones at the top, and the quantity climbs. A cultivator who has been
-- fighting will have them; one who has only sat still will have to go and
-- find out where they come from, which is the entire point.
--
-- Forward-only. Do not edit once applied.


CREATE TABLE realm_gates (
    rank          SMALLINT PRIMARY KEY CHECK (rank BETWEEN 2 AND 9),

    stones        BIGINT NOT NULL CHECK (stones >= 0),

    treasure_code TEXT REFERENCES materials (code) ON DELETE RESTRICT,
    treasure_qty  BIGINT NOT NULL DEFAULT 0 CHECK (treasure_qty >= 0),

    pill_kind     TEXT REFERENCES pill_kinds (code) ON DELETE RESTRICT,
    pill_tier     SMALLINT CHECK (pill_tier IS NULL OR pill_tier BETWEEN 1 AND 9),

    CONSTRAINT realm_gate_treasure_has_a_count CHECK (
        (treasure_code IS NULL) = (treasure_qty = 0)),
    CONSTRAINT realm_gate_pill_has_a_tier CHECK (
        (pill_kind IS NULL) = (pill_tier IS NULL))
);

COMMENT ON TABLE realm_gates IS
    'What entering a great realm asks for. Only rank crossings - the stages inside a realm stay free, because gating all thirty-five would make cultivation a shopping list.';

CREATE INDEX realm_gates_treasure_idx ON realm_gates (treasure_code);
CREATE INDEX realm_gates_pill_idx     ON realm_gates (pill_kind);


INSERT INTO realm_gates (rank, stones, treasure_code, treasure_qty, pill_kind, pill_tier) VALUES
    (2,      2000, 'beast_horn',       10, 'physique',    1),
    (3,     12000, 'snake_gall',       15, 'physique',    2),
    (4,     60000, 'thunder_horn',     20, 'cultivation', 3),
    (5,    260000, 'soul_crystal',     25, 'cultivation', 4),
    (6,   1100000, 'beast_core',       20, 'cultivation', 5),
    (7,   4500000, 'iron_bone',        25, 'cultivation', 6),
    (8,  18000000, 'heroic_soul',      30, 'cultivation', 7),
    (9,  72000000, 'tormented_soul',   35, 'cultivation', 7);


-- ---------------------------------------------------------------------------
-- What the door is asking for, and whether it is answered
-- ---------------------------------------------------------------------------

CREATE FUNCTION breakthrough_gate(p_player_id BIGINT)
RETURNS TABLE (
    need     TEXT,
    detail   TEXT,
    have     BIGINT,
    want     BIGINT,
    met      BOOLEAN
)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    cult    player_cultivation%ROWTYPE;
    was     realms%ROWTYPE;
    becomes realms%ROWTYPE;
    gate    realm_gates%ROWTYPE;
BEGIN
    SELECT * INTO cult FROM player_cultivation WHERE player_id = p_player_id;
    IF NOT FOUND THEN
        RETURN;
    END IF;

    SELECT * INTO was     FROM realms WHERE realm_id = cult.realm_id;
    SELECT * INTO becomes FROM realms WHERE realm_id = cult.realm_id + 1;

    IF becomes.realm_id IS NULL THEN
        RETURN;
    END IF;

    -- Cultivation is always the first thing asked for, at every crossing.
    RETURN QUERY SELECT
        'Cultivation'::text, becomes.name,
        cult.cultivation, becomes.cultivation_required,
        cult.cultivation >= becomes.cultivation_required;

    -- The rest only at a rank crossing.
    IF becomes.rank <= was.rank THEN
        RETURN;
    END IF;

    SELECT * INTO gate FROM realm_gates WHERE rank = becomes.rank;
    IF NOT FOUND THEN
        RETURN;
    END IF;

    IF gate.stones > 0 THEN
        RETURN QUERY SELECT
            'Spirit Stones'::text, NULL::text,
            COALESCE((SELECT pm.quantity FROM player_materials pm
                      WHERE pm.player_id = p_player_id
                        AND pm.material_code = 'spirit_stone'), 0),
            gate.stones,
            COALESCE((SELECT pm.quantity FROM player_materials pm
                      WHERE pm.player_id = p_player_id
                        AND pm.material_code = 'spirit_stone'), 0) >= gate.stones;
    END IF;

    IF gate.treasure_code IS NOT NULL THEN
        RETURN QUERY SELECT
            (SELECT m.name FROM materials m WHERE m.code = gate.treasure_code),
            'Heaven and Earth Treasure'::text,
            COALESCE((SELECT pm.quantity FROM player_materials pm
                      WHERE pm.player_id = p_player_id
                        AND pm.material_code = gate.treasure_code), 0),
            gate.treasure_qty,
            COALESCE((SELECT pm.quantity FROM player_materials pm
                      WHERE pm.player_id = p_player_id
                        AND pm.material_code = gate.treasure_code), 0)
                >= gate.treasure_qty;
    END IF;

    IF gate.pill_kind IS NOT NULL THEN
        RETURN QUERY SELECT
            (SELECT pk.name FROM pill_kinds pk WHERE pk.code = gate.pill_kind)
                || ' Pill',
            'tier ' || gate.pill_tier || ' or better',
            COALESCE((SELECT sum(pl.quantity) FROM player_pills pl
                      WHERE pl.owner_id = p_player_id
                        AND pl.kind = gate.pill_kind
                        AND pl.tier >= gate.pill_tier), 0),
            1::bigint,
            COALESCE((SELECT sum(pl.quantity) FROM player_pills pl
                      WHERE pl.owner_id = p_player_id
                        AND pl.kind = gate.pill_kind
                        AND pl.tier >= gate.pill_tier), 0) >= 1;
    END IF;
END;
$$;

COMMENT ON FUNCTION breakthrough_gate(BIGINT) IS
    'Everything the next crossing asks for and whether it has been answered. One place, so `breakthrough` and the screen that warns you cannot disagree about what you owe.';


-- ---------------------------------------------------------------------------
-- And the door reads it
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc WHERE proname = 'breakthrough';

    old := '    -- The tribulation goes here: a roll before this line, and an outcome
    -- column on the way out. Everything below is what surviving one is worth.';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'breakthrough no longer marks where the tribulation goes';
    END IF;

    src := replace(src, old,
'    -- What a great realm asks for beyond patience. `breakthrough_gate` is the
    -- only place that decides, so the screen that warns and the door that
    -- refuses cannot drift apart.
    IF becomes.rank > was.rank THEN
        SELECT g.need INTO short_of
        FROM breakthrough_gate(p_player_id) g
        WHERE NOT g.met AND g.need <> ''Cultivation''
        ORDER BY g.need LIMIT 1;

        IF short_of IS NOT NULL THEN
            RAISE EXCEPTION
                ''the door to % will not open - you are short of %'',
                becomes.name, short_of
                USING ERRCODE = ''check_violation'';
        END IF;

        SELECT * INTO gate FROM realm_gates WHERE rank = becomes.rank;

        IF gate.stones > 0 THEN
            PERFORM spend_material(p_player_id, ''spirit_stone'', gate.stones);
        END IF;
        IF gate.treasure_code IS NOT NULL THEN
            PERFORM spend_material(p_player_id, gate.treasure_code, gate.treasure_qty);
        END IF;
        IF gate.pill_kind IS NOT NULL THEN
            -- The weakest one that qualifies, so a hoard of good pills is not
            -- spent on a door a cheap one opens.
            UPDATE player_pills pl SET quantity = pl.quantity - 1
            WHERE pl.pill_id = (
                SELECT p2.pill_id FROM player_pills p2
                WHERE p2.owner_id = p_player_id AND p2.kind = gate.pill_kind
                  AND p2.tier >= gate.pill_tier AND p2.quantity > 0
                ORDER BY p2.tier, p2.magnitude LIMIT 1);
            DELETE FROM player_pills WHERE owner_id = p_player_id AND quantity <= 0;
        END IF;
    END IF;

    -- The tribulation goes here: a roll before this line, and an outcome
    -- column on the way out. Everything below is what surviving one is worth.');

    old := '    now_at    BIGINT;';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'breakthrough no longer declares its tally';
    END IF;
    src := replace(src, old,
'    now_at    BIGINT;
    short_of  TEXT;
    gate      realm_gates%ROWTYPE;');

    EXECUTE src;
END;
$$;


DO $$
DECLARE
    who   BIGINT;
    gate  realm_gates%ROWTYPE;
    said  TEXT;
    stood BOOLEAN := FALSE;
    rows  INTEGER;
BEGIN
    -- Somebody one step below a rank crossing.
    SELECT pc.player_id INTO who
    FROM player_cultivation pc
    JOIN realms r  ON r.realm_id = pc.realm_id
    JOIN realms nx ON nx.realm_id = pc.realm_id + 1 AND nx.rank > r.rank
    JOIN players p ON p.player_id = pc.player_id
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0
    LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'nobody stands at a rank door; the tests carry it';
        RETURN;
    END IF;

    BEGIN
        -- The gate says something, and cultivation is always among it.
        SELECT count(*) INTO rows FROM breakthrough_gate(who);
        IF rows < 2 THEN
            RAISE EXCEPTION 'a rank door asked for % things', rows;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM breakthrough_gate(who) g
                       WHERE g.need = 'Cultivation') THEN
            RAISE EXCEPTION 'the gate forgot to ask for cultivation';
        END IF;

        -- Standing at the door with nothing, it refuses by name.
        UPDATE player_cultivation pc SET cultivation = (
            SELECT nx.cultivation_required FROM realms nx
            WHERE nx.realm_id = pc.realm_id + 1)
        WHERE pc.player_id = who;

        DELETE FROM player_materials WHERE player_id = who
          AND material_code IN (SELECT treasure_code FROM realm_gates
                                WHERE treasure_code IS NOT NULL);

        BEGIN
            PERFORM breakthrough(who);
            RAISE EXCEPTION 'the door opened for somebody carrying nothing';
        EXCEPTION
            WHEN check_violation THEN
                GET STACKED DIAGNOSTICS said = MESSAGE_TEXT;
                IF said NOT LIKE '%will not open%' THEN
                    RAISE;
                END IF;
                stood := TRUE;
        END;

        IF NOT stood THEN
            RAISE EXCEPTION 'a rank crossing asked for nothing at all';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
