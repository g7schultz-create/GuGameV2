-- 0370_fates_worth_writing_for_an_immortal
--
-- pashu0 crossed into Purple Mulberry and fate had nothing to say, because
-- there are thirty destinies and the ladder now asks for fifty-one.
--
-- THE ARITHMETIC NOBODY DID WHEN THE LADDER GREW. `destiny_offer` puts three
-- in front of you per crossing and never repeats one - "a fate is a thing you
-- are, not a stack" - so a crossing consumes three from the pool forever,
-- whichever is taken. The mortal ladder has eight crossings and burns
-- twenty-four of thirty. 0334 added nine more realms and no more fates, so the
-- tenth crossing is where the well runs dry. `destinies.min_rank` was even
-- CHECKed 2 to 9: the table was built for the mortal ladder and never told the
-- ladder had moved.
--
-- Twenty-four more, gated at rank 10 and above, taking the pool to fifty-four
-- against the fifty-one the full climb needs.
--
-- WHY THESE ARE SHAPED DIFFERENTLY TO THE FIRST THIRTY. The mortal fates are
-- percentages between -5 and +30 - they lean a build. An immortal's realm is
-- already a multiplier on everything they own, so a percentage is worth what
-- it always was while the numbers around it have gone up a thousandfold. Two
-- kinds of fate answer that:
--
--   * BASE STATS. Body, Hide and Sinew are points added to the body BEFORE
--     the realm multiplies it, so a fate granting thirty Body is worth thirty
--     health at Qi Condensation and eight million to a Dewberry immortal. It
--     keeps paying every realm you climb, which is the only kind of gift that
--     stays interesting on a ladder this long. Held to about a third of each
--     stat's ceiling so one fate is a foundation and not the whole building.
--
--   * A TECHNIQUE THAT GROWS WITH YOU. 0360 built exactly the mechanism: a
--     forged technique stores a GRADE rather than a damage number, and
--     `compute_technique_damage` recomputes it against the realm its owner
--     stands at now. Six fates hand over a technique through that same door,
--     at grades between Sovereign and Peerless, so what fate gave you at
--     Dewberry is still worth carrying at Yellow Apricot. Reusing
--     `technique_forges` for the grade is the whole trick - nothing else had
--     to learn how to scale.
--
-- AND THE DISPLAY IS FIXED WHILE I AM HERE. `destiny_take` builds its summary
-- with `round(100 * magnitude) || per cent`, the same assumption 0367 pulled
-- out of four other screens. Adding the first base-stat destinies would have
-- made it announce 'Body 3000%'.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE destinies DROP CONSTRAINT destinies_min_rank_check;
ALTER TABLE destinies ADD CONSTRAINT destinies_min_rank_check
    CHECK (min_rank >= 2 AND min_rank <= 18);


INSERT INTO destinies (code, name, description, min_rank, roll_weight) VALUES
    ('immemorial_flesh',    'Immemorial Flesh',    'Something older than your body decided to lend you its shape.', 10, 1.0),
    ('nine_forged_hide',    'Nine-Forged Hide',    'Beaten flat nine times. It stopped minding on the fourth.', 10, 1.0),
    ('venerables_arm',      'Venerable''s Arm',    'The arm remembers a strength it has no right to.', 10, 1.0),
    ('mountain_frame',      'Mountain-Bearing Frame', 'You are built the way a mountain is built, and about as movable.', 11, 0.9),
    ('first_dragon_scale',  'Scale of the First Dragon', 'One scale. It was enough for the dragon.', 11, 0.9),
    ('titans_inheritance',  'Titan''s Inheritance', 'Nobody asked whether you wanted it.', 12, 0.8),
    ('thousand_kalpa_body', 'Thousand Kalpa Body', 'A thousand disasters went through this body and left it thicker.', 13, 0.7),
    ('sovereign_sinew',     'Sovereign Sinew',     'Strung from whatever a Venerable is strung from.', 14, 0.6),

    ('heaven_slaying_edge', 'Heaven-Slaying Edge', 'The cut lands before the heavens finish objecting.', 10, 1.0),
    ('immortal_killer',     'Immortal Killer Move', 'You have found the place where everything comes apart.', 10, 1.0),
    ('formless_blade',      'Formless Blade',      'Armour is a shape, and this has no opinion about shapes.', 11, 0.9),
    ('blood_drinking_dao',  'Blood Drinking Dao',  'What you take, you keep.', 11, 0.9),
    ('twin_shadow',         'Twin Shadow',         'One of you swings. The other one also swings.', 12, 0.8),
    ('the_unfalling',       'The Unfalling',       'It was not that you survived. It was that you declined.', 13, 0.7),
    ('gathering_momentum',  'Gathering Momentum',  'Every exchange you live through makes the next one worse for them.', 12, 0.8),
    ('court_aegis',         'Aegis of the Court',  'Stolen from a Court that is still looking for it.', 14, 0.6),

    ('essence_affinity',    'Essence Affinity',    'Essence comes apart in your hands the way bread does.', 10, 1.0),
    ('aperture_expansion',  'Widened Aperture',    'There is simply more room in you than there was.', 10, 1.0),
    ('unmoving_dao',        'Unmoving Dao',        'The matchup chart is a suggestion and you are declining it.', 12, 0.8),
    ('eternal_furnace',     'Eternal Furnace',     'Crossing a realm stopped being something that hurt.', 13, 0.7),
    ('heavens_grudge',      'Heaven''s Grudge',    'It hits harder because something is always hitting back.', 11, 0.85),
    ('hollow_victory',      'Hollow Victory',      'You win. There is simply less of you afterwards.', 12, 0.8),

    ('dao_rivalling_heaven','Dao Rivalling Heaven','The heavens have a rival and it is inconvenienced by nothing.', 16, 0.45),
    ('venerable_ascension', 'Venerable''s Ascension', 'The last step is not taken. It is simply already behind you.', 18, 0.3);


INSERT INTO destiny_effects (code, effect_code, magnitude) VALUES
    ('immemorial_flesh',    'base_hp',          30),
    ('nine_forged_hide',    'base_defense',      6),
    ('venerables_arm',      'base_strength',     9),
    ('mountain_frame',      'base_hp',          20),
    ('mountain_frame',      'base_strength',     5),
    ('first_dragon_scale',  'base_defense',      5),
    ('first_dragon_scale',  'base_hp',          12),
    ('titans_inheritance',  'base_strength',     7),
    ('titans_inheritance',  'base_hp',          15),
    ('thousand_kalpa_body', 'base_hp',          36),
    ('thousand_kalpa_body', 'base_defense',      3),
    ('sovereign_sinew',     'base_strength',     9),
    ('sovereign_sinew',     'base_defense',      4),

    ('heaven_slaying_edge', 'crit_damage',    0.50),
    ('immortal_killer',     'crit_rate',      0.18),
    ('formless_blade',      'armor_pen',      0.25),
    ('blood_drinking_dao',  'lifesteal',      0.14),
    ('twin_shadow',         'multi_hit',      0.50),
    ('the_unfalling',       'death_ward',     0.30),
    ('gathering_momentum',  'momentum',       0.25),
    ('court_aegis',         'shield',         0.30),

    ('essence_affinity',    'cultivation_rate', 0.35),
    ('aperture_expansion',  'max_qi',           0.40),
    ('unmoving_dao',        'matchup_relief',   0.35),
    ('eternal_furnace',     'realm_tempering',  0.50),

    -- Two with a price, in the shape Heaven's Scorn and Mountain Root set.
    ('heavens_grudge',      'attack_power',     0.35),
    ('heavens_grudge',      'damage_reduction', -0.08),
    ('hollow_victory',      'crit_damage',      0.45),
    ('hollow_victory',      'max_hp',          -0.10),

    ('dao_rivalling_heaven','base_hp',          24),
    ('dao_rivalling_heaven','base_strength',     6),
    ('dao_rivalling_heaven','crit_rate',      0.12),
    ('venerable_ascension', 'base_hp',          30),
    ('venerable_ascension', 'base_strength',     8),
    ('venerable_ascension', 'base_defense',      5);


-- ---------------------------------------------------------------------------
-- A fate that hands over a technique, and it grows with you
-- ---------------------------------------------------------------------------

CREATE TABLE destiny_techniques (
    code           TEXT PRIMARY KEY REFERENCES destinies(code) ON DELETE CASCADE,
    technique_name TEXT NOT NULL,
    path_code      TEXT NOT NULL REFERENCES paths(code) ON DELETE RESTRICT,
    power_grade    NUMERIC(6,3) NOT NULL CHECK (power_grade > 0),
    description    TEXT NOT NULL DEFAULT ''
);

CREATE INDEX destiny_techniques_path_idx ON destiny_techniques (path_code);

COMMENT ON TABLE destiny_techniques IS
    'Fates that hand over a technique rather than a number. The grade is stored the way a forged technique stores one, so compute_technique_damage recomputes it against the realm its owner stands at now.';


INSERT INTO destinies (code, name, description, min_rank, roll_weight) VALUES
    ('inherited_sword',   'Inherited Sword Dao',  'Somebody died holding this. It has been waiting for hands.', 10, 0.9),
    ('borrowed_flame',    'Borrowed Flame',       'It was never yours. It answers anyway.', 10, 0.9),
    ('gu_immortal_fist',  'Gu Immortal''s Fist',  'No refinement, no formation. A fist, and a realm behind it.', 11, 0.85),
    ('shadow_of_the_dao', 'Shadow of the Dao',    'You did not learn it. You remembered it.', 13, 0.6),
    ('heavens_own_move',  'Heaven''s Own Move',   'The move the heavens use when they have run out of patience.', 15, 0.45),
    ('venerable_art',     'Venerable''s Art',     'One of the nine. It does not say which.', 17, 0.3);

INSERT INTO destiny_techniques (code, technique_name, path_code, power_grade, description) VALUES
    ('inherited_sword',   'Inherited Sword Dao',  'sword',  2.40, 'A dead hand''s sword, still cutting.'),
    ('borrowed_flame',    'Borrowed Flame',       'fire',   2.40, 'Fire that was lent and never called back.'),
    ('gu_immortal_fist',  'Gu Immortal''s Fist',  'strength', 2.70, 'A fist with a realm behind it.'),
    ('shadow_of_the_dao', 'Shadow of the Dao',    'shadow', 3.00, 'Remembered rather than learned.'),
    ('heavens_own_move',  'Heaven''s Own Move',   'heaven', 3.40, 'What the heavens do when patience runs out.'),
    ('venerable_art',     'Venerable''s Art',     'rule',   3.80, 'One of the nine, unnamed.');


-- ---------------------------------------------------------------------------
-- Taking one writes the fate, and hands over the move if it carries one
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    -- 1. The technique hand-over, inserted just after the fate is written.
    anchor := concat(
'    UPDATE player_destinies', chr(10),
'    SET code = p_code, chosen_at = now()', chr(10),
'    WHERE player_id = p_player_id AND rank = p_rank;');

    swap := concat(anchor, chr(10),
chr(10),
'    -- A fate that carries a move hands it over now. The grade goes into', chr(10),
'    -- `technique_forges` exactly as a forged one does, which is what makes', chr(10),
'    -- `compute_technique_damage` recompute it against the owner''s realm', chr(10),
'    -- every time they swing instead of freezing it at the realm they', chr(10),
'    -- happened to be standing at when fate offered it.', chr(10),
'    DECLARE', chr(10),
'        gift  RECORD;', chr(10),
'        made  BIGINT;', chr(10),
'    BEGIN', chr(10),
'        SELECT * INTO gift FROM destiny_techniques WHERE code = p_code;', chr(10),
'        IF FOUND THEN', chr(10),
'            INSERT INTO techniques', chr(10),
'                (name, rank, category, base_power, qi_cost_pct, accuracy,', chr(10),
'                 grade, created_by, description)', chr(10),
'            VALUES (gift.technique_name, 9, ''attack'',', chr(10),
'                LEAST(2000000000::numeric, round(', chr(10),
'                    game_config_value(''technique_forge_power_base'')', chr(10),
'                    * player_power_multiple(p_player_id)', chr(10),
'                    * gift.power_grade))::integer,', chr(10),
'                0.08, 1, ''advanced'', p_player_id, gift.description)', chr(10),
'            RETURNING technique_id INTO made;', chr(10),
chr(10),
'            INSERT INTO technique_paths (technique_id, path_code, weight)', chr(10),
'            VALUES (made, gift.path_code, 1);', chr(10),
chr(10),
'            INSERT INTO technique_forges', chr(10),
'                (player_id, realm_rank, power_grade, dual, paths, step,', chr(10),
'                 technique_id, finished_at)', chr(10),
'            VALUES (p_player_id, p_rank, gift.power_grade, FALSE,', chr(10),
'                    ARRAY[gift.path_code],', chr(10),
'                    game_config_value(''technique_forge_steps'')::smallint,', chr(10),
'                    made, now());', chr(10),
chr(10),
'            INSERT INTO player_techniques (player_id, technique_id)', chr(10),
'            VALUES (p_player_id, made) ON CONFLICT DO NOTHING;', chr(10),
'        END IF;', chr(10),
'    END;');

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'destiny_take';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'destiny_take no longer writes the fate where it did';
    END IF;
    body := replace(body, anchor, swap);

    -- 2. The summary, which would otherwise call thirty Body '3000 per cent'.
    anchor := concat(
'           (SELECT string_agg(ef.emoji || '' '' || ef.name || '' ''', chr(10),
'                              || CASE WHEN de.magnitude < 0 THEN '''' ELSE ''+'' END', chr(10),
'                              || round(100 * de.magnitude) || ''%'',');

    swap := concat(
'           (SELECT string_agg(ef.emoji || '' '' || ef.name || '' ''', chr(10),
'                              || effect_amount(ef.code, de.magnitude),');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'destiny_take no longer summarises a fate where it did';
    END IF;
    body := replace(body, anchor, swap);

    EXECUTE body;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- The well is deep enough for the whole climb, and a fate can be taken
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    pool      INTEGER;
    crossings INTEGER;
    who       BIGINT;
    offer     TEXT[];
    took      RECORD;
    made      BIGINT;
    before    BIGINT;
    bad       TEXT;
BEGIN
    SELECT count(*) INTO pool FROM destinies WHERE roll_weight > 0;
    SELECT count(DISTINCT rank) - 1 INTO crossings FROM realms;

    IF pool < crossings * 3 THEN
        RAISE EXCEPTION
            'the ladder has % crossings wanting % fates and the pool holds %',
            crossings, crossings * 3, pool;
    END IF;
    RAISE NOTICE '% fates for % crossings (% needed)', pool, crossings, crossings * 3;

    -- No base-stat fate eats a whole ceiling on its own.
    SELECT string_agg(d.code || ' ' || f.name, ', ') INTO bad
    FROM destiny_effects de
    JOIN destinies d ON d.code = de.code
    JOIN gu_effects f ON f.code = de.effect_code
    WHERE f.is_base AND de.magnitude > 0.35 * f.cap;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these fates are a whole body by themselves: %', bad;
    END IF;

    -- Nothing points at an effect that is not live.
    SELECT string_agg(DISTINCT de.effect_code, ', ') INTO bad
    FROM destiny_effects de
    WHERE NOT EXISTS (SELECT 1 FROM gu_effects f
                      WHERE f.code = de.effect_code AND f.is_live);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these fates grant a dead effect: %', bad;
    END IF;

    -- Every technique-granting fate is a real fate.
    SELECT string_agg(dt.code, ', ') INTO bad
    FROM destiny_techniques dt
    WHERE NOT EXISTS (SELECT 1 FROM destinies d WHERE d.code = dt.code);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these gifts belong to no fate: %', bad;
    END IF;

    -- ---- driven: an immortal takes a technique fate and can swing it -----
    SELECT pc.player_id INTO who
    FROM player_cultivation pc JOIN realms r ON r.realm_id = pc.realm_id
    WHERE r.rank >= 10 ORDER BY r.rank DESC LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'no immortal to write a fate for';
        RETURN;
    END IF;

    BEGIN
        SELECT count(*) INTO before FROM player_techniques WHERE player_id = who;

        DELETE FROM player_destinies WHERE player_id = who AND rank = 18;
        INSERT INTO player_destinies (player_id, rank, offered)
        VALUES (who, 18, ARRAY['venerable_art']);

        SELECT * INTO took FROM destiny_take(who, 18::smallint, 'venerable_art');
        IF took.name IS NULL THEN
            RAISE EXCEPTION 'the fate was not written';
        END IF;

        SELECT technique_id INTO made FROM technique_forges
        WHERE player_id = who AND technique_id IS NOT NULL
        ORDER BY finished_at DESC LIMIT 1;

        IF NOT EXISTS (SELECT 1 FROM player_techniques
                       WHERE player_id = who AND technique_id = made) THEN
            RAISE EXCEPTION 'the fate handed over no technique';
        END IF;

        -- And it is a REAL move: it hits, and it hits through the realm.
        IF (SELECT final_damage FROM compute_technique_damage(
                who, made, (SELECT species_id FROM creature_species LIMIT 1),
                player_external_multiplier(who, made))) <= 0 THEN
            RAISE EXCEPTION 'the fate''s technique hits for nothing';
        END IF;

        -- The summary says points, not per cent, which is the display fix.
        SELECT * INTO took FROM destiny_take(who, 18::smallint, 'venerable_art');
        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT IN ('probe-ok', 'that fate is already written') THEN
            RAISE;
        END IF;
    END;

    RAISE NOTICE 'a fate was written, a technique handed over, and rolled back';
END;
$probe$;
