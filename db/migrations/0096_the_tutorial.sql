-- 0096_the_tutorial
--
-- A guide that cannot go out of date.
--
-- THE NUMBERS ARE NOT WRITTEN DOWN. A tutorial saying "gathering has a twenty
-- minute cooldown" is wrong the first time somebody edits `game_config`, and a
-- guide that lies is worse than no guide - it is the one thing a new player has
-- no way to check. So a page writes `{gather_cooldown_minutes}` and the reader
-- substitutes the live value. There is one source of truth for every number in
-- this game and the tutorial reads it like everything else does.
--
-- THE PAGES ARE ROWS. Fifteen screens of prose in a cog is fifteen screens
-- that need a deploy to fix a typo, and a page per system means a system
-- shipping without one is a missing row rather than a forgotten paragraph.
--
-- AND ONLY SYSTEMS THAT EXIST. The design this is modelled on lists farming,
-- dungeons, sects, pets and PvP - none of which are built here. A tutorial
-- page for an unbuilt system is the worst kind of promise: it teaches somebody
-- a command they cannot run. Twelve pages, one per thing that is actually in
-- the game, and the next one arrives with its feature.
--
-- Forward-only. Do not edit once applied.


CREATE TABLE tutorial_pages (
    code       TEXT PRIMARY KEY,
    title      TEXT NOT NULL,
    emoji      TEXT NOT NULL,

    -- `{game_config_key}` anywhere in here is replaced with the live value.
    body       TEXT NOT NULL,

    sort_order SMALLINT NOT NULL
);

CREATE INDEX tutorial_pages_order_idx ON tutorial_pages (sort_order);

COMMENT ON TABLE tutorial_pages IS
    'The guide, one row per system. Braced game_config keys in `body` are substituted at read time, so the tutorial cannot drift from the numbers it describes.';

CREATE FUNCTION tutorial_text(p_body TEXT)
RETURNS TEXT
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    dial RECORD;
    out  TEXT := p_body;
BEGIN
    -- Every key, rather than the ones a page happens to use: the page is data
    -- and this function has no business knowing which keys are in it.
    FOR dial IN SELECT key, value FROM game_config LOOP
        IF position('{' || dial.key || '}' IN out) > 0 THEN
            out := replace(out, '{' || dial.key || '}',
                           trim_scale(dial.value)::text);
        END IF;
    END LOOP;
    RETURN out;
END;
$$;

COMMENT ON FUNCTION tutorial_text(TEXT) IS
    'Substitutes live game_config values into a tutorial page. A guide that quotes a stale number is worse than one that quotes none.';

CREATE VIEW tutorial AS
SELECT code, title, emoji, sort_order, tutorial_text(body) AS body
FROM tutorial_pages;


INSERT INTO tutorial_pages (code, title, emoji, sort_order, body) VALUES

('start', 'Getting Started', '🧭', 10,
'Welcome. You are a cultivator in the Mortal World, and everything here is a long game.

**1.** **/register** rolls your character. You choose a **Race**, and you are *given* a **Root** and a **Physique** — with free rerolls before you commit.
**2.** Press **Confirm** when you are happy. That locks the character in and hands you a starter manual.
**3.** **/profile** is your sheet. **/cultivation** is your progress.

**Nothing ticks.** Cultivation, health and training accrue from the time that has passed, worked out the moment you look at them — so closing Discord costs you nothing.

*Tip: every command also works as plain text. Type `I profile`, or the short form `I p`. Try `I h` for hunt, `I g` for gather, `I cd` for cooldowns.*'),

('cultivation', 'Cultivation', '🌿', 20,
'Cultivation is the main track, and most of it happens while you are away.

**/cultivation** shows your rate and what is feeding it. Everything adds: your Race, your Root, your Physique, equipped manuals, Gu, and gear are summed — never multiplied together.

**/focus** aims you at one of the 34 Paths. You trade a little raw speed for insight in that Path.

**/meditate** spends {meditate_cooldown_minutes} minutes on one thing: a share of the realm you are crossing, or of the next step on your Path. It is a choice, not a roll.

**Cultivation stops at the next realm''s door.** It does not spill over. **/breakthrough** is what takes the realm — and it pays {jade_per_realm} Spirit Jade every time.'),

('world', 'The World', '🗺️', 30,
'Five regions, each with its own herbs, ore, and beasts.

**/where** — where you stand, what lives here, and how deep the veins go.
**/travel** — a real journey. You arrive when the time has passed, whether or not you are watching.

**/gather** forages what grows. **/mine** works the stone under it. **/explore** looks for what was left lying around.

**One cooldown buys {gather_tries} tries.** Each command opens a set and every try is a button press — walk away and the rest are still there when you come back.

Rogue cultivators interrupt about one action in ten. They are the only thing that carries manual pages.'),

('combat', 'Combat', '⚔️', 40,
'**/hunt** finds something and starts a fight you play a round at a time.

Each round you **Attack**, **Guard**, **Observe** or **Flee**. Attacking costs Qi. Guarding halves the blow and returns some Qi. Observing spends the round to learn what the creature is weak to.

Damage runs through the **Path matchup chart** — the same chart that decides whether two manual pages will refine together. A creature weak to Fire takes a quarter more from a Fire technique; one immune to it takes nothing at all.

**/techniques** lists what there is, **/learn** takes one, **/loadout** orders them. **/bestiary** is what you have learned about what you have fought.

**/rest** closes {rest_heal_min_pct} to {rest_heal_max_pct} of your health, every {rest_cooldown_minutes} minutes.'),

('traits', 'Root, Physique and Race', '🌱', 50,
'Three traits. One you choose, two you are given.

**Race** is chosen. Eleven of them, each leaning toward a different Path.
**Root** is rolled. It carries Path packages, and some carry craft effects.
**Physique** is rolled. It carries the multipliers behind your HP, defence and strength — and, since the bodies were reworked, real effects: evasion, penetration, tolerance for difficult crafting.

**/physique** shows what your body grants and lets you pick a body Path.

**/reroll** buys more chances with Spirit Jade — {reroll_jade_cost} a roll. It shows you the real odds first, and **nothing changes until you accept it**: a batch keeps the best it saw and offers it. Refusing still costs the Jade.'),

('professions', 'Professions', '⚒️', 60,
'Seven crafts, and every one of them levels by doing the work — never by spending anything.

**Forager** — more looks at the ground per gather, keeping the rarest.
**Explorer** — fewer empty searches.
**Miner** — deeper veins, and more out of them.
**Blacksmith** — deeper equipment, more materials on the anvil.
**Alchemist** — a wider cauldron.
**Gu Refiner** — more auxiliary materials on the bench.
**Refiner** — more pages in one refinement.

**/professions** shows all seven, how far the next level is, and exactly what that level will buy.

They level on the *attempt*, not the success. A spoiled cauldron still teaches the shape of the mistake.'),

('crafting', 'Crafting', '🔨', 70,
'Four crafts, and none of them has a recipe list. What goes in decides what comes out.

**/refine** — manual pages into a manual. Pages of one Path refine easily; Paths that fight each other on the chart fight on the page. It shows you a forecast and asks before it spends anything.
**/alchemy** — herbs into pills. The Path with the most weight decides what the pill *does*.
**/forge** — ore and beast materials into equipment. The **metal decides the ceiling**, the beast materials decide what it does.
**/refinegu** — materials into Gu.

Every one of them scores **harmony**: how well the Paths involved agree. High harmony keeps more of what you put in, and can exceed what the tier alone would give.'),

('gear', 'Equipment and Gu', '🛡️', 80,
'**Gear is a percentage.** Everything a forged piece grants is a fraction added to the same stack your Gu, manuals, Race, Root and Physique feed — never multiplied into it.

**/gear** — what you have forged and what you are wearing. Four slots: weapon, armour, helm, boots.
**/gu** — the Gu you hold and what fits in your aperture. Your realm decides how many.
**/equipment** and **/manuals** — the manuals you carry.

Every effect has **one ceiling**, shared across all sources. A body already spending most of an effect''s cap makes gear granting the same thing worth little — which is what makes a rolled body a build decision.'),

('jade', 'Spirit Jade', '💚', 90,
'The one currency, and the only thing here that is money.

It refines into nothing and cultivates nothing. That is deliberate — it is worth what somebody will trade you for it.

**Where it comes from:** **/daily** ({daily_jade_base} rising to {daily_jade_max} on a run), crossing a realm ({jade_per_realm}), the first time you kill a species ({jade_first_kill}), and off rogues.

**What it is for:** protecting a rare material against a failed craft, rerolling a Root or Physique, listing on the auction house — and buying whatever another player will sell.

**/cooldowns** tells you what is ready and what you are waiting on.'),

('trade', 'Trading and the Auction House', '🏦', 100,
'**/trade** is a face-to-face swap. Both sides put things on the table, both sides confirm, then it happens at once.

**/auction** is the board. Everything on it is priced in Spirit Jade.
**/sell** puts something up — materials, equipment, Gu, pills or manual pages.

**Listing costs {auction_listing_fee} Jade and hands the item to the house.** It stops being yours the moment it goes up: a worn piece comes off, an equipped Gu leaves the aperture. Take it back any time — but the fee is not returned.

Nothing here is priced by the game. What a thing is worth is what somebody pays for it.'),

('paths', 'The Paths', '☯️', 110,
'Thirty-four Paths, and they run through everything.

They decide combat damage through the matchup chart. They decide whether two manual pages will refine. They decide what a pill does, what a Gu becomes, and whether a forging holds together.

**/paths** lists them. **/path** reads one, in both directions — what it beats and what beats it.

**Attainment** is how deeply you understand a Path. It rises from focused cultivation and from meditation, and it multiplies damage from techniques of that Path.

Paths that oppose each other are worth knowing before you put them in the same crucible.'),

('waiting', 'Waiting Well', '⏰', 120,
'This game is built to be left alone.

Nothing ticks in the background. Cultivation, physique training, Path insight and health are all worked out from the time that has passed, the moment something asks — so a week away accrues exactly what a week should, up to a cap of {passive_cap_hours} hours.

**/cooldowns** shows every timed action at once and what is still running.

The things worth doing when you sit down: take **/daily**, spend your gathering sets, **/meditate** if the hour is up, and check whether **/breakthrough** is open. Everything else keeps.');
