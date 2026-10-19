-- 0308_techniques_that_do_something_other_than_damage
--
-- 203 of the 205 techniques this game shipped with were category 'attack'.
-- The other two were a defense and a utility that did nothing, because until
-- 0298 there was nothing for them to do. This is the content that engine was
-- built for: thirty techniques that mend, ward, set, rally and mark.
--
-- A SUPPORT TECHNIQUE TRADES ITS DAMAGE FOR ITS EFFECT. Every one below has
-- `base_power` 0. A technique that both warded you and hit for full would be
-- strictly better than the attack technique beside it, and then there is no
-- decision in the screen - only an obviously correct button. Spending the
-- turn IS the cost, and that is the whole design.
--
-- WHICH MEANS `category` FINALLY MATTERS. `dungeon_default_move` picks the
-- best 'attack' technique, so none of these can be auto-selected and nobody
-- walks into a dungeon swinging for nothing without having chosen to.
--
-- WHY PARTY EFFECTS ARE THE EXPENSIVE ONES. A rally that multiplies five
-- cultivators' blows is worth roughly five times a rally that multiplies one,
-- so the party techniques sit high on the ladder and the self-only ones sit
-- low. Rallying a room you are alone in is legal and nearly pointless, which
-- is the correct amount of pointless.
--
-- TAUNT IS WHY BONE AND SOUL EXIST ON THIS LIST. It only does anything where
-- something chooses a victim - a dungeon room - so the Paths that get it are
-- the ones a person would actually bring to a room rather than to a duel.
--
-- Forward-only. Do not edit once applied.


WITH spec (code, name, rank, qi, cat, pa, wa, pb, wb, effects, descr) AS (VALUES
  -- ---- mending -----------------------------------------------------------
  ('blood_nourishing_art','Blood Nourishing Art',3,0.14,'support','blood',0.7,'qi',0.3,
   '{"apply":[{"code":"regen","magnitude":0.05,"turns":3}]}',
   'Blood put back where it was taken from. Slower than losing it, as everything is.'),
  ('verdant_mending','Verdant Mending',4,0.18,'support','wood',0.7,'water',0.3,
   '{"apply":[{"code":"regen","magnitude":0.07,"turns":3}]}',
   'What grows over a wound is not the same flesh. It holds all the same.'),
  ('feast_of_the_long_road','Feast of the Long Road',5,0.22,'support','food',0.7,'earth',0.3,
   '{"apply":[{"code":"regen","magnitude":0.09,"turns":4}]}',
   'Eaten once, drawn on for days. Food Path''s whole argument in one sitting.'),
  ('circulating_mend','Circulating Mend',7,0.30,'support','qi',0.6,'water',0.4,
   '{"apply":[{"code":"regen","magnitude":0.13,"turns":4}]}',
   'The qi does not stop to repair anything. It repairs on the way past, continuously.'),
  ('crimson_mending','Crimson Mending',8,0.34,'support','blood',0.7,'soul',0.3,
   '{"apply":[{"code":"regen","magnitude":0.18,"turns":4}]}',
   'There is more blood in the world than in you, and it does not object to the arrangement.'),
  ('immortal_crimson_renewal','Immortal Crimson Renewal',9,0.42,'support','blood',0.6,'time',0.4,
   '{"apply":[{"code":"regen","magnitude":0.25,"turns":5}]}',
   'Not healing. A refusal, renewed each moment, to have been wounded.'),

  -- ---- warding -----------------------------------------------------------
  ('bone_shield_art','Bone Shield Art',3,0.13,'defense','bone',0.7,'earth',0.3,
   '{"apply":[{"code":"defence_up","magnitude":0.14,"turns":3}]}',
   'Your own frame, brought closer to the outside than it was meant to be.'),
  ('frost_carapace','Frost Carapace',5,0.20,'defense','ice',0.7,'water',0.3,
   '{"apply":[{"code":"defence_up","magnitude":0.20,"turns":3}]}',
   'A shell that does not harden so much as refuse to be hurried.'),
  ('mountain_root_stance','Mountain Root Stance',6,0.25,'defense','earth',0.7,'strength',0.3,
   '{"apply":[{"code":"defence_up","magnitude":0.26,"turns":3}]}',
   'Rooted. Everything that arrives has to move the mountain first, and it will not be moved.'),
  ('bulwark_formation','Bulwark Formation',7,0.34,'defense','formation',0.6,'earth',0.4,
   '{"apply":[{"code":"defence_up","magnitude":0.22,"turns":4,"target":"party"}]}',
   'Drawn around the whole line at once. A formation is worth nothing to one person standing in it.'),
  ('vault_of_ten_thousand_walls','Vault of Ten Thousand Walls',9,0.44,'defense','formation',0.6,'metal',0.4,
   '{"apply":[{"code":"defence_up","magnitude":0.40,"turns":4,"target":"party"}]}',
   'Ten thousand walls, each one behind the last. Getting through is not the problem. Finishing is.'),

  -- ---- setting against the blow ------------------------------------------
  ('iron_skin_stance','Iron Skin Stance',4,0.16,'defense','metal',0.7,'bone',0.3,
   '{"apply":[{"code":"block_up","magnitude":0.15,"turns":3}]}',
   'Not armour. A way of standing that makes the armour you have count twice.'),
  ('the_reed_that_bends','The Reed That Bends',6,0.24,'defense','wind',0.6,'wood',0.4,
   '{"apply":[{"code":"block_up","magnitude":0.24,"turns":3}]}',
   'Everything that breaks in a storm was standing up straight when it started.'),
  ('foreseen_guard','Foreseen Guard',8,0.36,'defense','wisdom',0.6,'time',0.4,
   '{"apply":[{"code":"block_up","magnitude":0.35,"turns":4}]}',
   'The blow is not blocked faster. It is blocked earlier, which is a different thing entirely.'),

  -- ---- rallying ----------------------------------------------------------
  ('sword_heart_focus','Sword Heart Focus',5,0.22,'support','sword',0.7,'wisdom',0.3,
   '{"apply":[{"code":"attack_up","magnitude":0.18,"turns":3}]}',
   'The sword does not get sharper. Everything that is not the sword gets quieter.'),
  ('rally_the_line','Rally the Line',6,0.28,'support','human',0.6,'rule',0.4,
   '{"apply":[{"code":"attack_up","magnitude":0.15,"turns":3,"target":"party"}]}',
   'Men fight harder beside other men. The Human Path has never needed a more complicated idea.'),
  ('edict_of_the_vanguard','Edict of the Vanguard',7,0.34,'support','rule',0.6,'human',0.4,
   '{"apply":[{"code":"attack_up","magnitude":0.24,"turns":3,"target":"party"}]}',
   'Not encouragement. An instruction, of the kind the world has agreed to obey.'),
  ('constellation_muster','Constellation Muster',8,0.38,'support','star',0.6,'formation',0.4,
   '{"apply":[{"code":"attack_up","magnitude":0.30,"turns":4,"target":"party"}]}',
   'Every one of them placed where a star would be, and lent what a star is owed.'),
  ('heavens_favour','Heaven''s Favour',8,0.38,'support','heaven',0.7,'luck',0.3,
   '{"apply":[{"code":"attack_up","magnitude":0.33,"turns":3,"target":"party"}]}',
   'Heaven does not favour. It is merely persuaded, briefly, to look elsewhere while you work.'),
  ('mandate_of_the_nine','Mandate of the Nine',9,0.46,'support','heaven',0.6,'rule',0.4,
   '{"apply":[{"code":"attack_up","magnitude":0.45,"turns":4,"target":"party"}]}',
   'Nine authorities, none of them yours, all of them briefly agreeing that this should be permitted.'),

  -- ---- marking -----------------------------------------------------------
  ('mirror_decoy','Mirror Decoy',5,0.20,'utility','illusion',0.7,'shadow',0.3,
   '{"apply":[{"code":"taunt","magnitude":0.40,"turns":2}]}',
   'There is suddenly more of you to be angry at, and all of it is standing in front.'),
  ('weight_of_regard','Weight of Regard',7,0.32,'utility','soul',0.6,'bone',0.4,
   '{"apply":[{"code":"taunt","magnitude":0.70,"turns":3}]}',
   'Being looked at by something large is a wound of its own. This is arranging to be looked at.'),
  ('compelling_gaze','Compelling Gaze',8,0.36,'utility','enslavement',0.6,'soul',0.4,
   '{"apply":[{"code":"taunt","magnitude":0.85,"turns":3}]}',
   'It has not decided to come for you. It has been relieved of the decision.'),
  ('sovereigns_regard','Sovereign''s Regard',9,0.46,'utility','soul',0.5,'enslavement',0.5,
   '{"apply":[{"code":"taunt","magnitude":1.00,"turns":4},{"code":"defence_up","magnitude":0.25,"turns":4}]}',
   'Everything in the room is yours to be hated by, and a sovereign is expected to survive being hated.'),

  -- ---- the ones that do two things --------------------------------------
  ('stone_hearted_vigil','Stone-Hearted Vigil',7,0.33,'defense','bone',0.5,'earth',0.5,
   '{"apply":[{"code":"taunt","magnitude":0.55,"turns":3},{"code":"block_up","magnitude":0.22,"turns":3}]}',
   'Standing where the blow is going to be, having already decided to still be there afterwards.'),
  ('shepherd_of_the_dying','Shepherd of the Dying',8,0.38,'support','food',0.5,'blood',0.5,
   '{"apply":[{"code":"regen","magnitude":0.12,"turns":4,"target":"party"}]}',
   'Fed to the whole line, from a bowl nobody watched being filled.'),
  ('the_unmoving_edict','The Unmoving Edict',9,0.46,'defense','rule',0.5,'formation',0.5,
   '{"apply":[{"code":"defence_up","magnitude":0.35,"turns":4,"target":"party"},{"code":"block_up","magnitude":0.25,"turns":4,"target":"party"}]}',
   'It is written that the line holds. Arguing with what is written is a separate technique.'),
  ('lightning_quickened_heart','Lightning-Quickened Heart',6,0.26,'support','lightning',0.6,'qi',0.4,
   '{"apply":[{"code":"attack_up","magnitude":0.20,"turns":3}]}',
   'The heart is made to beat at the speed of the strike rather than the speed of a man.'),
  ('poisoned_resolve','Poisoned Resolve',7,0.32,'support','poison',0.6,'blood',0.4,
   '{"apply":[{"code":"attack_up","magnitude":0.28,"turns":3},{"code":"regen","magnitude":0.06,"turns":3}]}',
   'Taken deliberately, in a dose the body will survive being improved by.')
), made AS (
    INSERT INTO techniques
        (code, name, rank, category, base_power, qi_cost_pct, grade,
         effects, description)
    SELECT s.code, s.name, s.rank::smallint, s.cat, 0, s.qi::numeric(6,4),
           'basic', s.effects::jsonb, s.descr
    FROM spec s
    RETURNING technique_id, code
)
INSERT INTO technique_paths (technique_id, path_code, weight)
SELECT m.technique_id, s.pa, s.wa::numeric FROM made m JOIN spec s ON s.code = m.code
UNION ALL
SELECT m.technique_id, s.pb, s.wb::numeric FROM made m JOIN spec s ON s.code = m.code;


-- ---------------------------------------------------------------------------
-- The two that have been standing here since the beginning, doing nothing
-- ---------------------------------------------------------------------------
--
-- `rooted_stance` and `minds_eye` are the one defense and the one utility
-- technique this game shipped with. They have never done anything, because
-- until 0298 there was nothing a technique could do except damage - and both
-- have `base_power` 0, so both have been a button that spends qi and a turn
-- and returns nothing at all. Somebody learned them. They are rank 1: almost
-- certainly the first thing a Wisdom or Earth cultivator ever bought.
--
-- Their descriptions already say exactly what they should do. They are given
-- the effects they were written for rather than left as the only two dead
-- techniques on a list that now has thirty live ones.

UPDATE techniques
SET effects = '{"apply":[{"code":"defence_up","magnitude":0.10,"turns":2}]}'
WHERE code = 'rooted_stance';

UPDATE techniques
SET effects = '{"apply":[{"code":"block_up","magnitude":0.12,"turns":2}]}'
WHERE code = 'minds_eye';


-- ---------------------------------------------------------------------------
-- None of them is a free lunch, and all of them do what they say
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    bad TEXT;
    n   INTEGER;
BEGIN
    -- Every new one declares something. A support technique with no effect
    -- and no power is a button that does nothing.
    SELECT string_agg(code, ' ') INTO bad
    FROM techniques
    WHERE created_by IS NULL AND category <> 'attack' AND base_power = 0
      AND NOT (effects ? 'apply');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these spend a turn and do nothing: %', bad;
    END IF;

    -- And none of them also hits, which is the trade this migration is about.
    SELECT string_agg(code, ' ') INTO bad
    FROM techniques
    WHERE created_by IS NULL AND effects ? 'apply' AND base_power > 0;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these ward AND hit, which is strictly better: %', bad;
    END IF;

    -- None can be auto-picked into somebody's dungeon rotation.
    SELECT count(*) INTO n FROM techniques
    WHERE created_by IS NULL AND effects ? 'apply' AND category = 'attack';
    IF n > 0 THEN
        RAISE EXCEPTION '% effect techniques are category attack and would be auto-picked', n;
    END IF;

    SELECT count(*) INTO n FROM techniques
    WHERE created_by IS NULL AND effects ? 'apply';
    RAISE NOTICE '% techniques now do something other than damage', n;
END;
$$;


-- ---------------------------------------------------------------------------
-- One of them, cast in a real fight
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    who  BIGINT;
    ward BIGINT;
    sp   BIGINT;
    held NUMERIC;
BEGIN
    SELECT player_id INTO who FROM players
    WHERE deleted_at IS NULL AND discord_id > 0 ORDER BY player_id LIMIT 1;
    SELECT technique_id INTO ward FROM techniques WHERE code = 'bone_shield_art';

    IF who IS NULL OR ward IS NULL THEN
        RAISE NOTICE 'nothing to test with; the tests carry this';
        RETURN;
    END IF;

    SELECT species_id INTO sp FROM creature_species
    WHERE kind = 'beast' ORDER BY rank DESC LIMIT 1;

    BEGIN
        PERFORM player_swing(who, ward, sp, 1000000::bigint, 0::bigint,
                             NULL, NULL, 0, 'battle', -8);

        held := effect_value('battle', -8, who, 'defence_up');
        IF held <> 0.14 THEN
            RAISE EXCEPTION
                'Bone Shield Art left % behind, not the 0.14 it promises', held;
        END IF;

        PERFORM effect_clear('battle', -8);
        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
