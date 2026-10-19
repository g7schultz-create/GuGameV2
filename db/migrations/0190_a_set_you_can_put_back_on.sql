-- 0190_a_set_you_can_put_back_on
--
-- Four things a cultivator wears, and every one of them is set one piece at a
-- time: Gu in the aperture, two manuals, four pieces of gear, and the
-- technique loadout. Somebody who farms with Gathering Yield and fights a
-- world beast with Attack Power currently rebuilds the whole set by hand
-- twice a session, across three different screens.
--
-- A preset is a named snapshot of all four, and putting it on again is one
-- press. Nothing about what may be equipped changes - `enforce_gu_capacity`
-- still refuses a Gu that will not fit, and it still fires per insert, which
-- is why a load empties the aperture before it fills it.
--
-- WHAT IS GONE IS SKIPPED, AND SAID. A preset is a list of specific items,
-- and between saving and loading one can be sold, traded, unbound, refined
-- away or eaten by a Gu feeding. The foreign keys cascade for the ones that
-- are deleted outright; a piece that merely changed hands is checked at load
-- and left out. Either way the load reports what it could not put on rather
-- than quietly dressing somebody in three quarters of a set.
--
-- Forward-only. Do not edit once applied.


CREATE TABLE loadout_presets (
    preset_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    player_id  BIGINT NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,
    name       TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT loadout_presets_name_length CHECK (
        length(btrim(name)) BETWEEN 1 AND 32
    )
);

CREATE INDEX loadout_presets_player_idx ON loadout_presets (player_id);

-- One "farming" a cultivator, whatever case they typed it in.
CREATE UNIQUE INDEX loadout_presets_one_name_each
    ON loadout_presets (player_id, lower(btrim(name)));

CREATE TRIGGER loadout_presets_set_updated_at
    BEFORE UPDATE ON loadout_presets
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


CREATE TABLE preset_gu (
    preset_id BIGINT NOT NULL REFERENCES loadout_presets (preset_id) ON DELETE CASCADE,
    gu_id     BIGINT NOT NULL REFERENCES player_gu (gu_id) ON DELETE CASCADE,
    PRIMARY KEY (preset_id, gu_id)
);
CREATE INDEX preset_gu_gu_idx ON preset_gu (gu_id);

CREATE TABLE preset_manuals (
    preset_id  BIGINT NOT NULL REFERENCES loadout_presets (preset_id) ON DELETE CASCADE,
    slot_index SMALLINT NOT NULL,
    manual_id  BIGINT NOT NULL REFERENCES manuals (manual_id) ON DELETE CASCADE,
    PRIMARY KEY (preset_id, slot_index)
);
CREATE INDEX preset_manuals_manual_idx ON preset_manuals (manual_id);

CREATE TABLE preset_gear (
    preset_id    BIGINT NOT NULL REFERENCES loadout_presets (preset_id) ON DELETE CASCADE,
    slot         TEXT NOT NULL REFERENCES equipment_slots (code) ON DELETE CASCADE,
    equipment_id BIGINT NOT NULL REFERENCES player_equipment (equipment_id) ON DELETE CASCADE,
    PRIMARY KEY (preset_id, slot)
);
CREATE INDEX preset_gear_equipment_idx ON preset_gear (equipment_id);
CREATE INDEX preset_gear_slot_idx ON preset_gear (slot);

CREATE TABLE preset_techniques (
    preset_id    BIGINT NOT NULL REFERENCES loadout_presets (preset_id) ON DELETE CASCADE,
    slot_index   SMALLINT NOT NULL,
    technique_id BIGINT NOT NULL REFERENCES techniques (technique_id) ON DELETE CASCADE,
    PRIMARY KEY (preset_id, slot_index)
);
CREATE INDEX preset_techniques_technique_idx ON preset_techniques (technique_id);


INSERT INTO game_config (key, value, description) VALUES
    ('loadout_preset_max', 6,
     'Named sets a cultivator may keep. Six is enough for farming, bossing, '
     'cultivating and a few experiments without the list becoming its own '
     'thing to manage.');


-- What the screen reads, and what `load_preset` checks itself against: how
-- much of each set is still in the cultivator's hands.
CREATE VIEW preset_shelf AS
SELECT s.preset_id,
       s.player_id,
       s.name,
       s.updated_at,
       (SELECT count(*) FROM preset_gu x WHERE x.preset_id = s.preset_id) AS gu_saved,
       (SELECT count(*) FROM preset_gu x
        JOIN player_gu g ON g.gu_id = x.gu_id
        WHERE x.preset_id = s.preset_id AND g.owner_id = s.player_id) AS gu_held,
       (SELECT count(*) FROM preset_manuals x WHERE x.preset_id = s.preset_id) AS manuals_saved,
       (SELECT count(*) FROM preset_manuals x
        JOIN player_manuals pm ON pm.manual_id = x.manual_id
        WHERE x.preset_id = s.preset_id AND pm.player_id = s.player_id) AS manuals_held,
       (SELECT count(*) FROM preset_gear x WHERE x.preset_id = s.preset_id) AS gear_saved,
       (SELECT count(*) FROM preset_gear x
        JOIN player_equipment pe ON pe.equipment_id = x.equipment_id
        WHERE x.preset_id = s.preset_id AND pe.owner_id = s.player_id) AS gear_held,
       (SELECT count(*) FROM preset_techniques x WHERE x.preset_id = s.preset_id) AS techniques_saved,
       (SELECT count(*) FROM preset_techniques x
        JOIN player_usable_techniques u ON u.technique_id = x.technique_id
        WHERE x.preset_id = s.preset_id AND u.player_id = s.player_id) AS techniques_held
FROM loadout_presets s;


CREATE FUNCTION save_preset(p_player_id BIGINT, p_name TEXT)
RETURNS TABLE (
    preset_id  BIGINT,
    name       TEXT,
    gu         INTEGER,
    manuals    INTEGER,
    gear       INTEGER,
    techniques INTEGER,
    replaced   BOOLEAN
)
LANGUAGE plpgsql
AS $$
DECLARE
    tidy TEXT := btrim(p_name);
    made BIGINT;
    over BOOLEAN := FALSE;
BEGIN
    IF length(tidy) < 1 THEN
        RAISE EXCEPTION 'a preset needs a name' USING ERRCODE = 'check_violation';
    END IF;
    IF length(tidy) > 32 THEN
        RAISE EXCEPTION 'that name is longer than 32 characters'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT s.preset_id INTO made FROM loadout_presets s
    WHERE s.player_id = p_player_id AND lower(btrim(s.name)) = lower(tidy);

    IF made IS NOT NULL THEN
        -- Saving over a name is how somebody keeps a set current, so it
        -- replaces rather than refusing - and says which it did.
        over := TRUE;
        DELETE FROM preset_gu WHERE preset_gu.preset_id = made;
        DELETE FROM preset_manuals WHERE preset_manuals.preset_id = made;
        DELETE FROM preset_gear WHERE preset_gear.preset_id = made;
        DELETE FROM preset_techniques WHERE preset_techniques.preset_id = made;
        UPDATE loadout_presets s SET name = tidy WHERE s.preset_id = made;
    ELSE
        IF (SELECT count(*) FROM loadout_presets s WHERE s.player_id = p_player_id)
           >= game_config_value('loadout_preset_max') THEN
            RAISE EXCEPTION 'you already keep % sets - overwrite one by name',
                game_config_value('loadout_preset_max')::integer
                USING ERRCODE = 'check_violation';
        END IF;

        INSERT INTO loadout_presets (player_id, name)
        VALUES (p_player_id, tidy)
        RETURNING loadout_presets.preset_id INTO made;
    END IF;

    INSERT INTO preset_gu (preset_id, gu_id)
    SELECT made, e.gu_id FROM player_gu_equipped e WHERE e.player_id = p_player_id;

    INSERT INTO preset_manuals (preset_id, slot_index, manual_id)
    SELECT made, m.slot_index, m.manual_id
    FROM player_manual_slots m WHERE m.player_id = p_player_id;

    INSERT INTO preset_gear (preset_id, slot, equipment_id)
    SELECT made, w.slot, w.equipment_id
    FROM player_equipped w WHERE w.player_id = p_player_id;

    INSERT INTO preset_techniques (preset_id, slot_index, technique_id)
    SELECT made, l.slot_index, l.technique_id
    FROM player_loadout l WHERE l.player_id = p_player_id;

    RETURN QUERY
    SELECT made, tidy,
           (SELECT count(*)::integer FROM preset_gu x WHERE x.preset_id = made),
           (SELECT count(*)::integer FROM preset_manuals x WHERE x.preset_id = made),
           (SELECT count(*)::integer FROM preset_gear x WHERE x.preset_id = made),
           (SELECT count(*)::integer FROM preset_techniques x WHERE x.preset_id = made),
           over;
END;
$$;


CREATE FUNCTION load_preset(p_player_id BIGINT, p_preset_id BIGINT)
RETURNS TABLE (
    name        TEXT,
    gu_worn     INTEGER,
    manuals_worn INTEGER,
    gear_worn   INTEGER,
    techniques_set INTEGER,
    missing     INTEGER,
    refused     TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    it     RECORD;
    one    RECORD;
    left_out TEXT[] := '{}';
    worn_g INTEGER := 0;
BEGIN
    SELECT * INTO it FROM preset_shelf s
    WHERE s.preset_id = p_preset_id AND s.player_id = p_player_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'that is not one of your sets'
            USING ERRCODE = 'check_violation';
    END IF;

    -- Emptied first, every time. The aperture is checked per Gu as it goes
    -- in, so a set that fits only once the old one is out would otherwise be
    -- refused halfway through.
    DELETE FROM player_gu_equipped WHERE player_id = p_player_id;
    DELETE FROM player_manual_slots WHERE player_id = p_player_id;
    DELETE FROM player_equipped WHERE player_id = p_player_id;
    DELETE FROM player_loadout WHERE player_id = p_player_id;

    FOR one IN
        SELECT x.gu_id, t.name FROM preset_gu x
        JOIN player_gu g ON g.gu_id = x.gu_id
        JOIN gu_types t ON t.gu_type_id = g.gu_type_id
        WHERE x.preset_id = p_preset_id AND g.owner_id = p_player_id
        ORDER BY t.size DESC, x.gu_id
    LOOP
        BEGIN
            INSERT INTO player_gu_equipped (player_id, gu_id)
            VALUES (p_player_id, one.gu_id);
            worn_g := worn_g + 1;
        EXCEPTION WHEN check_violation THEN
            -- The aperture shrank, or the Gu grew. Say which rather than
            -- failing the whole change of clothes.
            left_out := left_out || (one.name || ' will not fit the aperture');
        END;
    END LOOP;

    INSERT INTO player_manual_slots (player_id, slot_index, manual_id)
    SELECT p_player_id, x.slot_index, x.manual_id
    FROM preset_manuals x
    JOIN player_manuals pm
      ON pm.manual_id = x.manual_id AND pm.player_id = p_player_id
    JOIN manuals m ON m.manual_id = x.manual_id
    WHERE x.preset_id = p_preset_id
      AND m.required_rank <= COALESCE(
          (SELECT r.rank FROM player_cultivation pc
           JOIN realms r ON r.realm_id = pc.realm_id
           WHERE pc.player_id = p_player_id), 0);

    INSERT INTO player_equipped (player_id, slot, equipment_id)
    SELECT p_player_id, x.slot, x.equipment_id
    FROM preset_gear x
    JOIN player_equipment pe
      ON pe.equipment_id = x.equipment_id AND pe.owner_id = p_player_id
    WHERE x.preset_id = p_preset_id;

    INSERT INTO player_loadout (player_id, slot_index, technique_id)
    SELECT p_player_id, x.slot_index, x.technique_id
    FROM preset_techniques x
    WHERE x.preset_id = p_preset_id
      AND EXISTS (SELECT 1 FROM player_usable_techniques u
                  WHERE u.player_id = p_player_id
                    AND u.technique_id = x.technique_id);

    -- Bonuses are derived from what is worn, so the body has to be re-read.
    PERFORM apply_physique_xp(p_player_id, 0);

    RETURN QUERY
    SELECT it.name, worn_g,
           (SELECT count(*)::integer FROM player_manual_slots m
            WHERE m.player_id = p_player_id),
           (SELECT count(*)::integer FROM player_equipped w
            WHERE w.player_id = p_player_id),
           (SELECT count(*)::integer FROM player_loadout l
            WHERE l.player_id = p_player_id),
           ((it.gu_saved + it.manuals_saved + it.gear_saved + it.techniques_saved)
            - (worn_g
               + (SELECT count(*) FROM player_manual_slots m WHERE m.player_id = p_player_id)
               + (SELECT count(*) FROM player_equipped w WHERE w.player_id = p_player_id)
               + (SELECT count(*) FROM player_loadout l WHERE l.player_id = p_player_id))
           )::integer,
           array_to_string(left_out, ', ');
END;
$$;


CREATE FUNCTION delete_preset(p_player_id BIGINT, p_preset_id BIGINT)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    gone TEXT;
BEGIN
    DELETE FROM loadout_presets s
    WHERE s.preset_id = p_preset_id AND s.player_id = p_player_id
    RETURNING s.name INTO gone;

    IF gone IS NULL THEN
        RAISE EXCEPTION 'that is not one of your sets'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN gone;
END;
$$;


-- Saved, changed, and put back on again, on a live cultivator inside a
-- subtransaction that is thrown away. A preset that restores three quarters
-- of a set is worse than no preset at all.

DO $$
DECLARE
    who   BIGINT;
    made  BIGINT;
    back  RECORD;
    was_g INTEGER;
    was_w INTEGER;
BEGIN
    SELECT e.player_id INTO who FROM player_gu_equipped e
    GROUP BY e.player_id ORDER BY count(*) DESC LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'nobody has anything equipped; tests carry it';
        RETURN;
    END IF;

    BEGIN
        SELECT count(*) INTO was_g FROM player_gu_equipped WHERE player_id = who;
        SELECT count(*) INTO was_w FROM player_equipped WHERE player_id = who;

        SELECT s.preset_id INTO made FROM save_preset(who, 'probe set') s;

        DELETE FROM player_gu_equipped WHERE player_id = who;
        DELETE FROM player_equipped WHERE player_id = who;

        SELECT * INTO back FROM load_preset(who, made);

        IF back.gu_worn <> was_g THEN
            RAISE EXCEPTION 'saved % Gu and put back %', was_g, back.gu_worn;
        END IF;
        IF back.gear_worn <> was_w THEN
            RAISE EXCEPTION 'saved % pieces and put back %', was_w, back.gear_worn;
        END IF;
        IF back.missing <> 0 THEN
            RAISE EXCEPTION '% pieces went missing on a round trip', back.missing;
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
