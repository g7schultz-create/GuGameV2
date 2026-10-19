-- 0414_a_roster_of_servants_and_what_each_is_good_for
--
-- The first of four. This one is only the CATALOGUE - who exists, what tier
-- they sit at and what each is good for. Nothing owns a servant yet, nothing
-- rolls for one and nothing farms with one; those are 0415, 0416 and 0417.
-- Split that way because a roster is data and the rest is machinery, and a
-- migration that seeds sixty-seven rows should not also be the one that
-- decides what a star costs.
--
-- WHY SERVANTS AT ALL. Mortal materials have quietly become unobtainable for
-- anybody who has left the mortal realms, and the recipes never stopped asking
-- for them. Centipede Venom is wanted by 344 Gu recipes and there is not one
-- of it on the server. Fish Scale Shard: 294 recipes, none held. Crab
-- Carapace: 364 recipes, 1,248 between every living cultivator. A rank 10
-- immortal cannot go back and pick grass, so the bench closes behind them.
-- A servant is somebody who CAN go and pick it.
--
-- THE SIX BONUSES, and the one that had to be adapted. The roster asks for
-- Cultivation, STR, Attack, Health, Double Strike and Aperture. Five map onto
-- effects this game already has:
--
--     cultivation   -> cultivation_rate    Cultivation Speed
--     attack        -> attack_power        Attack Power
--     health        -> max_hp              Maximum HP
--     aperture      -> max_qi              Battle Qi Capacity
--     double_strike -> multi_hit           Extra Strikes
--
-- STR does not. Strength in this game is Sinew: FLAT points on a body, capped
-- at 30, and there is no percentage multiplier anywhere for it to be a
-- percentage OF. So a Strength servant grants points rather than a share, and
-- `servant_tiers` carries a second column for them. Writing "plus six per
-- cent" against a stat measured in points would have been a number that looks
-- like the others and means something else.
--
-- WHAT A TIER IS WORTH is in `servant_tiers` rather than on each servant, so
-- the whole curve moves by editing seven rows. Roll weights live there too:
-- they are the weight of the TIER, and a roll picks a tier and then somebody
-- inside it, which keeps a tier''s odds fixed no matter how many characters
-- are later added to it. Thirteen Venerables did not make Venerables thirteen
-- times likelier.
--
-- `image_url` is a column with no pictures in it yet, on purpose - it is
-- easier to add the column now than to migrate sixty-seven rows later.
--
-- Forward-only. Do not edit once applied.


CREATE TABLE servant_tiers (
    tier          SMALLINT PRIMARY KEY CHECK (tier BETWEEN 1 AND 7),
    rarity        TEXT NOT NULL REFERENCES rarities(code),
    -- What a percentage bonus is worth at this tier, and what a Double Strike
    -- one is instead: an extra whole swing scales harder than a stat, so it is
    -- deliberately the smaller number.
    pct_bonus     NUMERIC NOT NULL CHECK (pct_bonus > 0),
    strike_bonus  NUMERIC NOT NULL CHECK (strike_bonus > 0),
    -- Sinew is points, not a share. See the header.
    flat_bonus    INTEGER NOT NULL CHECK (flat_bonus > 0),
    roll_weight   NUMERIC NOT NULL CHECK (roll_weight > 0),
    farm_per_hour NUMERIC NOT NULL CHECK (farm_per_hour > 0)
);

COMMENT ON TABLE servant_tiers IS
    'What a servant of each tier is worth, and how often the wheel gives one. Held here rather than per servant so the whole curve moves by editing seven rows.';

INSERT INTO servant_tiers
    (tier, rarity, pct_bonus, strike_bonus, flat_bonus, roll_weight, farm_per_hour)
VALUES
    (1, 'common',    0.005, 0.0015,  1, 4000,  1),
    (2, 'uncommon',  0.010, 0.0030,  1, 2500,  2),
    (3, 'rare',      0.015, 0.0050,  2, 1800,  3),
    (4, 'epic',      0.020, 0.0075,  3,  900,  5),
    (5, 'legendary', 0.030, 0.0100,  5,  350,  8),
    (6, 'mythic',    0.045, 0.0150,  7,   90, 12),
    (7, 'unique',    0.060, 0.0250, 10,   12, 18);


-- ---------------------------------------------------------------------------
-- What a servant is good for, said once
-- ---------------------------------------------------------------------------

CREATE TABLE servant_bonuses (
    kind        TEXT PRIMARY KEY,
    effect_code TEXT NOT NULL REFERENCES gu_effects(code),
    name        TEXT NOT NULL,
    is_flat     BOOLEAN NOT NULL DEFAULT FALSE,
    is_strike   BOOLEAN NOT NULL DEFAULT FALSE
);

COMMENT ON TABLE servant_bonuses IS
    'The six things a servant can be good for, and which effect each one actually feeds. `is_flat` marks Strength, which this game measures in points rather than a share.';

INSERT INTO servant_bonuses (kind, effect_code, name, is_flat, is_strike) VALUES
    ('cultivation',   'cultivation_rate', 'Cultivation',   FALSE, FALSE),
    ('attack',        'attack_power',     'Attack',        FALSE, FALSE),
    ('health',        'max_hp',           'Health',        FALSE, FALSE),
    ('aperture',      'max_qi',           'Aperture',      FALSE, FALSE),
    ('double_strike', 'multi_hit',        'Double Strike', FALSE, TRUE),
    ('strength',      'base_strength',    'Strength',      TRUE,  FALSE);


-- ---------------------------------------------------------------------------
-- The roster
-- ---------------------------------------------------------------------------

CREATE TABLE servants (
    servant_code    TEXT PRIMARY KEY,
    name            TEXT NOT NULL UNIQUE,
    gender_pool     TEXT NOT NULL CHECK (gender_pool IN ('male', 'female', 'any')),
    tier            SMALLINT NOT NULL REFERENCES servant_tiers(tier),
    bonus_kind      TEXT NOT NULL REFERENCES servant_bonuses(kind),
    canonical_peak  TEXT,
    story_weight    TEXT,
    trait_name      TEXT,
    trait_text      TEXT,
    blurb           TEXT,
    -- Pictures come later; the column does not.
    image_url       TEXT,
    -- A named character is somebody out of the story. The generics exist so
    -- the shallow end of the wheel is not full of Venerables.
    is_named        BOOLEAN NOT NULL DEFAULT TRUE,
    CHECK ((trait_name IS NULL) = (trait_text IS NULL))
);

CREATE INDEX servants_tier_idx ON servants (tier);

COMMENT ON TABLE servants IS
    'Everybody who can be rolled. Tier decides what they are worth and how rare they are; bonus_kind decides what they are good for. Story importance sets the tier, and fighting style sets the bonus - not cultivation rank alone.';


-- ---- the unique ones, who are the story ------------------------------------

INSERT INTO servants (servant_code, name, gender_pool, tier, bonus_kind,
                      canonical_peak, story_weight, trait_name, trait_text, blurb)
VALUES
('star_constellation', 'Star Constellation Immortal Venerable', 'female', 7, 'cultivation',
 'Rank 9 Venerable', 'extreme', 'Wisdom Deduction',
 'A small bonus to the harmony of anything refined or enlightened.',
 'Founder of the wisdom path and a central Heavenly Court figure.'),
('bai_ning_bing', 'Bai Ning Bing', 'female', 7, 'double_strike',
 'Gu Immortal', 'extreme', 'Northern Dark Ice Soul',
 'A small chance to survive a lethal blow at one health.',
 'One of Fang Yuan''s most iconic companions, rivals and recurring threats.'),
('hei_lou_lan', 'Hei Lou Lan', 'female', 7, 'strength',
 'High-level Gu Immortal', 'very high', 'Great Strength True Martial',
 'Slightly improves the Strength carried by worn equipment.',
 'Northern Plains extreme physique holder, ally and rival by turns.'),
('fang_yuan', 'Fang Yuan', 'male', 7, 'cultivation',
 'Rank 9 Venerable', 'protagonist', 'Perseverance',
 'A small bonus to cultivation won from difficult content.',
 'The central character of the entire story.'),
('spectral_soul', 'Spectral Soul Demon Venerable', 'male', 7, 'attack',
 'Rank 9 Venerable', 'extreme', 'Soul Devourer',
 'A small chance for a felled boss to give back health and qi.',
 'Founder of the soul path and the longest shadow over the story.'),
('giant_sun', 'Giant Sun Immortal Venerable', 'male', 7, 'aperture',
 'Rank 9 Venerable', 'extreme', 'Fortune Rivalling Heaven',
 'Slightly improves the chance of a rare find.',
 'Luck path Venerable whose inheritances shape the Northern Plains.'),
('red_lotus', 'Red Lotus Demon Venerable', 'male', 7, 'cultivation',
 'Rank 9 Venerable', 'extreme', 'River of Time',
 'A small chance for a cultivation action to refund its cooldown.',
 'His war on Fate Gu is the foundation the whole plot stands on.'),
('limitless', 'Limitless Demon Venerable', 'male', 7, 'strength',
 'Rank 9 Venerable', 'very high', 'Limitless Dao',
 'Slightly raises the ceiling on mastery-based bonuses.',
 'One of the strongest Venerables in history.'),
('reckless_savage', 'Reckless Savage Demon Venerable', 'male', 7, 'strength',
 'Rank 9 Venerable', 'high', 'Savage Transformation',
 'A small chance to gain a burst of Strength when attacking.',
 'Strength and transformation path Venerable of enormous influence.'),
('thieving_heaven', 'Thieving Heaven Demon Venerable', 'male', 7, 'double_strike',
 'Rank 9 Venerable', 'very high', 'Steal Heavenly Secret',
 'A small chance for an encounter to yield one more material.',
 'Theft path Venerable whose inheritances keep finding Fang Yuan.'),
('paradise_earth', 'Paradise Earth Immortal Venerable', 'male', 7, 'health',
 'Rank 9 historically', 'very high', 'Benevolent Paradise',
 'Slightly improves healing received.',
 'His revival plans run under the whole late story.'),
('genesis_lotus', 'Genesis Lotus Immortal Venerable', 'male', 7, 'health',
 'Rank 9 Venerable', 'high', 'Heavenly Lotus',
 'A small recovery after every fight.',
 'Heavenly Court Venerable whose methods outlived him by an era.'),
('primordial_origin', 'Primordial Origin Immortal Venerable', 'male', 7, 'aperture',
 'Rank 9 Venerable', 'very high', 'Primordial Qi',
 'Slightly improves how quickly qi returns.',
 'The first human Venerable and founder of the Heavenly Court.');


-- ---- mythic --------------------------------------------------------------

INSERT INTO servants (servant_code, name, gender_pool, tier, bonus_kind,
                      canonical_peak, story_weight, trait_name, trait_text, blurb)
VALUES
('feng_jin_huang', 'Feng Jin Huang', 'female', 6, 'cultivation',
 'Gu Immortal', 'very high', 'Dreamer',
 'A slight bonus to what a dream or an enlightenment returns.',
 'Exceptional talent of the younger generation, bound to the dream path.'),
('qin_ding_ling', 'Qin Ding Ling', 'female', 6, 'aperture',
 'Rank 8', 'high', 'Fortune Read',
 'A small increase to favourable random outcomes.',
 'Heavenly Court leader and luck path expert.'),
('fairy_zi_wei', 'Fairy Zi Wei', 'female', 6, 'cultivation',
 'Rank 8', 'very high', 'Deduction',
 'A small improvement to what information-gathering returns.',
 'Heavenly Court wisdom path expert who drives the hunt for Fang Yuan.'),
('blazing_heaven_demoness', 'Blazing Heaven Demoness', 'female', 6, 'attack',
 'Rank 8', 'high', 'Blazing Heaven',
 'A slight bonus to fire path techniques.',
 'Northern Plains immortal zombie, elder sister of Fairy Li Shan.'),
('duke_long', 'Duke Long', 'male', 6, 'health',
 'Rank 8 pseudo-venerable', 'extreme', 'Dragon Guard',
 'Slight damage reduction while below half health.',
 'The Heavenly Court''s defining combatant through the Fate War.'),
('feng_jiu_ge', 'Feng Jiu Ge', 'male', 6, 'attack',
 'Rank 8 Dao Guardian', 'extreme', 'Nine Songs',
 'Slightly increases what a technique hits for.',
 'The strongest and most influential man never to be a Venerable.'),
('wu_yong', 'Wu Yong', 'male', 6, 'attack',
 'Rank 8', 'very high', 'Clan Lord',
 'A small edge in the opening exchanges of a group fight.',
 'Wu clan leader and a regional power in his own right.'),
('bo_qing', 'Bo Qing', 'male', 6, 'double_strike',
 'Pseudo-Venerable', 'high', 'Sword Heart',
 'A slight bonus to weapon-borne attacks.',
 'Legendary sword path pseudo-venerable and a Spectral Soul split.'),
('qi_jue', 'Qi Jue', 'male', 6, 'aperture',
 'Rank 8 pseudo-venerable', 'high', 'Qi Reservoir',
 'Slightly reduces what a technique costs to throw.',
 'Ancient qi path powerhouse walking in the modern era.'),
('shen_shang', 'Shen Shang', 'male', 6, 'health',
 'Rank 8', 'high', 'Human Path Mercy',
 'A slight bonus to healing given.',
 'Human path expert who matters at the very top of the board.'),
('lu_wei_yin', 'Lu Wei Yin', 'male', 6, 'health',
 'Rank 8', 'very high', 'Paradise Inheritor',
 'A small resistance to control and hindering effects.',
 'Paradise Earth''s inheritor and a major late-story ally.'),
('purple_mountain', 'Purple Mountain True Monarch', 'male', 6, 'cultivation',
 'Rank 8', 'very high', 'Shadow Counsel',
 'A slight bonus to wisdom path enlightenment.',
 'Spectral Soul split and Shadow Sect leader at its height.');


-- ---- legendary and epic, who are named but carry no trait -----------------

INSERT INTO servants (servant_code, name, gender_pool, tier, bonus_kind,
                      canonical_peak, story_weight, blurb)
VALUES
('zhao_lian_yun', 'Zhao Lian Yun', 'female', 5, 'aperture',
 'Gu Immortal', 'high', 'Otherworldly demon, later bound up with Love Gu.'),
('fairy_miao_yin', 'Fairy Miao Yin', 'female', 5, 'double_strike',
 'Rank 7', 'medium-high', 'Shadow Sect sound path fighter.'),
('lady_white_rabbit', 'Lady White Rabbit', 'female', 5, 'health',
 'Gu Immortal', 'medium-high', 'Southern Border ally with the Black Tigress temper.'),
('fairy_li_shan', 'Fairy Li Shan', 'female', 5, 'aperture',
 'Rank 7', 'high', 'Northern Plains information path immortal.'),
('mo_yao', 'Mo Yao', 'female', 5, 'cultivation',
 'Rank 7 in life', 'high', 'Spirit Affinity House fairy whose will still moves events.'),
('lady_wan_shou', 'Lady Wan Shou', 'female', 5, 'cultivation',
 'Gu Immortal', 'medium', 'Refinement path immortal of the Fortune Rivalling Heaven attempt.'),
('bing_sai_chuan', 'Bing Sai Chuan', 'male', 5, 'aperture',
 'Rank 8', 'high', 'Longevity Heaven leader, luck and time path both.'),
('chu_du', 'Chu Du', 'male', 5, 'strength',
 'Rank 7', 'high', 'Domination Immortal and a defining strength path fighter.'),
('ying_wu_xie', 'Ying Wu Xie', 'male', 5, 'cultivation',
 'Shadow Sect core', 'very high', 'Pure Dream Reality Seeker Physique, and never far behind.'),
('tai_bai_yun_sheng', 'Tai Bai Yun Sheng', 'male', 5, 'health',
 'Rank 6', 'high', 'Long-running companion with time path healing.'),
('fang_zheng', 'Fang Zheng', 'male', 5, 'health',
 'Gu Immortal', 'very high', 'Fang Yuan''s twin, and his counterpoint throughout.'),
('ma_hong_yun', 'Ma Hong Yun', 'male', 5, 'aperture',
 'Low personal power', 'very high', 'Owner of Fortune Rivalling Heaven. Ranked for what follows him, not what he can do.'),
('fang_di_chang', 'Fang Di Chang', 'male', 5, 'cultivation',
 'Rank 8-level', 'medium-high', 'Fang clan wisdom path strategist in the Western Desert.'),
('shang_xin_ci', 'Shang Xin Ci', 'female', 4, 'health',
 'Mortal-era', 'high', 'One of Fang Yuan''s earliest ties, and later a clan leader.'),
('tie_ruo_nan', 'Tie Ruo Nan', 'female', 4, 'strength',
 'Gu Master', 'high', 'Righteous path investigator who would not let go.'),
('song_yi_shi', 'Song Yi Shi', 'female', 4, 'aperture',
 'Rank 6', 'medium', 'Eastern Sea immortal with the right friends.'),
('xue_er', 'Xue Er', 'female', 4, 'health',
 'Rank 6', 'medium', 'Snowman Gu Immortal and a variant-human tie.'),
('fairy_cui_bo', 'Fairy Cui Bo', 'female', 4, 'attack',
 'Rank 7', 'lower', 'Stronger than several above her and far less consequential.'),
('hei_fan', 'Hei Fan', 'male', 4, 'cultivation',
 'Rank 8', 'medium', 'Historical time path expert whose inheritance matters enormously.'),
('qin_bai_sheng', 'Qin Bai Sheng', 'male', 4, 'attack',
 'Rank 7', 'high', 'Central to the Northern Plains auction and the Shadow Sect.'),
('old_man_yan_shi', 'Old Man Yan Shi', 'male', 4, 'cultivation',
 'Rank 7', 'high', 'Shadow Sect planner behind a dozen long schemes.'),
('dong_fang_chang_fan', 'Dong Fang Chang Fan', 'male', 4, 'cultivation',
 'Rank 7', 'high', 'Northern Plains wisdom path immortal and possession schemer.'),
('ma_ying_jie', 'Ma Ying Jie', 'male', 4, 'aperture',
 'Gu Immortal', 'medium', 'Ma tribe leader on the enslavement path.'),
('hei_cheng', 'Hei Cheng', 'male', 4, 'attack',
 'Rank 7', 'medium-high', 'Hei Lou Lan''s father, and the reason for her revenge.');


-- ---- and the ones who are not anybody, so that the famous stay famous -----

INSERT INTO servants (servant_code, name, gender_pool, tier, bonus_kind, is_named, blurb)
VALUES
('gu_yue_disciple',    'Gu Yue Clan Disciple',     'any', 1, 'cultivation',   FALSE, 'A clan child with a Gu and a lot to learn.'),
('caravan_guard',      'Caravan Guard',            'any', 1, 'health',        FALSE, 'Paid by the mile to stand in front of somebody else.'),
('mortal_strength_gu_master', 'Mortal Strength Gu Master', 'any', 1, 'strength', FALSE, 'One Strength Gu and no illusions about it.'),
('village_hunter',     'Village Hunter',           'any', 1, 'attack',        FALSE, 'Knows the woods better than the Gu in his hand.'),
('academy_student',    'Academy Student',          'any', 1, 'aperture',      FALSE, 'Still measuring their aperture every morning.'),
('twin_blade_disciple','Twin-Blade Disciple',      'any', 1, 'double_strike', FALSE, 'Two blades, neither of them mastered.'),
('rank_two_elite',     'Rank Two Clan Elite',      'any', 2, 'attack',        FALSE, 'The best of a small clan, which is not nothing.'),
('beast_hunter_captain','Beast Hunter Captain',    'any', 2, 'strength',      FALSE, 'Brings back the carcass and the men both.'),
('medicine_hall_disciple','Medicine Hall Disciple','any', 2, 'health',        FALSE, 'Grinds more than they brew, for now.'),
('primeval_stone_steward','Primeval Stone Steward','any', 2, 'aperture',      FALSE, 'Counts the clan''s stones and knows where they go.'),
('sect_inner_disciple','Sect Inner Disciple',      'any', 2, 'cultivation',   FALSE, 'Inner robes, outer worries.'),
('shadow_blade_assassin','Shadow Blade Assassin',  'any', 2, 'double_strike', FALSE, 'Paid twice for one night''s work.'),
('rank_three_elder',   'Rank Three Clan Elder',    'any', 3, 'health',        FALSE, 'Old enough to have outlived his rivals.'),
('demonic_wanderer',   'Demonic Path Wanderer',    'any', 3, 'attack',        FALSE, 'No clan, no sect, no witnesses.'),
('strength_path_veteran','Strength Path Veteran',  'any', 3, 'strength',      FALSE, 'Thirty years of lifting what others would not.'),
('refinement_hall_elder','Refinement Hall Elder',  'any', 3, 'cultivation',   FALSE, 'Has ruined more Gu than most people have seen.'),
('essence_formation_adept','Essence Formation Adept','any', 3, 'aperture',    FALSE, 'Reads a formation the way others read a road.'),
('twin_sword_expert',  'Twin Sword Expert',        'any', 3, 'double_strike', FALSE, 'The second blade finally means something.');


-- ---------------------------------------------------------------------------
-- Sixty-seven of them, and every one of them good for something real
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_bad TEXT;
    r     RECORD;
BEGIN
    -- Every bonus must feed an effect that is actually read, or a servant is
    -- a card with nothing behind it - which is what 0405 had to go back and
    -- fix for four page kinds.
    SELECT string_agg(b.kind, ', ') INTO v_bad
    FROM servant_bonuses b
    JOIN gu_effects ef ON ef.code = b.effect_code
    WHERE NOT ef.is_live;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these bonuses feed effects nothing reads: %', v_bad;
    END IF;

    -- Strength is the only flat one, and it must be the only flat one - the
    -- whole reason `flat_bonus` exists is that points are not a share.
    SELECT string_agg(b.kind, ', ') INTO v_bad
    FROM servant_bonuses b
    JOIN gu_effects ef ON ef.code = b.effect_code
    WHERE ef.is_base <> b.is_flat;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION
            'these disagree with their effect about being points: %', v_bad;
    END IF;

    -- A tier with nobody in it cannot be rolled, and a roll that picks a tier
    -- first would then have to pick nobody.
    SELECT string_agg(t.tier::text, ', ') INTO v_bad
    FROM servant_tiers t
    WHERE NOT EXISTS (SELECT 1 FROM servants s WHERE s.tier = t.tier);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these tiers have nobody in them: %', v_bad;
    END IF;

    -- The rarest tier must actually be the rarest.
    IF (SELECT roll_weight FROM servant_tiers WHERE tier = 7)
       >= (SELECT min(roll_weight) FROM servant_tiers WHERE tier < 7) THEN
        RAISE EXCEPTION 'a Venerable is not rarer than everything under one';
    END IF;

    -- Nobody unique is missing the trait that is the point of being unique.
    SELECT string_agg(s.name, ', ') INTO v_bad
    FROM servants s WHERE s.tier = 7 AND s.trait_name IS NULL;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these are unique and carry no trait: %', v_bad;
    END IF;

    FOR r IN
        SELECT t.tier, t.rarity, count(s.servant_code) AS people,
               round(100 * t.roll_weight
                     / (SELECT sum(roll_weight) FROM servant_tiers), 3) AS pct
        FROM servant_tiers t
        LEFT JOIN servants s ON s.tier = t.tier
        GROUP BY t.tier, t.rarity, t.roll_weight
        ORDER BY t.tier
    LOOP
        RAISE NOTICE 'T% %: % servant(s), % in a hundred rolls',
            r.tier, rpad(r.rarity, 10), r.people, r.pct;
    END LOOP;

    RAISE NOTICE '% servants on the roster, % of them named',
        (SELECT count(*) FROM servants),
        (SELECT count(*) FROM servants WHERE is_named);
END;
$probe$;
