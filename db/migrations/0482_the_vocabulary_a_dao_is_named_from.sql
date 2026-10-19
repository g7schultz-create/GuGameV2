-- 0482_the_vocabulary_a_dao_is_named_from
--
-- Phase 2 of the Venerable spec, first half: the words. Nothing reads these
-- yet and no player can see anything - the derivation that uses them comes
-- next, behind an owner-only command until the whole realm is finished.
--
-- A Dao is named by rule from the aspects a cultivator's history produced, and
-- the game already names things this way: `path_words` and `technique_words`
-- are what the forge titles a technique from. They are the right machinery and
-- far too thin for this.
--
--     path_words          102 across 34 paths - three each
--     technique_words      15 prefixes, 15 endings
--
-- Three words per path gives a two-path Dao nine noun pairs to work with. The
-- seven cultivators at the ceiling would collide almost at once, and the name
-- would read as a template rather than as a title.
--
-- SO: SIX ADJECTIVES AND SIX NOUNS PER PATH, 408 words, in the register the
-- existing hundred set. That register is specific and worth naming so it
-- survives the next person who adds to it: Nine Palace, Ten Thousand Folk,
-- Inch of Time, Myriad Mortal, Vajra. Slightly archaic, Chinese-inflected,
-- concrete rather than abstract. Not a fantasy noun salad.
--
-- The existing words are kept and sorted into their part of speech, because
-- they are the register and throwing them away would lose it.
--
-- WHY A PART OF SPEECH. A template that reads "The Dao of the {adjective}
-- {noun}" cannot draw both from one undifferentiated pile without producing
-- "The Dao of the Marrow Bone". The role is what lets the shapes be written
-- once and applied to all thirty-four.
--
-- BODY AND CRAFT get smaller sets. They modify rather than lead - a Dao is
-- named for the paths walked and coloured by the body forged and the craft
-- levelled, so these want fewer and sharper words rather than six each.
--
-- ROOTS ARE LEFT FOR LATER. Forty-five of them, held unevenly, and they are
-- the weakest of the five axes for naming. The schema admits them; the words
-- are a separate sitting.
--
-- Forward-only. Do not edit once applied.


CREATE TABLE dao_words (
    source_kind TEXT NOT NULL,
    source_code TEXT NOT NULL,
    word        TEXT NOT NULL,
    role        TEXT NOT NULL,
    PRIMARY KEY (source_kind, source_code, word, role),
    CHECK (source_kind IN ('path', 'body', 'craft', 'root')),
    CHECK (role IN ('adjective', 'noun'))
);

CREATE INDEX dao_words_lookup_idx ON dao_words (source_kind, source_code, role);

COMMENT ON TABLE dao_words IS
    'The vocabulary a Dao name is composed from, keyed by what part of a cultivator produced it. One table for every axis rather than one per axis, because the templates draw from all of them the same way.';

COMMENT ON COLUMN dao_words.role IS
    'Part of speech. A template reading "the {adjective} {noun}" cannot draw both from one pile without producing "the Marrow Bone".';


-- ---------------------------------------------------------------------------
-- The thirty-four paths
-- ---------------------------------------------------------------------------

INSERT INTO dao_words (source_kind, source_code, word, role) VALUES
-- blood
('path','blood','Crimson','adjective'),('path','blood','Sanguine','adjective'),
('path','blood','Bloodletting','adjective'),('path','blood','Vein-Drawn','adjective'),
('path','blood','Scarlet-Fed','adjective'),('path','blood','Exsanguine','adjective'),
('path','blood','Blood','noun'),('path','blood','Red Vein','noun'),
('path','blood','Sanguine Tide','noun'),('path','blood','Lifeblood','noun'),
('path','blood','Crimson Flow','noun'),('path','blood','Heartsblood','noun'),
-- bone
('path','bone','Ossuary','adjective'),('path','bone','Marrow-Deep','adjective'),
('path','bone','Boneset','adjective'),('path','bone','Calcified','adjective'),
('path','bone','Grave-Wrought','adjective'),('path','bone','White-Boned','adjective'),
('path','bone','Bone','noun'),('path','bone','Marrow','noun'),
('path','bone','Ossuary','noun'),('path','bone','Reliquary','noun'),
('path','bone','Bonefield','noun'),('path','bone','Skeleton','noun'),
-- dream
('path','dream','Dreaming','adjective'),('path','dream','Night-Wandering','adjective'),
('path','dream','Slumbering','adjective'),('path','dream','Sleepbound','adjective'),
('path','dream','Reverie-Held','adjective'),('path','dream','Unwaking','adjective'),
('path','dream','Dream','noun'),('path','dream','Slumber','noun'),
('path','dream','Night-Wandering','noun'),('path','dream','Reverie','noun'),
('path','dream','Sleep','noun'),('path','dream','Vision','noun'),
-- earth
('path','earth','Deep-Loamed','adjective'),('path','earth','Mountainous','adjective'),
('path','earth','Stonebound','adjective'),('path','earth','Unmoving','adjective'),
('path','earth','Root-Deep','adjective'),('path','earth','Earthen','adjective'),
('path','earth','Mountain','noun'),('path','earth','Deep Loam','noun'),
('path','earth','Stone','noun'),('path','earth','Bedrock','noun'),
('path','earth','Earth','noun'),('path','earth','Foundation','noun'),
-- enslavement
('path','enslavement','Binding','adjective'),('path','enslavement','Yoked','adjective'),
('path','enslavement','Sovereign','adjective'),('path','enslavement','Thralled','adjective'),
('path','enslavement','Collared','adjective'),('path','enslavement','Subjugating','adjective'),
('path','enslavement','Chain','noun'),('path','enslavement','Yoke','noun'),
('path','enslavement','Thrall','noun'),('path','enslavement','Dominion','noun'),
('path','enslavement','Leash','noun'),('path','enslavement','Sovereign','noun'),
-- fire
('path','fire','Blazing','adjective'),('path','fire','Ember-Lit','adjective'),
('path','fire','Scarlet','adjective'),('path','fire','Kindling','adjective'),
('path','fire','Ashen','adjective'),('path','fire','Conflagrant','adjective'),
('path','fire','Flame','noun'),('path','fire','Ember','noun'),
('path','fire','Pyre','noun'),('path','fire','Conflagration','noun'),
('path','fire','Cinder','noun'),('path','fire','Blaze','noun'),
-- food
('path','food','Nourishing','adjective'),('path','food','Ripe','adjective'),
('path','food','Sated','adjective'),('path','food','Famished','adjective'),
('path','food','Harvest-Fed','adjective'),('path','food','Devouring','adjective'),
('path','food','Harvest','noun'),('path','food','Feast','noun'),
('path','food','Hunger','noun'),('path','food','Ripeness','noun'),
('path','food','Table','noun'),('path','food','Sustenance','noun'),
-- formation
('path','formation','Nine-Palace','adjective'),('path','formation','Ninefold','adjective'),
('path','formation','Warded','adjective'),('path','formation','Arrayed','adjective'),
('path','formation','Lattice-Bound','adjective'),('path','formation','Sealed','adjective'),
('path','formation','Array','noun'),('path','formation','Nine Palace','noun'),
('path','formation','Ward','noun'),('path','formation','Lattice','noun'),
('path','formation','Formation','noun'),('path','formation','Seal','noun'),
-- heaven
('path','heaven','Celestial','adjective'),('path','heaven','Fated','adjective'),
('path','heaven','Heavenly','adjective'),('path','heaven','Heaven-Defying','adjective'),
('path','heaven','Decreed','adjective'),('path','heaven','Empyrean','adjective'),
('path','heaven','Heaven','noun'),('path','heaven','Mandate','noun'),
('path','heaven','Firmament','noun'),('path','heaven','Decree','noun'),
('path','heaven','Celestial Vault','noun'),('path','heaven','Fate','noun'),
-- human
('path','human','Common','adjective'),('path','human','Myriad','adjective'),
('path','human','Ten-Thousand-Folk','adjective'),('path','human','Mortal','adjective'),
('path','human','Thronging','adjective'),('path','human','Manifold','adjective'),
('path','human','Myriad Folk','noun'),('path','human','Mortal','noun'),
('path','human','Multitude','noun'),('path','human','Ten Thousand','noun'),
('path','human','Common Lot','noun'),('path','human','Humanity','noun'),
-- ice
('path','ice','Frost-Rimed','adjective'),('path','ice','Glacial','adjective'),
('path','ice','Rime-Bound','adjective'),('path','ice','Hoarfrost','adjective'),
('path','ice','Frozen','adjective'),('path','ice','Winterbound','adjective'),
('path','ice','Frost','noun'),('path','ice','Glacier','noun'),
('path','ice','Rime','noun'),('path','ice','Winter','noun'),
('path','ice','Ice','noun'),('path','ice','Hoar','noun'),
-- illusion
('path','illusion','Deceiving','adjective'),('path','illusion','Mirage-Woven','adjective'),
('path','illusion','Phantom','adjective'),('path','illusion','Unreal','adjective'),
('path','illusion','Veil-Drawn','adjective'),('path','illusion','Beguiling','adjective'),
('path','illusion','Mirage','noun'),('path','illusion','Phantom','noun'),
('path','illusion','Veil','noun'),('path','illusion','Deception','noun'),
('path','illusion','Illusion','noun'),('path','illusion','Semblance','noun'),
-- light
('path','light','Brilliant','adjective'),('path','light','Radiant','adjective'),
('path','light','Solar','adjective'),('path','light','Luminous','adjective'),
('path','light','Dawn-Struck','adjective'),('path','light','Blinding','adjective'),
('path','light','Radiance','noun'),('path','light','Dawn','noun'),
('path','light','Brilliance','noun'),('path','light','Light','noun'),
('path','light','Sun','noun'),('path','light','Lumen','noun'),
-- lightning
('path','lightning','Levin-Struck','adjective'),('path','lightning','Storming','adjective'),
('path','lightning','Thunderous','adjective'),('path','lightning','Arcing','adjective'),
('path','lightning','Sky-Split','adjective'),('path','lightning','Galvanic','adjective'),
('path','lightning','Thunder','noun'),('path','lightning','Levin','noun'),
('path','lightning','Storm','noun'),('path','lightning','Lightning','noun'),
('path','lightning','Skybolt','noun'),('path','lightning','Tempest','noun'),
-- luck
('path','luck','Auspicious','adjective'),('path','luck','Fortunate','adjective'),
('path','luck','Golden','adjective'),('path','luck','Chance-Favoured','adjective'),
('path','luck','Blessed','adjective'),('path','luck','Serendipitous','adjective'),
('path','luck','Fortune','noun'),('path','luck','Golden Chance','noun'),
('path','luck','Omen','noun'),('path','luck','Luck','noun'),
('path','luck','Auspice','noun'),('path','luck','Providence','noun'),
-- metal
('path','metal','Gilded','adjective'),('path','metal','Iron','adjective'),
('path','metal','Keen','adjective'),('path','metal','Tempered','adjective'),
('path','metal','Edged','adjective'),('path','metal','Argent','adjective'),
('path','metal','Iron','noun'),('path','metal','Aurum','noun'),
('path','metal','Edge','noun'),('path','metal','Metal','noun'),
('path','metal','Alloy','noun'),('path','metal','Keen Steel','noun'),
-- painting
('path','painting','Ink-Drawn','adjective'),('path','painting','Painted','adjective'),
('path','painting','Rendered','adjective'),('path','painting','Brush-Struck','adjective'),
('path','painting','Scroll-Borne','adjective'),('path','painting','Limned','adjective'),
('path','painting','Ink','noun'),('path','painting','Brush','noun'),
('path','painting','Scroll','noun'),('path','painting','Painting','noun'),
('path','painting','Rendering','noun'),('path','painting','Stroke','noun'),
-- poison
('path','poison','Blighted','adjective'),('path','poison','Miasmic','adjective'),
('path','poison','Venomous','adjective'),('path','poison','Festering','adjective'),
('path','poison','Tainted','adjective'),('path','poison','Corrosive','adjective'),
('path','poison','Venom','noun'),('path','poison','Miasma','noun'),
('path','poison','Blight','noun'),('path','poison','Poison','noun'),
('path','poison','Rot','noun'),('path','poison','Contagion','noun'),
-- qi
('path','qi','Breathing','adjective'),('path','qi','Coiled','adjective'),
('path','qi','Primeval','adjective'),('path','qi','Circulating','adjective'),
('path','qi','Unbroken','adjective'),('path','qi','Welling','adjective'),
('path','qi','Breath','noun'),('path','qi','Coiled Breath','noun'),
('path','qi','Qi','noun'),('path','qi','Primeval Air','noun'),
('path','qi','Circulation','noun'),('path','qi','Vitality','noun'),
-- refinement
('path','refinement','Purified','adjective'),('path','refinement','Refined','adjective'),
('path','refinement','Tempered','adjective'),('path','refinement','Distilled','adjective'),
('path','refinement','Crucible-Born','adjective'),('path','refinement','Clarified','adjective'),
('path','refinement','Crucible','noun'),('path','refinement','Refinement','noun'),
('path','refinement','Purity','noun'),('path','refinement','Furnace','noun'),
('path','refinement','Distillate','noun'),('path','refinement','Temper','noun'),
-- rule
('path','rule','Decreed','adjective'),('path','rule','Lawful','adjective'),
('path','rule','Writ','adjective'),('path','rule','Ordaining','adjective'),
('path','rule','Statute-Bound','adjective'),('path','rule','Governing','adjective'),
('path','rule','Law','noun'),('path','rule','Decree','noun'),
('path','rule','Writ','noun'),('path','rule','Ordinance','noun'),
('path','rule','Rule','noun'),('path','rule','Precept','noun'),
-- shadow
('path','shadow','Nightfallen','adjective'),('path','shadow','Umbral','adjective'),
('path','shadow','Shadowed','adjective'),('path','shadow','Unseen','adjective'),
('path','shadow','Dark-Clad','adjective'),('path','shadow','Eclipsing','adjective'),
('path','shadow','Shadow','noun'),('path','shadow','Nightfall','noun'),
('path','shadow','Umbra','noun'),('path','shadow','Eclipse','noun'),
('path','shadow','Gloom','noun'),('path','shadow','Silhouette','noun'),
-- soul
('path','soul','Ghostly','adjective'),('path','soul','Hollow','adjective'),
('path','soul','Spirit-Bound','adjective'),('path','soul','Soulbare','adjective'),
('path','soul','Wraithlike','adjective'),('path','soul','Disembodied','adjective'),
('path','soul','Soul','noun'),('path','soul','Spirit','noun'),
('path','soul','Ghost','noun'),('path','soul','Hollow','noun'),
('path','soul','Shade','noun'),('path','soul','Anima','noun'),
-- space
('path','space','Distant','adjective'),('path','space','Folded','adjective'),
('path','space','Void-Touched','adjective'),('path','space','Far-Reaching','adjective'),
('path','space','Unbounded','adjective'),('path','space','Displaced','adjective'),
('path','space','Void','noun'),('path','space','Distance','noun'),
('path','space','Fold','noun'),('path','space','Expanse','noun'),
('path','space','Space','noun'),('path','space','Reach','noun'),
-- star
('path','star','Astral','adjective'),('path','star','Constellate','adjective'),
('path','star','Starfallen','adjective'),('path','star','Night-Lit','adjective'),
('path','star','Sidereal','adjective'),('path','star','Far-Burning','adjective'),
('path','star','Star','noun'),('path','star','Constellation','noun'),
('path','star','Starfall','noun'),('path','star','Firmament','noun'),
('path','star','Astral Wheel','noun'),('path','star','Nightsky','noun'),
-- strength
('path','strength','Titanic','adjective'),('path','strength','Tyrannical','adjective'),
('path','strength','Vajra','adjective'),('path','strength','Unyielding','adjective'),
('path','strength','Mountain-Framed','adjective'),('path','strength','Overbearing','adjective'),
('path','strength','Titan','noun'),('path','strength','Tyrant','noun'),
('path','strength','Vajra','noun'),('path','strength','Might','noun'),
('path','strength','Sinew','noun'),('path','strength','Colossus','noun'),
-- sword
('path','sword','Severing','adjective'),('path','sword','Edged','adjective'),
('path','sword','Sword-Borne','adjective'),('path','sword','Unsheathed','adjective'),
('path','sword','Cleaving','adjective'),('path','sword','Keen','adjective'),
('path','sword','Sword','noun'),('path','sword','Edge','noun'),
('path','sword','Severance','noun'),('path','sword','Blade','noun'),
('path','sword','Cut','noun'),('path','sword','Scabbard','noun'),
-- theft
('path','theft','Light-Fingered','adjective'),('path','theft','Plundering','adjective'),
('path','theft','Thieving','adjective'),('path','theft','Pilfering','adjective'),
('path','theft','Unseen-Handed','adjective'),('path','theft','Rapacious','adjective'),
('path','theft','Theft','noun'),('path','theft','Plunder','noun'),
('path','theft','Pilferage','noun'),('path','theft','Spoil','noun'),
('path','theft','Larceny','noun'),('path','theft','Taking','noun'),
-- time
('path','time','Aeonic','adjective'),('path','time','Waning','adjective'),
('path','time','Inch-Measured','adjective'),('path','time','Everlasting','adjective'),
('path','time','Hourless','adjective'),('path','time','Time-Worn','adjective'),
('path','time','Aeon','noun'),('path','time','Hour','noun'),
('path','time','Inch of Time','noun'),('path','time','Epoch','noun'),
('path','time','Moment','noun'),('path','time','Duration','noun'),
-- transformation
('path','transformation','Becoming','adjective'),('path','transformation','Manifold','adjective'),
('path','transformation','Shifting','adjective'),('path','transformation','Protean','adjective'),
('path','transformation','Unfixed','adjective'),('path','transformation','Metamorphic','adjective'),
('path','transformation','Becoming','noun'),('path','transformation','Transformation','noun'),
('path','transformation','Shift','noun'),('path','transformation','Guise','noun'),
('path','transformation','Metamorphosis','noun'),('path','transformation','Change','noun'),
-- water
('path','water','Azure','adjective'),('path','water','Flowing','adjective'),
('path','water','Tidal','adjective'),('path','water','Deep-Running','adjective'),
('path','water','Unstill','adjective'),('path','water','Drowning','adjective'),
('path','water','Tide','noun'),('path','water','Flow','noun'),
('path','water','Water','noun'),('path','water','Depths','noun'),
('path','water','Current','noun'),('path','water','Azure Sea','noun'),
-- wind
('path','wind','Gale-Borne','adjective'),('path','wind','Swiftwind','adjective'),
('path','wind','Tempestuous','adjective'),('path','wind','Unresting','adjective'),
('path','wind','Whirling','adjective'),('path','wind','Keening','adjective'),
('path','wind','Gale','noun'),('path','wind','Wind','noun'),
('path','wind','Tempest','noun'),('path','wind','Zephyr','noun'),
('path','wind','Whirl','noun'),('path','wind','Breath of Sky','noun'),
-- wisdom
('path','wisdom','Clear-Insighted','adjective'),('path','wisdom','Sage','adjective'),
('path','wisdom','Thousand-Thought','adjective'),('path','wisdom','Discerning','adjective'),
('path','wisdom','Lucid','adjective'),('path','wisdom','Far-Seeing','adjective'),
('path','wisdom','Insight','noun'),('path','wisdom','Sage','noun'),
('path','wisdom','Thousand Thoughts','noun'),('path','wisdom','Wisdom','noun'),
('path','wisdom','Clarity','noun'),('path','wisdom','Understanding','noun'),
-- wood
('path','wood','Green-Boughed','adjective'),('path','wood','Jade','adjective'),
('path','wood','Verdant','adjective'),('path','wood','Flourishing','adjective'),
('path','wood','Root-Fast','adjective'),('path','wood','Evergreen','adjective'),
('path','wood','Green Bough','noun'),('path','wood','Jade','noun'),
('path','wood','Verdure','noun'),('path','wood','Grove','noun'),
('path','wood','Root','noun'),('path','wood','Bloom','noun');


-- ---------------------------------------------------------------------------
-- The three bodies and the six crafts
-- ---------------------------------------------------------------------------

INSERT INTO dao_words (source_kind, source_code, word, role) VALUES
('body','taoist','Balanced','adjective'),('body','taoist','Harmonious','adjective'),
('body','taoist','Still-Centred','adjective'),('body','taoist','Harmony','noun'),
('body','taoist','Stillness','noun'),('body','taoist','Balance','noun'),

('body','demonic','Devouring','adjective'),('body','demonic','Unbridled','adjective'),
('body','demonic','Demon-Hearted','adjective'),('body','demonic','Appetite','noun'),
('body','demonic','Demon Heart','noun'),('body','demonic','Ruin','noun'),

('body','buddhist','Enduring','adjective'),('body','buddhist','Immovable','adjective'),
('body','buddhist','Forbearing','adjective'),('body','buddhist','Forbearance','noun'),
('body','buddhist','Endurance','noun'),('body','buddhist','Stone Bell','noun'),

('craft','alchemy','Cauldron-Tending','adjective'),('craft','alchemy','Distilling','adjective'),
('craft','alchemy','Cauldron','noun'),('craft','alchemy','Elixir','noun'),

('craft','blacksmithing','Hammer-Handed','adjective'),('craft','blacksmithing','Forge-Lit','adjective'),
('craft','blacksmithing','Anvil','noun'),('craft','blacksmithing','Forge','noun'),

('craft','exploring','Far-Walking','adjective'),('craft','exploring','Untracked','adjective'),
('craft','exploring','Long Road','noun'),('craft','exploring','Wanderer','noun'),

('craft','foraging','Leaf-Gathering','adjective'),('craft','foraging','Patient','adjective'),
('craft','foraging','Gleaning','noun'),('craft','foraging','Harvester','noun'),

('craft','gu_refining','Worm-Wrought','adjective'),('craft','gu_refining','Refining','adjective'),
('craft','gu_refining','Refiner','noun'),('craft','gu_refining','Worm-Craft','noun'),

('craft','mining','Deep-Delving','adjective'),('craft','mining','Stone-Breaking','adjective'),
('craft','mining','Delver','noun'),('craft','mining','Deep Seam','noun');


-- ---------------------------------------------------------------------------
-- The shapes a name can take
-- ---------------------------------------------------------------------------

CREATE TABLE dao_templates (
    code   TEXT PRIMARY KEY,
    shape  TEXT NOT NULL,
    weight NUMERIC(5,2) NOT NULL DEFAULT 1,
    CHECK (weight > 0)
);

COMMENT ON TABLE dao_templates IS
    'How a name is assembled. Placeholders: adj1 noun1 from the dominant path, adj2 noun2 from the second, body and craft from those axes. Several shapes so one pair of paths does not always read the same way.';

INSERT INTO dao_templates (code, shape, weight) VALUES
    ('of_the',      'The Dao of the {adj2} {noun1}',            1.40),
    ('and',         'The Dao of {noun1} and {noun2}',           1.20),
    ('sovereign',   '{noun1} of the {adj2} {noun2}',            1.00),
    ('twofold',     'The {adj1} {adj2} Dao',                    0.80),
    ('bodied',      'The {body_adj} Dao of the {adj1} {noun2}', 0.70),
    ('crafted',     'The {craft_noun} of the {adj1} {noun1}',   0.50);


-- ---------------------------------------------------------------------------
-- Enough words, in the right register, for every path
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_thin  TEXT;
    v_paths INTEGER;
    v_words INTEGER;
    v_pairs BIGINT;
    r       RECORD;
BEGIN
    -- Every path carries a full set. A path short of words is a path whose
    -- cultivators get a worse name than everybody else.
    SELECT string_agg(p.code || ' (' || COALESCE(w.n, 0) || ')', ', ')
    INTO v_thin
    FROM paths p
    LEFT JOIN (SELECT source_code, count(*) AS n FROM dao_words
               WHERE source_kind = 'path' AND role = 'adjective'
               GROUP BY source_code) w ON w.source_code = p.code
    WHERE COALESCE(w.n, 0) < 6;
    IF v_thin IS NOT NULL THEN
        RAISE EXCEPTION 'these paths have fewer than six adjectives: %', v_thin;
    END IF;

    SELECT string_agg(p.code || ' (' || COALESCE(w.n, 0) || ')', ', ')
    INTO v_thin
    FROM paths p
    LEFT JOIN (SELECT source_code, count(*) AS n FROM dao_words
               WHERE source_kind = 'path' AND role = 'noun'
               GROUP BY source_code) w ON w.source_code = p.code
    WHERE COALESCE(w.n, 0) < 6;
    IF v_thin IS NOT NULL THEN
        RAISE EXCEPTION 'these paths have fewer than six nouns: %', v_thin;
    END IF;

    -- Every body and every craft is covered too.
    IF EXISTS (SELECT 1 FROM body_paths b
               WHERE NOT EXISTS (SELECT 1 FROM dao_words w
                                 WHERE w.source_kind = 'body' AND w.source_code = b.code)) THEN
        RAISE EXCEPTION 'a body path has no words';
    END IF;
    IF EXISTS (SELECT 1 FROM professions pr
               WHERE NOT EXISTS (SELECT 1 FROM dao_words w
                                 WHERE w.source_kind = 'craft' AND w.source_code = pr.code)) THEN
        RAISE EXCEPTION 'a craft has no words';
    END IF;

    -- Nothing points at a path, body or craft that does not exist.
    IF EXISTS (SELECT 1 FROM dao_words w WHERE w.source_kind = 'path'
               AND NOT EXISTS (SELECT 1 FROM paths p WHERE p.code = w.source_code)) THEN
        RAISE EXCEPTION 'a word is keyed to a path that does not exist';
    END IF;
    IF EXISTS (SELECT 1 FROM dao_words w WHERE w.source_kind = 'body'
               AND NOT EXISTS (SELECT 1 FROM body_paths b WHERE b.code = w.source_code)) THEN
        RAISE EXCEPTION 'a word is keyed to a body that does not exist';
    END IF;
    IF EXISTS (SELECT 1 FROM dao_words w WHERE w.source_kind = 'craft'
               AND NOT EXISTS (SELECT 1 FROM professions pr WHERE pr.code = w.source_code)) THEN
        RAISE EXCEPTION 'a word is keyed to a craft that does not exist';
    END IF;

    -- Every template names only placeholders the composer can fill.
    FOR r IN SELECT code, shape FROM dao_templates LOOP
        IF r.shape !~ '^[^{}]*(\{(adj1|adj2|noun1|noun2|body_adj|craft_noun)\}[^{}]*)+$' THEN
            RAISE EXCEPTION
                'the template % names a placeholder nothing fills: %',
                r.code, r.shape;
        END IF;
    END LOOP;

    -- And the register: the existing path_words are still reachable, because
    -- they ARE the register and losing them would lose it.
    SELECT count(*) INTO v_words
    FROM path_words pw
    WHERE EXISTS (SELECT 1 FROM dao_words w
                  WHERE w.source_kind = 'path' AND w.source_code = pw.path_code
                    AND w.word = pw.word);
    IF v_words < 60 THEN
        RAISE EXCEPTION
            'only % of the original 102 words survived into the new vocabulary',
            v_words;
    END IF;

    SELECT count(*) INTO v_words FROM dao_words;
    SELECT count(DISTINCT source_code) INTO v_paths FROM dao_words
    WHERE source_kind = 'path';

    -- How much variety this actually buys, stated rather than hoped at.
    SELECT sum(a.n * b.n) INTO v_pairs
    FROM (SELECT source_code, count(*) AS n FROM dao_words
          WHERE source_kind='path' AND role='adjective' GROUP BY source_code) a
    CROSS JOIN (SELECT source_code, count(*) AS n FROM dao_words
                WHERE source_kind='path' AND role='noun' GROUP BY source_code) b
    WHERE a.source_code <> b.source_code;

    RAISE NOTICE
        '% words over % paths; % adjective-noun pairings across distinct paths, times % templates',
        v_words, v_paths, v_pairs, (SELECT count(*) FROM dao_templates);
END;
$probe$;
