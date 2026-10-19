-- 0338_what_grows_in_black_heaven
--
-- Forty materials, and they are gatherable rather than dug or butchered. That
-- is a choice worth writing down: `region_materials` carries a UNIQUE on
-- material_code, one region each, so putting them here makes them found ONLY
-- in Black Heaven and nowhere else in the world. A mortal cannot buy their way
-- around the door by gathering Nether Moon Marrow in the Southern Border.
--
-- EVERY ONE OF THEM LEANS SOMEWHERE. `test_every_ingredient_leans_somewhere`
-- has held since 0038: a Path-less material is bulk and no opinion, and this
-- game does not ship bulk. Forty new materials is forty new chances to break
-- that rule, so each is given the Path its name already implies - soul for the
-- wails and the ash, bone for the marrow and the powder, formation for the
-- crystals a formation is drawn with.
--
-- THE WEIGHTS FALL WITH THE RARITY, so a gather in Black Heaven mostly turns
-- up nether grass and dark silk, and a Void Boundary Fragment is a day worth
-- talking about. Foraging keeps the rarest of however many candidates a
-- Forager's level draws, so a thin tail is what makes that skill worth having
-- here at all.
--
-- Forward-only. Do not edit once applied.


INSERT INTO materials (code, name, category, rarity, path_code, emoji, description) VALUES
    ('heaven_metal', 'Heaven Metal', 'gathering', 'epic', 'metal', '⚙️',
     'Torn loose from the vault itself. It does not rust; it waits.'),
    ('heaven_attached_fungi', 'Heaven-Attached Fungi', 'gathering', 'rare', 'wood', '🍄',
     'Grows downward from nothing, rooted in the dark above.'),
    ('black_hole_wood', 'Black Hole Wood', 'gathering', 'epic', 'space', '🪵',
     'Heavier than the arm that lifts it, and heavier again tomorrow.'),
    ('black_oil', 'Black Oil', 'gathering', 'uncommon', 'poison', '🛢️',
     'Seeps up through the rock. Nothing that drinks it stays itself.'),
    ('black_soul_water', 'Black Soul Water', 'gathering', 'epic', 'soul', '🌊',
     'Still, and it reflects the drinker rather than the sky.'),
    ('black_iron_qi', 'Black Iron Qi', 'gathering', 'rare', 'qi', '💨',
     'Qi gone so dense it can be cut. Immortals bottle it and regret it.'),
    ('black_cloud_soil', 'Black Cloud Soil', 'gathering', 'rare', 'earth', '🟫',
     'Soil that never settled, hanging where a field ought to be.'),
    ('electrolytic_starlight', 'Electrolytic Starlight', 'gathering', 'legendary', 'star', '✨',
     'Starlight separated into its parts. Only one of the parts is light.'),
    ('ghostly_wail', 'Ghostly Wail', 'gathering', 'rare', 'soul', '👻',
     'A sound that kept going after the thing making it stopped.'),
    ('nether_grass', 'Nether Grass', 'gathering', 'uncommon', 'wood', '🌿',
     'The commonest thing here, which in Black Heaven is not saying much.'),
    ('profound_eerie_wind', 'Profound Eerie Wind', 'gathering', 'rare', 'wind', '🌬️',
     'It blows inward from every direction at once.'),
    ('lightning_qi', 'Lightning Qi', 'gathering', 'rare', 'lightning', '⚡',
     'The moment before the strike, kept in a jar.'),
    ('floating_life_fire', 'Floating Life Fire', 'gathering', 'epic', 'fire', '🔥',
     'A flame that drifts at head height and follows, slowly.'),
    ('nether_grass_essence', 'Nether Grass Essence', 'gathering', 'epic', 'wood', '🌱',
     'What a field of nether grass comes to when it is pressed.'),
    ('nether_moon_marrow', 'Nether Moon Marrow', 'gathering', 'legendary', 'bone', '🦴',
     'There is no moon here. The marrow is from the one there is not.'),
    ('wraithfire_crystal', 'Wraithfire Crystal', 'gathering', 'legendary', 'fire', '💎',
     'Cold to hold and burning to look at.'),
    ('black_eclipse_stone', 'Black Eclipse Stone', 'gathering', 'epic', 'shadow', '🪨',
     'Cut it and the cut face is darker than the dark around it.'),
    ('ghost_lantern_oil', 'Ghost Lantern Oil', 'gathering', 'rare', 'soul', '🏮',
     'Burns with a light that shows only what is already dead.'),
    ('night_terror_flower', 'Night Terror Flower', 'gathering', 'epic', 'dream', '🌸',
     'It opens when the gatherer sleeps, and not before.'),
    ('abyssal_bone_powder', 'Abyssal Bone Powder', 'gathering', 'rare', 'bone', '🦴',
     'Ground from something large enough that nobody found the skull.'),
    ('silent_night_silk', 'Silent Night Silk', 'gathering', 'rare', 'shadow', '🧵',
     'Cloth of it makes no sound at all, including when it tears.'),
    ('nether_moon_pearl', 'Nether Moon Pearl', 'gathering', 'legendary', 'light', '🌕',
     'The only thing in Black Heaven that gives light without being asked.'),
    ('black_eclipse_blood', 'Black Eclipse Blood', 'gathering', 'legendary', 'blood', '🩸',
     'It is warm, and it is nobody''s.'),
    ('netherwind_silk', 'Netherwind Silk', 'gathering', 'epic', 'wind', '🧵',
     'Spun out of the wind rather than by anything living in it.'),
    ('abyssal_shadow_jade', 'Abyssal Shadow Jade', 'gathering', 'legendary', 'shadow', '💠',
     'Jade with a shadow inside it that does not match the room.'),
    ('dark_heaven_lotus_seed', 'Dark Heaven Lotus Seed', 'gathering', 'legendary', 'heaven', '🪷',
     'One seed to a flowering, and the flowerings are centuries apart.'),
    ('silent_soul_ash', 'Silent Soul Ash', 'gathering', 'epic', 'soul', '🌫️',
     'What is left when a soul is burned rather than spent.'),
    ('dark_thread_algae', 'Dark Thread Algae', 'gathering', 'uncommon', 'water', '🌿',
     'Grows in the black water in threads a mile long.'),
    ('dark_soft_silk', 'Dark Soft Silk', 'gathering', 'uncommon', 'shadow', '🧵',
     'Ordinary, by the standards of this place.'),
    ('rooster_iron', 'Rooster Iron', 'gathering', 'rare', 'metal', '⚙️',
     'Red-streaked, and it is hottest at what would be dawn elsewhere.'),
    ('nether_forged_dark_iron', 'Nether-Forged Dark Iron', 'gathering', 'epic', 'metal', '⛓️',
     'Already worked when it is found. Nobody will say by whom.'),
    ('electrolytic_iron_starflower', 'Electrolytic Iron Starflower', 'gathering', 'epic', 'star', '🌟',
     'Iron grown into petals, one crystal at a time.'),
    ('earth_hole_traveling_flame', 'Earth Hole Traveling Flame', 'gathering', 'epic', 'fire', '🔥',
     'It moves through the rock rather than over it.'),
    ('void_boundary_fragment', 'Void Boundary Fragment', 'gathering', 'legendary', 'space', '🌌',
     'A piece of the edge of somewhere. Not of this somewhere.'),
    ('advancing_and_retreating_tidal_water', 'Advancing and Retreating Tidal Water',
     'gathering', 'epic', 'water', '🌊',
     'It comes in and goes out on no schedule anybody has written down.'),
    ('rising_falling_tide_water', 'Rising and Falling Tide Water', 'gathering', 'rare', 'water', '💧',
     'The quieter cousin of the above, and far easier to carry.'),
    ('formation_dao_crystal', 'Formation Dao Crystal', 'gathering', 'legendary', 'formation', '🔷',
     'A formation already inside it, waiting for somebody to read it out.'),
    ('formation_spirit_stone', 'Formation Spirit Stone', 'gathering', 'epic', 'formation', '🔶',
     'What a formation is pinned to the ground with.'),
    ('pill_azure_incense', 'Pill Azure Incense', 'gathering', 'rare', 'refinement', '🕯️',
     'Burned beside a cauldron. The smoke goes into the pill, not the room.'),
    ('refinement_water', 'Refinement Water', 'gathering', 'rare', 'refinement', '💧',
     'Water that has already dissolved everything it is going to.');


-- The tail is thin on purpose: mostly grass and silk, rarely a fragment of
-- the edge of somewhere.
INSERT INTO region_materials (region_code, material_code, weight)
SELECT 'black_heaven', m.code,
       CASE m.rarity WHEN 'uncommon' THEN 10.0
                     WHEN 'rare'     THEN 6.0
                     WHEN 'epic'     THEN 3.0
                     ELSE 1.0 END
FROM materials m
WHERE m.code IN (
    'heaven_metal','heaven_attached_fungi','black_hole_wood','black_oil',
    'black_soul_water','black_iron_qi','black_cloud_soil','electrolytic_starlight',
    'ghostly_wail','nether_grass','profound_eerie_wind','lightning_qi',
    'floating_life_fire','nether_grass_essence','nether_moon_marrow',
    'wraithfire_crystal','black_eclipse_stone','ghost_lantern_oil',
    'night_terror_flower','abyssal_bone_powder','silent_night_silk',
    'nether_moon_pearl','black_eclipse_blood','netherwind_silk',
    'abyssal_shadow_jade','dark_heaven_lotus_seed','silent_soul_ash',
    'dark_thread_algae','dark_soft_silk','rooster_iron',
    'nether_forged_dark_iron','electrolytic_iron_starflower',
    'earth_hole_traveling_flame','void_boundary_fragment',
    'advancing_and_retreating_tidal_water','rising_falling_tide_water',
    'formation_dao_crystal','formation_spirit_stone','pill_azure_incense',
    'refinement_water');


-- ---------------------------------------------------------------------------
-- Forty, all leaning somewhere, all found in one place only
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    n   INTEGER;
    bad TEXT;
BEGIN
    SELECT count(*) INTO n FROM region_materials WHERE region_code = 'black_heaven';
    IF n <> 40 THEN
        RAISE EXCEPTION 'expected 40 materials in Black Heaven, found %', n;
    END IF;

    -- The rule from 0038, checked here rather than waited for.
    SELECT string_agg(m.code, ', ') INTO bad
    FROM region_materials rm JOIN materials m ON m.code = rm.material_code
    WHERE rm.region_code = 'black_heaven' AND m.path_code IS NULL;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these lean nowhere: %', bad;
    END IF;

    -- And each of them says where it comes from, which is here.
    SELECT string_agg(m.code, ', ') INTO bad
    FROM region_materials rm JOIN materials m ON m.code = rm.material_code
    WHERE rm.region_code = 'black_heaven'
      AND NOT EXISTS (SELECT 1 FROM material_sources(m.code));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these come from nowhere: %', bad;
    END IF;

    RAISE NOTICE 'forty materials grow in Black Heaven and nowhere else';
END;
$probe$;
