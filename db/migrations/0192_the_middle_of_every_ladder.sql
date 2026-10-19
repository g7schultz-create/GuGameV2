-- 0192_the_middle_of_every_ladder
--
-- Every Path had a first rung and almost nothing above it. 0161 and 0162 gave
-- all 34 Paths a rank 1 attack; nobody ever filled ranks 2 to 5, and the
-- seeded attacks above that start at rank 6. The result is a hole exactly
-- where the live cultivators are standing.
--
-- The grid, before this migration - seeded attacks by dominant Path:
--
--     11 Paths had NOTHING between rank 1 and rank 6
--        (enslavement, food, heaven, light, luck, painting, qi,
--         refinement, soul, theft, wisdom)
--     23 more had one or two of the four
--        no Path had all of ranks 2, 3, 4 and 5
--
-- m_i_y_u_k_i. is Nascent Soul - Early, rank 4, with an interest in the
-- Heaven Path. Her options were Fate Tap at rank 1 and 113 power, or
-- Heavenly Thunder Edict at rank 6 - and Thunder Edict is gated on LIGHTNING
-- attainment, because the shelf reads the dominant Path by weight and Heaven
-- is the junior partner in it. She had one Heaven move and it was 4% of the
-- power of what she already knew.
--
-- 105 techniques, one per empty cell. Numbers come from the bands the
-- existing 98 seeded attacks already occupy rather than from a new curve:
--
--     rank 2: 270-580     rank 3: 600-1250
--     rank 4: 1500-3100   rank 5: 3800-7800
--
-- A Path's character decides where inside its band it sits - Sword hits
-- harder than Wisdom at the same rank and Wisdom lands more often - but no
-- new technique leaves the band its rank already had. Nothing existing is
-- touched.
--
-- ALL OF THEM ARE 'basic', AND THAT IS LOAD-BEARING. `learn_technique`
-- refuses an 'advanced' technique at any price - those are carried by a
-- manual and only while it is equipped. 105 advanced techniques would be 105
-- more rows nobody can reach, which is the exact failure this migration
-- exists to undo.
--
-- Each one has a single Path, so it is that Path's own dominant move and the
-- attainment gate reads the Path the player was actually training.
--
-- Forward-only. Do not edit once applied.


INSERT INTO techniques
    (code, name, rank, category, grade, base_power, qi_cost_pct, accuracy,
     cooldown_turns, description)
VALUES
    ('crimson_tithe', 'Crimson Tithe', 2, 'attack', 'basic', 408, 0.1000, 0.9200, 1, 'A tenth of what is in them, collected at the door. The rate is not negotiable and the collector is already inside.'),
    ('boiling_vein_cascade', 'Boiling Vein Cascade', 4, 'attack', 'basic', 2400, 0.2000, 0.9000, 3, 'It starts at the wrist and the rest of the body finds out in order. Nothing is added; the blood is simply asked to hurry.'),
    ('marrow_splinter', 'Marrow Splinter', 2, 'attack', 'basic', 416, 0.1000, 0.9200, 1, 'A sliver worked loose from the inside of the bone rather than the outside. There is no bruise to point at afterwards.'),
    ('ossuary_bloom', 'Ossuary Bloom', 4, 'attack', 'basic', 2450, 0.2000, 0.9000, 3, 'Bone grows where bone was never meant to, and grows fast, and grows outward. The shape it takes is roughly a flower.'),
    ('thousand_bone_pagoda', 'Thousand Bone Pagoda', 5, 'attack', 'basic', 6248, 0.2800, 0.8900, 3, 'Every skeleton within reach volunteers a storey. The building goes up around the target, and the target is the foundation.'),
    ('sleepwalker_s_errand', 'Sleepwalker''s Errand', 3, 'attack', 'basic', 646, 0.1500, 0.9700, 2, 'They are sent to do one small thing and they do it. They will remember deciding to.'),
    ('the_long_corridor', 'The Long Corridor', 4, 'attack', 'basic', 1700, 0.2000, 0.9600, 3, 'A hallway with the same door at both ends, walked at the speed of sleep. Waking up is a door too, and it is not on this floor.'),
    ('nightmare_made_tenant', 'Nightmare Made Tenant', 5, 'attack', 'basic', 4335, 0.2800, 0.9500, 3, 'It does not visit. It signs, unpacks, and begins changing the furniture around while the owner is still using it.'),
    ('swallowing_loam', 'Swallowing Loam', 3, 'attack', 'basic', 775, 0.1500, 0.9400, 2, 'The ground goes soft to the ankle, then firm again. Timing is the whole technique.'),
    ('mountain_sits_down', 'Mountain Sits Down', 4, 'attack', 'basic', 2040, 0.2000, 0.9300, 3, 'No landslide, no tremor, no warning worth the name. Simply a great deal of stone deciding to be somewhere lower.'),
    ('collar_of_small_words', 'Collar of Small Words', 2, 'attack', 'basic', 354, 0.1000, 0.9500, 1, 'Nothing that sounds like an order. Six or seven of them and the wearer stops noticing which thoughts arrived from outside.'),
    ('borrowed_hands', 'Borrowed Hands', 3, 'attack', 'basic', 790, 0.1500, 0.9400, 2, 'Their arms do one thing that was not theirs. It is brief, and it is usually enough, and they watch it happen.'),
    ('the_kneeling_hour', 'The Kneeling Hour', 4, 'attack', 'basic', 2080, 0.2000, 0.9300, 3, 'For an hour the body agrees with someone else about what it is for. The mind is left awake to keep it company.'),
    ('ten_thousand_willing', 'Ten Thousand Willing', 5, 'attack', 'basic', 5304, 0.2800, 0.9200, 3, 'Not compulsion - conviction. By the end they would argue the point with anyone who suggested they had been made to.'),
    ('ash_sermon', 'Ash Sermon', 3, 'attack', 'basic', 912, 0.1500, 0.9100, 2, 'The smoke arrives before the flame and says most of it. What burns afterwards is a formality nobody stays to watch.'),
    ('first_bite', 'First Bite', 2, 'attack', 'basic', 283, 0.1000, 0.9800, 1, 'Taken out of whatever is nearest, including the air, including the qi. Small, and the second one is never far behind.'),
    ('gnawing_hunger', 'Gnawing Hunger', 3, 'attack', 'basic', 633, 0.1500, 0.9700, 2, 'Handed over rather than felt. They will eat, and it will not help, and they will keep eating.'),
    ('the_long_table', 'The Long Table', 4, 'attack', 'basic', 1666, 0.2000, 0.9600, 3, 'Everything in the room is laid out as a course. The order of service is decided by whoever set the table.'),
    ('devour_the_offering', 'Devour the Offering', 5, 'attack', 'basic', 4248, 0.2800, 0.9500, 3, 'Whatever they were saving - the reserve, the trump, the last clean breath - is eaten first, and eaten in front of them.'),
    ('nine_stake_snare', 'Nine Stake Snare', 3, 'attack', 'basic', 760, 0.1500, 0.9400, 2, 'Nine points that mean nothing individually. Cross the tenth line and all nine have opinions at once.'),
    ('closing_quarter', 'Closing Quarter', 4, 'attack', 'basic', 2000, 0.2000, 0.9300, 3, 'The ground they can stand on shrinks by a quarter, then by a quarter of that. It is never the whole ground, which is worse.'),
    ('the_board_turns_over', 'The Board Turns Over', 5, 'attack', 'basic', 5100, 0.2800, 0.9200, 3, 'Every stake, every line, every ward changes side simultaneously. The array was always going to belong to somebody.'),
    ('omen_reading', 'Omen Reading', 2, 'attack', 'basic', 347, 0.1000, 0.9500, 1, 'The next few seconds are already written somewhere. Reading them aloud in the right order is enough to bruise.'),
    ('borrowed_mandate', 'Borrowed Mandate', 3, 'attack', 'basic', 775, 0.1500, 0.9400, 2, 'Authority nobody granted, exercised anyway. It works for exactly as long as nothing above thinks to check.'),
    ('the_sky_notices', 'The Sky Notices', 4, 'attack', 'basic', 2040, 0.2000, 0.9300, 3, 'One instant of being genuinely attended to from a great height. Very little survives being important for that long.'),
    ('decree_of_the_distant_throne', 'Decree of the Distant Throne', 5, 'attack', 'basic', 5202, 0.2800, 0.9200, 3, 'A judgement handed down from somewhere that has never seen them and does not need to. There is no court to appeal it in.'),
    ('crowd_sense', 'Crowd Sense', 2, 'attack', 'basic', 301, 0.1000, 0.9800, 1, 'Everything a hundred people would notice about them, noticed at once, by one person standing close.'),
    ('the_weight_of_names', 'The Weight of Names', 4, 'attack', 'basic', 1768, 0.2000, 0.9600, 3, 'Every name they have been called, stacked and handed back. Most cultivators have collected more than they can carry.'),
    ('ten_thousand_faces_judge', 'Ten Thousand Faces Judge', 5, 'attack', 'basic', 4508, 0.2800, 0.9500, 3, 'Not an army - an audience. It turns out that being looked at by enough people is a physical event.'),
    ('rime_shroud', 'Rime Shroud', 3, 'attack', 'basic', 730, 0.1500, 0.9400, 2, 'A coat of frost too thin to see and too even to shrug off. It thickens wherever the body is warmest, which is everywhere.'),
    ('winter_that_does_not_end', 'Winter That Does Not End', 5, 'attack', 'basic', 4896, 0.2800, 0.9200, 3, 'Not a season - a verdict about the season. The cold stops being weather and starts being the local condition of things.'),
    ('borrowed_reflection', 'Borrowed Reflection', 2, 'attack', 'basic', 283, 0.1000, 0.9800, 1, 'It stands where a reflection would, if there were anything to reflect in. They will check. Checking is the cost.'),
    ('the_wrong_door', 'The Wrong Door', 3, 'attack', 'basic', 633, 0.1500, 0.9700, 2, 'Every exit is where they remember, and one of them is not an exit. Nobody checks the ones they are sure about.'),
    ('mirror_court', 'Mirror Court', 4, 'attack', 'basic', 1666, 0.2000, 0.9600, 3, 'Surrounded by versions of themselves, all slightly better informed. Some of them are lying and all of them sound right.'),
    ('dawn_needle', 'Dawn Needle', 2, 'attack', 'basic', 340, 0.1000, 0.9500, 1, 'A single line of morning, drawn through rather than across. It is not warm and it does not spread.'),
    ('refracted_blade', 'Refracted Blade', 3, 'attack', 'basic', 760, 0.1500, 0.9400, 2, 'One edge enters and four leave, at angles the body did not prepare for. The geometry is the injury.'),
    ('noon_without_shade', 'Noon Without Shade', 4, 'attack', 'basic', 2000, 0.2000, 0.9300, 3, 'Light from every direction at once, so nothing has a back. There is no side of them that is not currently being seen.'),
    ('pillar_of_unbroken_day', 'Pillar of Unbroken Day', 5, 'attack', 'basic', 5100, 0.2800, 0.9200, 3, 'A column of morning that does not end, does not move, and does not care what is standing in it.'),
    ('static_lash', 'Static Lash', 2, 'attack', 'basic', 434, 0.1000, 0.9200, 1, 'The hair lifts first, which is the only warning and not enough of one. Short, and it goes where the water is.'),
    ('forked_judgement', 'Forked Judgement', 4, 'attack', 'basic', 2550, 0.2000, 0.9000, 3, 'It divides at the last instant and takes both answers. Neither branch is the merciful one.'),
    ('storm_held_in_the_palm', 'Storm Held in the Palm', 5, 'attack', 'basic', 6502, 0.2800, 0.8900, 3, 'Carried the whole way rather than called down, which is the difficult part. Releasing it is not difficult.'),
    ('loaded_die', 'Loaded Die', 2, 'attack', 'basic', 301, 0.1000, 0.9800, 1, 'Nothing impossible happens. Merely the unlikely, repeatedly, in one direction, for a while.'),
    ('the_coin_lands_wrong', 'The Coin Lands Wrong', 3, 'attack', 'basic', 672, 0.1500, 0.9700, 2, 'Every small thing that could go either way goes the other. A loose stone, a caught sleeve, a breath taken at the wrong moment.'),
    ('borrowed_fortune', 'Borrowed Fortune', 4, 'attack', 'basic', 1768, 0.2000, 0.9600, 3, 'Taken from their next month and spent in the next minute. The loan is real and the repayment is not optional.'),
    ('every_wager_won', 'Every Wager Won', 5, 'attack', 'basic', 4508, 0.2800, 0.9500, 3, 'For a short while nothing that could go badly does. It is not skill and both parties know it, which does not help either.'),
    ('filing_storm', 'Filing Storm', 2, 'attack', 'basic', 408, 0.1000, 0.9200, 1, 'Iron dust with an opinion about direction. Individually each grain is nothing, which is what makes the count unpleasant.'),
    ('whetstone_wind', 'Whetstone Wind', 3, 'attack', 'basic', 912, 0.1500, 0.9100, 2, 'Air that sharpens what it passes and passes through most things. It leaves a very clean edge on the wound.'),
    ('the_whole_armoury_falls', 'The Whole Armoury Falls', 5, 'attack', 'basic', 6120, 0.2800, 0.8900, 3, 'Every blade the technique can reach, and it reaches further than the room. They arrive point first and in order.'),
    ('ink_wash_strike', 'Ink Wash Strike', 2, 'attack', 'basic', 283, 0.1000, 0.9800, 1, 'A stroke laid down in the air and left to run. Where it runs is not up to the person it runs across.'),
    ('painted_beast_steps_out', 'Painted Beast Steps Out', 3, 'attack', 'basic', 633, 0.1500, 0.9700, 2, 'It was two-dimensional a moment ago and remembers being so. That is why its bite has no thickness and goes so deep.'),
    ('landscape_folds_inward', 'Landscape Folds Inward', 4, 'attack', 'basic', 1666, 0.2000, 0.9600, 3, 'The scene closes on itself like a scroll being rolled. Whatever was standing in the foreground is now part of the paper.'),
    ('the_last_brushstroke', 'The Last Brushstroke', 5, 'attack', 'basic', 4248, 0.2800, 0.9500, 3, 'One line added to a finished work, which finishes it differently. The painter decides what the picture was about.'),
    ('seven_days_patience', 'Seven Days'' Patience', 3, 'attack', 'basic', 760, 0.1500, 0.9400, 2, 'Delivered now, argued with later, lost in a week. The technique is finished; the rest is just the calendar.'),
    ('the_well_goes_bad', 'The Well Goes Bad', 4, 'attack', 'basic', 2000, 0.2000, 0.9300, 3, 'Not the body - what the body draws from. Everything they take in from here arrives already spoiled.'),
    ('breath_thief', 'Breath Thief', 2, 'attack', 'basic', 295, 0.1000, 0.9800, 1, 'One cycle taken out of their circulation and not returned. It is a small theft and the accounting is immediate.'),
    ('circulating_lash', 'Circulating Lash', 3, 'attack', 'basic', 659, 0.1500, 0.9700, 2, 'Their own qi, turned one degree off its path and let go. It does the damage; the technique only aimed it.'),
    ('aperture_pressure', 'Aperture Pressure', 4, 'attack', 'basic', 1734, 0.2000, 0.9600, 3, 'Weight applied to the one place a cultivator cannot armour. Nothing enters and nothing needs to.'),
    ('the_sea_turns_over', 'The Sea Turns Over', 5, 'attack', 'basic', 4422, 0.2800, 0.9500, 3, 'Everything they have stored inverts at once, top to bottom. The volume does not change, which is the cruelty of it.'),
    ('crucible_tap', 'Crucible Tap', 2, 'attack', 'basic', 301, 0.1000, 0.9800, 1, 'A short pulse of the heat used to separate things. Applied to somebody who is not made of parts meant to separate.'),
    ('slag_and_silver', 'Slag and Silver', 3, 'attack', 'basic', 672, 0.1500, 0.9700, 2, 'Everything worth keeping is drawn to one side of them and everything else to the other. Both sides then have to travel.'),
    ('reduce_to_essentials', 'Reduce to Essentials', 4, 'attack', 'basic', 1768, 0.2000, 0.9600, 3, 'Whatever is not load-bearing is asked to leave. Rather more of a cultivator is decorative than they would like.'),
    ('what_the_furnace_keeps', 'What the Furnace Keeps', 5, 'attack', 'basic', 4508, 0.2800, 0.9500, 3, 'Everything that can burn does, and the technique looks at what is left, and takes that as well.'),
    ('small_clause', 'Small Clause', 2, 'attack', 'basic', 326, 0.1000, 0.9500, 1, 'One sentence they did not agree to and are now inside. It is narrow, and it is binding, and it is written down somewhere.'),
    ('binding_precedent', 'Binding Precedent', 4, 'attack', 'basic', 1920, 0.2000, 0.9300, 3, 'It happened once, therefore it happens. Nobody has found the authority that would be required to disagree.'),
    ('the_law_as_written', 'The Law As Written', 5, 'attack', 'basic', 4896, 0.2800, 0.9200, 3, 'Not justice, not intent - the text. Read out in full and applied to the letter, which is the whole punishment.'),
    ('umbral_quartering', 'Umbral Quartering', 4, 'attack', 'basic', 1960, 0.2000, 0.9300, 3, 'Their shadow is divided into four and the divisions are honoured. The body is asked to keep up.'),
    ('where_the_light_was', 'Where the Light Was', 5, 'attack', 'basic', 4998, 0.2800, 0.9200, 3, 'It takes the absence rather than the thing, which is a shorter reach and a much older one.'),
    ('thread_pull', 'Thread Pull', 2, 'attack', 'basic', 289, 0.1000, 0.9800, 1, 'One strand, drawn a finger''s width and let go. They feel it in a place they cannot point to.'),
    ('hollowing_whisper', 'Hollowing Whisper', 3, 'attack', 'basic', 646, 0.1500, 0.9700, 2, 'Said quietly and directly into whatever does the listening. It removes rather than adds.'),
    ('the_quiet_room', 'The Quiet Room', 4, 'attack', 'basic', 1700, 0.2000, 0.9600, 3, 'Everything they use to tell inside from outside is turned down at once. What is left is a very small place to be.'),
    ('soul_held_at_arm_s_length', 'Soul Held at Arm''s Length', 5, 'attack', 'basic', 4335, 0.2800, 0.9500, 3, 'Taken out, briefly, and looked at. Returning it is possible and is not part of the technique.'),
    ('folded_approach', 'Folded Approach', 3, 'attack', 'basic', 775, 0.1500, 0.9400, 2, 'The distance closed is not the distance crossed. They defended the ground that was there a moment ago.'),
    ('the_distance_lies', 'The Distance Lies', 4, 'attack', 'basic', 2040, 0.2000, 0.9300, 3, 'Everything is nearer or further than it looks, and it changes which. A step becomes a decision with consequences.'),
    ('two_places_at_once', 'Two Places At Once', 5, 'attack', 'basic', 5202, 0.2800, 0.9200, 3, 'Not speed and not illusion. Both are real, both arrive, and only one of them has to be blocked for the other to land.'),
    ('falling_cinder', 'Falling Cinder', 2, 'attack', 'basic', 442, 0.1000, 0.9200, 1, 'Something small and very far away, arriving. It has been on its way for longer than the fight has lasted.'),
    ('constellation_noose', 'Constellation Noose', 4, 'attack', 'basic', 2600, 0.2000, 0.9000, 3, 'Seven points drawn in the air, joined in an order that matters. The figure closes and so does the space inside it.'),
    ('the_sky_comes_down', 'The Sky Comes Down', 5, 'attack', 'basic', 6630, 0.2800, 0.8900, 3, 'Not one star. The arrangement, the distance and the weight, all brought within arm''s reach and released.'),
    ('mountain_breaking_palm', 'Mountain Breaking Palm', 4, 'attack', 'basic', 2400, 0.2000, 0.9000, 3, 'One open hand, moved a short way, very quickly. The name is not a boast about the hand.'),
    ('nothing_left_standing', 'Nothing Left Standing', 5, 'attack', 'basic', 6120, 0.2800, 0.8900, 3, 'Applied to whatever is holding them up, in the order it is holding them up. There is no technique in the follow-through.'),
    ('third_draw', 'Third Draw', 3, 'attack', 'basic', 931, 0.1500, 0.9100, 2, 'The first two were shown. This one was not, and it comes from the same scabbard, which was supposed to be empty.'),
    ('ten_thousand_edges', 'Ten Thousand Edges', 4, 'attack', 'basic', 2450, 0.2000, 0.9000, 3, 'One blade, moved into every position it could occupy. The target is asked to guard all of them.'),
    ('one_cut_one_ending', 'One Cut, One Ending', 5, 'attack', 'basic', 6248, 0.2800, 0.8900, 3, 'The whole of a sword cultivator''s life arranged into a single stroke. Nothing is held back for a second attempt.'),
    ('light_fingers', 'Light Fingers', 2, 'attack', 'basic', 289, 0.1000, 0.9800, 1, 'Something small, taken while they are attending to something large. They will look for it later and blame the road.'),
    ('take_the_breath', 'Take the Breath', 3, 'attack', 'basic', 646, 0.1500, 0.9700, 2, 'The one in the chest, mid-use. Returning it is not part of the arrangement.'),
    ('rob_the_foundation', 'Rob the Foundation', 4, 'attack', 'basic', 1700, 0.2000, 0.9600, 3, 'Not the technique - what the technique is standing on. They keep the skill and lose the ability to use it.'),
    ('everything_was_always_mine', 'Everything Was Always Mine', 5, 'attack', 'basic', 4335, 0.2800, 0.9500, 3, 'Taken so completely that the taking is retroactive. They struggle to describe having owned it.'),
    ('borrowed_minute', 'Borrowed Minute', 3, 'attack', 'basic', 775, 0.1500, 0.9400, 2, 'Sixty seconds moved from their side of the fight to the other. They are not missing; they are simply spent already.'),
    ('the_hour_runs_backward', 'The Hour Runs Backward', 4, 'attack', 'basic', 2040, 0.2000, 0.9300, 3, 'Whatever they spent the last hour building is unbuilt at the same rate. The wounds arrive in reverse order.'),
    ('debt_collected_in_years', 'Debt Collected in Years', 5, 'attack', 'basic', 5202, 0.2800, 0.9200, 3, 'Not damage - age. It is taken from the end, where it is kept, and there is no arrangement for paying it back.'),
    ('half_shift_rake', 'Half-Shift Rake', 2, 'attack', 'basic', 354, 0.1000, 0.9500, 1, 'One hand becomes something with an opinion about flesh, briefly. It changes back before anyone can name it.'),
    ('wear_the_beast', 'Wear the Beast', 4, 'attack', 'basic', 2080, 0.2000, 0.9300, 3, 'Not becoming it - putting it on. The strength arrives whole and so does everything the strength is used to wanting.'),
    ('nothing_keeps_its_shape', 'Nothing Keeps Its Shape', 5, 'attack', 'basic', 5304, 0.2800, 0.9200, 3, 'Applied outward rather than in. The target''s body is invited to consider alternatives and cannot decline.'),
    ('undertow_grip', 'Undertow Grip', 2, 'attack', 'basic', 326, 0.1000, 0.9500, 1, 'No visible current. Whatever they push against gives, and whatever they stand on is already moving.'),
    ('the_tide_insists', 'The Tide Insists', 4, 'attack', 'basic', 1920, 0.2000, 0.9300, 3, 'It does not strike. It arrives, and continues arriving, and has nowhere else to be.'),
    ('drowning_on_dry_land', 'Drowning on Dry Land', 5, 'attack', 'basic', 4896, 0.2800, 0.9200, 3, 'The water is present in the only place that matters. The ground underfoot stays perfectly dry throughout.'),
    ('cutting_draft', 'Cutting Draft', 2, 'attack', 'basic', 333, 0.1000, 0.9500, 1, 'Thin, cold and moving faster than it should be indoors. It finds the gaps in a stance the way it finds them in a door.'),
    ('hollow_gale', 'Hollow Gale', 3, 'attack', 'basic', 745, 0.1500, 0.9400, 2, 'Wind with the middle taken out of it. Bracing against the edges puts them exactly where the absence is.'),
    ('the_air_refuses', 'The Air Refuses', 5, 'attack', 'basic', 4998, 0.2800, 0.9200, 3, 'It stops being a medium and becomes a party to the fight. Everything they do now has to be argued for.'),
    ('read_the_flinch', 'Read the Flinch', 2, 'attack', 'basic', 289, 0.1000, 0.9800, 1, 'The small correction before the real move. Answering it early is not prophecy, though it is difficult to tell apart.'),
    ('three_moves_ahead', 'Three Moves Ahead', 3, 'attack', 'basic', 646, 0.1500, 0.9700, 2, 'Not their next move - the one after the one they will change to. The strike is waiting when they arrive.'),
    ('the_obvious_answer', 'The Obvious Answer', 4, 'attack', 'basic', 1700, 0.2000, 0.9600, 3, 'There was a simple solution to them the entire time. Finding it is the technique; using it takes no effort at all.'),
    ('nothing_you_do_surprises', 'Nothing You Do Surprises', 5, 'attack', 'basic', 4335, 0.2800, 0.9500, 3, 'Every option they have, considered and answered in advance. They are welcome to try the ones they think are clever.'),
    ('creeping_root', 'Creeping Root', 2, 'attack', 'basic', 347, 0.1000, 0.9500, 1, 'Under the foot, around the ankle, patient. It has been growing since before the technique was cast.'),
    ('strangling_vine', 'Strangling Vine', 3, 'attack', 'basic', 775, 0.1500, 0.9400, 2, 'It does not squeeze quickly. It squeezes without ever stopping, which arrives at the same place by a calmer road.'),
    ('the_forest_closes', 'The Forest Closes', 5, 'attack', 'basic', 5202, 0.2800, 0.9200, 3, 'Everything with roots within a hundred paces takes an interest at once. There was never a path out; there was a gap.');


INSERT INTO technique_paths (technique_id, path_code, weight)
SELECT t.technique_id, v.path_code, 1
FROM (VALUES
    ('crimson_tithe', 'blood'),
    ('boiling_vein_cascade', 'blood'),
    ('marrow_splinter', 'bone'),
    ('ossuary_bloom', 'bone'),
    ('thousand_bone_pagoda', 'bone'),
    ('sleepwalker_s_errand', 'dream'),
    ('the_long_corridor', 'dream'),
    ('nightmare_made_tenant', 'dream'),
    ('swallowing_loam', 'earth'),
    ('mountain_sits_down', 'earth'),
    ('collar_of_small_words', 'enslavement'),
    ('borrowed_hands', 'enslavement'),
    ('the_kneeling_hour', 'enslavement'),
    ('ten_thousand_willing', 'enslavement'),
    ('ash_sermon', 'fire'),
    ('first_bite', 'food'),
    ('gnawing_hunger', 'food'),
    ('the_long_table', 'food'),
    ('devour_the_offering', 'food'),
    ('nine_stake_snare', 'formation'),
    ('closing_quarter', 'formation'),
    ('the_board_turns_over', 'formation'),
    ('omen_reading', 'heaven'),
    ('borrowed_mandate', 'heaven'),
    ('the_sky_notices', 'heaven'),
    ('decree_of_the_distant_throne', 'heaven'),
    ('crowd_sense', 'human'),
    ('the_weight_of_names', 'human'),
    ('ten_thousand_faces_judge', 'human'),
    ('rime_shroud', 'ice'),
    ('winter_that_does_not_end', 'ice'),
    ('borrowed_reflection', 'illusion'),
    ('the_wrong_door', 'illusion'),
    ('mirror_court', 'illusion'),
    ('dawn_needle', 'light'),
    ('refracted_blade', 'light'),
    ('noon_without_shade', 'light'),
    ('pillar_of_unbroken_day', 'light'),
    ('static_lash', 'lightning'),
    ('forked_judgement', 'lightning'),
    ('storm_held_in_the_palm', 'lightning'),
    ('loaded_die', 'luck'),
    ('the_coin_lands_wrong', 'luck'),
    ('borrowed_fortune', 'luck'),
    ('every_wager_won', 'luck'),
    ('filing_storm', 'metal'),
    ('whetstone_wind', 'metal'),
    ('the_whole_armoury_falls', 'metal'),
    ('ink_wash_strike', 'painting'),
    ('painted_beast_steps_out', 'painting'),
    ('landscape_folds_inward', 'painting'),
    ('the_last_brushstroke', 'painting'),
    ('seven_days_patience', 'poison'),
    ('the_well_goes_bad', 'poison'),
    ('breath_thief', 'qi'),
    ('circulating_lash', 'qi'),
    ('aperture_pressure', 'qi'),
    ('the_sea_turns_over', 'qi'),
    ('crucible_tap', 'refinement'),
    ('slag_and_silver', 'refinement'),
    ('reduce_to_essentials', 'refinement'),
    ('what_the_furnace_keeps', 'refinement'),
    ('small_clause', 'rule'),
    ('binding_precedent', 'rule'),
    ('the_law_as_written', 'rule'),
    ('umbral_quartering', 'shadow'),
    ('where_the_light_was', 'shadow'),
    ('thread_pull', 'soul'),
    ('hollowing_whisper', 'soul'),
    ('the_quiet_room', 'soul'),
    ('soul_held_at_arm_s_length', 'soul'),
    ('folded_approach', 'space'),
    ('the_distance_lies', 'space'),
    ('two_places_at_once', 'space'),
    ('falling_cinder', 'star'),
    ('constellation_noose', 'star'),
    ('the_sky_comes_down', 'star'),
    ('mountain_breaking_palm', 'strength'),
    ('nothing_left_standing', 'strength'),
    ('third_draw', 'sword'),
    ('ten_thousand_edges', 'sword'),
    ('one_cut_one_ending', 'sword'),
    ('light_fingers', 'theft'),
    ('take_the_breath', 'theft'),
    ('rob_the_foundation', 'theft'),
    ('everything_was_always_mine', 'theft'),
    ('borrowed_minute', 'time'),
    ('the_hour_runs_backward', 'time'),
    ('debt_collected_in_years', 'time'),
    ('half_shift_rake', 'transformation'),
    ('wear_the_beast', 'transformation'),
    ('nothing_keeps_its_shape', 'transformation'),
    ('undertow_grip', 'water'),
    ('the_tide_insists', 'water'),
    ('drowning_on_dry_land', 'water'),
    ('cutting_draft', 'wind'),
    ('hollow_gale', 'wind'),
    ('the_air_refuses', 'wind'),
    ('read_the_flinch', 'wisdom'),
    ('three_moves_ahead', 'wisdom'),
    ('the_obvious_answer', 'wisdom'),
    ('nothing_you_do_surprises', 'wisdom'),
    ('creeping_root', 'wood'),
    ('strangling_vine', 'wood'),
    ('the_forest_closes', 'wood')
) AS v(code, path_code)
JOIN techniques t ON t.code = v.code;


-- The rule this migration exists to satisfy, stated as a rule rather than as
-- 105 names, so that a 35th Path added later has to answer it too.

DO $$
DECLARE
    thin  TEXT;
    n     INTEGER;
BEGIN
    -- 1. Every Path leads an attack at every rank from 1 to 5.
    SELECT string_agg(gap, ', ' ORDER BY gap) INTO thin
    FROM (
        SELECT p.code || ' r' || r.rank AS gap
        FROM paths p CROSS JOIN generate_series(1, 5) AS r(rank)
        WHERE NOT EXISTS (
            SELECT 1 FROM techniques t
            WHERE t.created_by IS NULL
              AND t.category = 'attack'
              AND t.rank = r.rank
              AND (SELECT tp.path_code FROM technique_paths tp
                   WHERE tp.technique_id = t.technique_id
                   ORDER BY tp.weight DESC, tp.path_code LIMIT 1) = p.code)
    ) holes;

    IF thin IS NOT NULL THEN
        RAISE EXCEPTION 'still no move at: %', thin;
    END IF;

    -- 2. Nothing added here is unlearnable. An 'advanced' technique cannot be
    --    bought at any price, so seeding one with no manual would be a row
    --    that exists and cannot be reached.
    SELECT string_agg(t.name, ', ') INTO thin
    FROM techniques t
    WHERE t.created_by IS NULL AND t.rank BETWEEN 2 AND 5
      AND t.grade = 'advanced'
      AND NOT EXISTS (SELECT 1 FROM manuals m WHERE m.archetype = 'technique'
                      AND EXISTS (SELECT 1 FROM manual_techniques mt
                                  WHERE mt.manual_id = m.manual_id
                                    AND mt.technique_id = t.technique_id));

    IF thin IS NOT NULL THEN
        RAISE EXCEPTION 'advanced and teachable by nothing: %', thin;
    END IF;

    -- 3. Every new technique has exactly one Path, so it is that Path's own
    --    move rather than a junior partner in somebody else's.
    SELECT count(*) INTO n
    FROM techniques t
    WHERE t.created_by IS NULL
      AND t.rank BETWEEN 2 AND 5
      AND (SELECT count(*) FROM technique_paths tp
           WHERE tp.technique_id = t.technique_id) = 0;

    IF n > 0 THEN
        RAISE EXCEPTION '% new techniques belong to no Path', n;
    END IF;

    -- 4. Power still climbs with rank across the whole seeded set. If a new
    --    rank 3 outhits an old rank 4 the ladder has a rung that goes down.
    SELECT string_agg(a.rank || ' overlaps ' || b.rank, ', ') INTO thin
    FROM (SELECT rank, max(base_power) AS hi FROM techniques
          WHERE created_by IS NULL AND category = 'attack' GROUP BY rank) a
    JOIN (SELECT rank, min(base_power) AS lo FROM techniques
          WHERE created_by IS NULL AND category = 'attack' GROUP BY rank) b
      ON b.rank = a.rank + 1
    WHERE a.hi >= b.lo;

    IF thin IS NOT NULL THEN
        RAISE EXCEPTION 'the ladder is not monotonic: %', thin;
    END IF;
END;
$$;


-- And read back through the shelf a real cultivator actually sees, because
-- a technique that exists but never reaches `technique_shelf` is the same
-- problem in a different table.

DO $$
DECLARE
    her    BIGINT;
    picked RECORD;
    before INTEGER;
BEGIN
    SELECT p.player_id INTO her FROM players p
    WHERE p.discord_name LIKE 'm%y%k%' AND p.deleted_at IS NULL;

    IF her IS NULL THEN
        RAISE NOTICE 'no such cultivator; tests carry it';
        RETURN;
    END IF;

    -- The best of the new Heaven rungs she can actually stand on. Her realm
    -- is rank 4, so rank 5 being out of reach is correct and is not what this
    -- is asking - the claim is that the hole between rank 1 and rank 6 is
    -- gone for somebody standing in it.
    SELECT count(*) INTO before
    FROM technique_shelf(her) s
    WHERE s.path_code = 'heaven' AND s.tech_rank BETWEEN 2 AND 5;

    IF before = 0 THEN
        RAISE EXCEPTION 'the new Heaven rungs never reached the shelf';
    END IF;

    SELECT s.name, s.tech_rank, s.base_power, s.ready, s.realm_ok, s.tier_ok
    INTO picked
    FROM technique_shelf(her) s
    WHERE s.path_code = 'heaven' AND s.tech_rank BETWEEN 2 AND 5
      AND s.realm_ok
    ORDER BY s.tech_rank DESC
    LIMIT 1;

    IF picked IS NULL THEN
        RAISE EXCEPTION
            'all % new Heaven rungs are still out of her realm', before;
    END IF;

    -- She holds one Heaven move at 113 power. Anything worth adding beats it.
    IF picked.base_power <= 113 THEN
        RAISE EXCEPTION '% is no better than Fate Tap', picked.name;
    END IF;

    RAISE NOTICE 'she can now reach % (rank %, % power)',
        picked.name, picked.tech_rank, picked.base_power;
END;
$$;
