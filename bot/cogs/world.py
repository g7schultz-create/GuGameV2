"""The world: /where, /travel, /gather, /mine, /hunt, /inventory.

Travel is a claim on a span of time, like everything else with a duration in
this game: departure is recorded, arrival is computed when somebody looks. So
`arrive()` runs at the top of every command here rather than on a schedule -
there is nothing to fall behind, and closing Discord mid-journey still gets you
there.

Gathering, mining and hunting are the three ways to fill an inventory, and they
are deliberately disjoint: the ground yields herbs, the stone under it yields
ore, a creature yields fang and hide. A region that handed out fangs for
foraging would make hunting pointless.
"""

import discord
import psycopg
from discord import app_commands
from discord.ext import commands

from bot import database as db
from bot.battle import open_battle
from bot.character import RARITY_MARK
from bot.formatting import (
    COLOUR_BAD,
    COLOUR_DEFAULT,
    COLOUR_GOOD,
    COLOUR_INFO,
    bar,
    embed,
    humanise_duration,
    thousands,
)
from bot.picking import add_page_buttons, page_note
from bot.views import AnsweringView
from bot.players import GameError, require_player, settle_passive

PICKER_TIMEOUT = 180

# Named escapes cannot appear inside an f-string expression, so these are
# constants rather than inline literals.
SKULL = "💀"
BLADES = "\N{CROSSED SWORDS}"
TIMES = "\N{MULTIPLICATION SIGN}"
RICH = "\N{SPARKLES}"


async def locate(player_id: int) -> dict:
    """Land any due journey, then say where the player is.

    Arrival first, always. Every command in this file is about a place, and
    answering with the place they left is worse than being slow.
    """
    await db.execute("SELECT arrive(%s)", (player_id,))
    row = await db.fetch_one(
        """
        SELECT l.region_code, l.travelling_to, l.departed_at, l.arrives_at,
               r.name AS region_name, r.emoji, r.danger_level, r.description,
               dest.name AS destination_name, dest.emoji AS destination_emoji,
               EXTRACT(EPOCH FROM (l.arrives_at - now()))   AS seconds_left,
               EXTRACT(EPOCH FROM (l.arrives_at - l.departed_at)) AS seconds_total
        FROM player_location l
        JOIN regions r ON r.code = l.region_code
        LEFT JOIN regions dest ON dest.code = l.travelling_to
        WHERE l.player_id = %s
        """,
        (player_id,),
    )
    if row is None:
        raise GameError("You are nowhere. That should not happen — try **/register**.")
    return row


def travelling_error(where: dict) -> GameError:
    """Only /travel still refuses: you cannot start a second journey.

    Gathering, mining, exploring and hunting used to refuse too, which made a
    six-hour road six hours of nothing. The world does not stop because you
    are crossing it - a cultivator walking out of the Central Continent is
    still in the Central Continent, and the country does not empty because
    they have somewhere to be.
    """
    return GameError(
        f"You are on the road to **{where['destination_name']}** — "
        f"{humanise_duration(float(where['seconds_left']))} still to go. "
        "**/where** to check the journey."
    )


def road_note(where: dict) -> str:
    """What a screen says when the work is being done in transit.

    It has to name the region the tables came from. A player pulling Central
    herbs while walking to the Western Desert has otherwise been handed a list
    that does not match where they think they are.
    """
    if not where["travelling_to"]:
        return ""
    return (
        f"\N{COMPASS} *On the road to **{where['destination_name']}**, "
        f"{humanise_duration(float(where['seconds_left']))} still to go \N{EM DASH} "
        f"so this is still {where['region_name']}.*"
    )


async def claim(player_id: int, action: str, config_key: str) -> None:
    """Take a cooldown or explain when it is free."""
    row = await db.fetch_one(
        "SELECT * FROM claim_cooldown(%s, %s, game_config_value(%s))",
        (player_id, action, config_key),
    )
    if not row["claimed"]:
        raise GameError(
            f"Not yet — you can {action} again "
            f"{discord.utils.format_dt(row['ready_at'], style='R')}."
        )


async def pick_technique(player_id: int) -> dict | None:
    """The move this player would fight with.

    Loadout order first, then raw power, over everything usable - learned or
    unlocked by an equipped manual. One definition, so a hunt and an ambush
    never disagree about what you are holding.
    """
    return await db.fetch_one(
        """
        SELECT t.technique_id, t.name, t.code, u.source
        FROM player_usable_techniques u
        JOIN techniques t ON t.technique_id = u.technique_id
        LEFT JOIN player_loadout l
            ON l.player_id = u.player_id AND l.technique_id = u.technique_id
        -- An ATTACK, said outright. This used to read `base_power > 0`,
        -- which happened to mean the same thing and stopped meaning it the
        -- moment anything else was asked of the column. The auto-swing on a
        -- hunt should never come up a healing technique.
        WHERE u.player_id = %s AND t.category = 'attack'
        -- By what the move is worth TODAY. Ordering on the stored figure made
        -- this pick the wrong technique for anybody holding a forged one, and
        -- this is the function that swings for you on a hunt - so it was a
        -- worse bug here than on any screen. Kept in step with
        -- `usable_techniques`, which orders the same way for the same reason.
        ORDER BY l.slot_index NULLS LAST,
                 technique_power_for(u.player_id, t.technique_id) DESC
        LIMIT 1
        """,
        (player_id,),
    )


async def check_ambush(player_id: int, region: str) -> dict | None:
    """A rogue cultivator interrupting what you meant to do.

    Rogues are `creature_species` rows with kind 'rogue', so the fight that
    follows is the same hunt() every other enemy goes through - there is no
    second combat path to keep in step.

    The player goes in because 0198 draws a rogue near their own rank, and a
    rogue's rank is what decides the tier of the pages they were carrying.
    Without it a Nascent Soul cultivator kept being ambushed by rank 1 herb
    thieves and going home with tier 1 pages.

    Since 0359 a rogue in either heaven is an immortal, and the rank that
    describes one is not its bestiary rank - every creature in a heaven is rank
    9 - but the realm it stands at. `standing` is that realm's name without the
    stage suffix, so the card can say Dewberry Immortal rather than Rank 9.
    """
    species_id = await db.fetch_value(
        "SELECT spawn_rogue(%s, %s)", (region, player_id)
    )
    if species_id is None:
        return None
    return await db.fetch_one(
        "SELECT s.species_id, s.code, s.name, s.rank, s.immortal_rank, "
        "s.base_hp, s.base_attack, s.base_defense, s.description, "
        "(SELECT btrim(split_part(r.name, '—', 1)) FROM realms r "
        " WHERE r.rank = s.immortal_rank LIMIT 1) AS standing "
        "FROM creature_species s WHERE s.species_id = %s",
        (species_id,),
    )


class World(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    # -----------------------------------------------------------------------

    @app_commands.command(description="Where you are, and what is around you.")
    async def where(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])
        here = await locate(player["player_id"])

        if here["travelling_to"]:
            left = float(here["seconds_left"])
            total = float(here["seconds_total"])
            card = embed(
                f"{here['destination_emoji']} On the road",
                f"**{here['region_name']}** → **{here['destination_name']}**",
                colour=COLOUR_INFO,
            )
            card.add_field(
                name="Progress",
                value=(
                    f"{bar(int(total - left), int(total), width=18)}\n"
                    f"Arriving {discord.utils.format_dt(here['arrives_at'], style='R')}"
                ),
                inline=False,
            )
            card.set_footer(text="You cannot gather or hunt while travelling.")
            await interaction.response.send_message(embed=card)
            return

        creatures = await db.fetch_all(
            """
            SELECT s.name, s.rank, s.kind
            FROM creature_regions cr
            JOIN creature_species s ON s.species_id = cr.species_id
            WHERE cr.region_code = %s AND s.kind <> 'rogue'
            ORDER BY s.rank, s.name
            """,
            (here["region_code"],),
        )
        materials = await db.fetch_value(
            "SELECT count(*) FROM region_materials WHERE region_code = %s",
            (here["region_code"],),
        )
        # How deep the stone goes here, against how deep this player can work
        # it. A miner deciding where to stand is deciding between those two.
        seams = await db.fetch_one(
            """
            SELECT count(*) AS veins, COALESCE(max(o.tier), 0) AS deepest,
                   mining_tier_cap(profession_level(%s, 'mining')) AS reach
            FROM region_veins rv
            JOIN ores o ON o.material_code = rv.material_code
            WHERE rv.region_code = %s
            """,
            (player["player_id"], here["region_code"]),
        )

        card = embed(
            f"{here['emoji']} {here['region_name']}",
            here["description"],
            colour=COLOUR_DEFAULT,
        )
        card.add_field(name="Danger", value=SKULL * here["danger_level"])
        card.add_field(name="Gatherable", value=f"{materials} materials")
        card.add_field(name="Wildlife", value=f"{len(creatures)} species")
        card.add_field(
            name="Veins",
            value=f"{seams['veins']} \N{BULLET} down to tier {seams['deepest']}\n"
            f"*you reach tier {min(seams['reach'], seams['deepest'])}*",
        )
        card.add_field(
            name="What lives here",
            value="\n".join(
                f"`{c['rank']}` **{c['name']}**"
                + ("" if c["kind"] == "beast" else f" — *{c['kind']}*")
                for c in creatures
            )
            or "Nothing worth hunting.",
            inline=False,
        )
        card.set_footer(
            text="/gather to forage · /mine to work the veins · /hunt to fight · /travel to leave"
        )
        await interaction.response.send_message(embed=card)

    # -----------------------------------------------------------------------

    @app_commands.command(description="Travel to another region. Takes real time.")
    async def travel(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])
        here = await locate(player["player_id"])

        if here["travelling_to"]:
            raise travelling_error(here)

        # Distances are read from here, so each button can say what it costs
        # before it is pressed.
        destinations = await db.fetch_all(
            """
            SELECT r.code, r.name, r.emoji, r.danger_level, r.min_rank,
                   travel_hours(%(from)s, r.code) AS hours,
                   -- STANDING, not realm. `realms` stops at rank 18 and a
                   -- Venerable never leaves realm_id 71, so this read answered
                   -- 18 for somebody standing at 19 and showed The Heavenly
                   -- Court as shut to the only people it is open to.
                   -- `begin_travel` has read `player_standing` since 0519; the
                   -- screen in front of it did not, so the door worked and the
                   -- button to use it was greyed out.
                   COALESCE(player_standing(%(me)s), 1) >= r.min_rank
                       AS open_to_you,
                   -- And the same table cannot name what a rank 19 region
                   -- wants, for the same reason: no row in `realms` has that
                   -- rank, so `wants` came back NULL and the refusal said
                   -- nothing at all.
                   COALESCE(
                       (SELECT min(rr.name) FROM realms rr
                        WHERE rr.rank = r.min_rank),
                       (SELECT min(v.name) FROM venerable_ranks v
                        WHERE v.rank = r.min_rank)
                   ) AS wants
            FROM regions r
            WHERE r.code <> %(from)s
            ORDER BY travel_hours(%(from)s, r.code), r.sort_order
            """,
            {"from": here["region_code"], "me": player["player_id"]},
        )

        view = TravelPicker(player["player_id"], interaction.user, here, destinations)
        await interaction.response.send_message(embed=view.prompt(), view=view)

    # -----------------------------------------------------------------------

    @app_commands.command(description="Forage the region for refining materials.")
    async def gather(self, interaction: discord.Interaction) -> None:
        await self.open_seam(interaction, SEAMS["gather"])

    # -----------------------------------------------------------------------

    @app_commands.command(description="Work the veins under the region for ore.")
    async def mine(self, interaction: discord.Interaction) -> None:
        await self.open_seam(interaction, SEAMS["mine"])

    # -----------------------------------------------------------------------

    @app_commands.command(description="Search the region for whatever was left lying around.")
    async def explore(self, interaction: discord.Interaction) -> None:
        await self.open_seam(interaction, SEAMS["explore"])

    # -----------------------------------------------------------------------

    async def open_seam(self, interaction: discord.Interaction, seam: "Seam") -> None:
        """Open a set of tries, or hand back the set already open.

        The three world actions are one screen because they are one idea: a
        cooldown buys five tries and each one is a button. Three copies of that
        screen would be three places for the tally to drift.
        """
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])
        here = await locate(player["player_id"])

        began = await db.fetch_one(
            "SELECT * FROM begin_action(%s, %s, %s, %s)",
            (player["player_id"], seam.action, seam.cooldown_key, seam.tries_key),
        )
        if began["tries_left"] == 0:
            raise GameError(
                f"Not yet \u2014 you can {seam.action} again "
                f"{discord.utils.format_dt(began['ready_at'], style='R')}."
            )

        view = SeamView(
            player["player_id"], interaction.user, seam, here,
            began["tries_left"], resumed=began["resumed"],
        )
        await interaction.response.send_message(embed=view.render(), view=view)
        view.message = await interaction.original_response()

    # -----------------------------------------------------------------------

    @app_commands.command(description="Hunt whatever is moving in this region.")
    async def hunt(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])
        here = await locate(player["player_id"])

        body = await db.fetch_one(
            "SELECT current_hp, max_hp FROM player_physique WHERE player_id = %s",
            (player["player_id"],),
        )
        if body["current_hp"] <= 0:
            raise GameError(
                "You have nothing left to fight with. HP returns on its own — "
                "**/cultivation** to see how fast."
            )

        # Everything usable: learned, plus whatever the equipped manuals
        # unlock. Loadout order first, then raw power - making a player equip
        # before their first fight is a chore that teaches nothing.
        technique = await pick_technique(player["player_id"])
        if technique is None:
            raise GameError(
                "You know no technique that could hurt anything. "
                "**/techniques** to see what there is, then **/learn** one — "
                "or equip a manual that teaches one."
            )

        # Claimed after the refusals, so a hunt that could not happen does not
        # cost the five minutes. hunt_cooldown_minutes has sat in game_config
        # since 0017 with nothing reading it: a menu you could reopen forever
        # had no use for one, and a command that resolves a fight does.
        await claim(player["player_id"], "hunt", "hunt_cooldown_minutes")

        # Whatever the fight turns out to be, it happens in the country you
        # are still crossing - so both cards say so rather than leaving a
        # player to wonder why the Western Desert is full of Central beasts.
        road = road_note(here)

        rogue = await check_ambush(player["player_id"], here["region_code"])
        if rogue is not None:
            card, fight = await build_ambush(
                player["player_id"], interaction.user, here, rogue,
                "tracking something else",
            )
            if road:
                card.description = f"{road}\n\n{card.description or ''}".strip()
            await interaction.response.send_message(
                embed=card,
                view=fight if fight is not None else discord.utils.MISSING,
            )
            return

        # You do not choose what you run into. `creature_regions.weight` is
        # already "how often this turns up here", so the draw is the same
        # weighted sample gathering uses and a rare beast stays rare. Choosing
        # your quarry comes back later as its own command.
        # Which beast turns up is `spawn_beast`, not a bare weighted draw.
        # Beasts run rank 1 to 9 since 0314, and the draw that used to sit
        # here read `creature_regions.weight` alone - so a Qi Condensation
        # cultivator could be shown a Primordial Dragon Whale and, because
        # `player_active_battle` is one-per-player, be stuck in front of it.
        # That is the Leviathan incident the old comment here recorded, and
        # adding ranks 3 to 9 would have reproduced it exactly.
        #
        # `spawn_beast` draws near the hunter's own rank the same way
        # `spawn_rogue` has drawn ambushes since 0198: region weight still
        # decides WHICH beast of a rank, a falloff decides how far down it
        # reaches, and one rank above is allowed and rare.
        quarry = await db.fetch_one(
            """
            -- MATERIALIZED is load-bearing. `spawn_beast` is VOLATILE, so
            -- as a bare `WHERE s.species_id = spawn_beast(...)` Postgres is
            -- free to call it once PER ROW of creature_species - comparing
            -- every row against a fresh random draw, so usually nothing
            -- matches at all and the hunt reports "nothing hunts here" in a
            -- region holding eleven beasts. Drawing once in a materialised
            -- CTE and joining to that is the fix.
            WITH drawn AS MATERIALIZED (
                SELECT spawn_beast(%s, %s) AS species_id
            )
            SELECT s.species_id, s.code, s.name, s.rank,
                   s.base_hp, s.base_attack, s.base_defense
            FROM drawn d
            JOIN creature_species s ON s.species_id = d.species_id
            """,
            (here["region_code"], player["player_id"]),
        )
        if quarry is None:
            raise GameError(f"Nothing hunts in {here['region_name']}.")

        # From here the fight is the player's to play, a round at a time. The
        # battle is a row in `battles`, so this view is a window onto it rather
        # than the fight itself.
        card, view = await open_battle(
            player["player_id"], interaction.user,
            quarry["species_id"], here["region_code"],
        )
        if road:
            card.description = f"{road}\n\n{card.description or ''}".strip()
        await interaction.response.send_message(embed=card, view=view)
        view.message = await interaction.original_response()

    # -----------------------------------------------------------------------

    @app_commands.command(
        description="Your Spirit Stones, Jade, keys, and how much else you carry."
    )
    async def balance(self, interaction: discord.Interaction) -> None:
        """The one-line answer to "can I afford this".

        `/inventory` is for looking through a satchel; this is for glancing at
        it. The shelf split is the same derivation, read from the same place,
        because two screens disagreeing about what counts as ore is exactly the
        sort of thing nobody notices until they are arguing with a recipe.
        """
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])

        shelves = await db.fetch_all(
            """
            SELECT CASE
                       WHEN o.material_code IS NOT NULL THEN 'ore'
                       WHEN m.tier IS NOT NULL           THEN 'herb'
                       ELSE m.category
                   END AS shelf,
                   count(*)          AS kinds,
                   sum(pm.quantity)  AS items
            FROM player_materials pm
            JOIN materials m ON m.code = pm.material_code
            LEFT JOIN ores o ON o.material_code = pm.material_code
            WHERE pm.player_id = %s
              AND pm.quantity > 0
              AND m.category <> 'currency'
            GROUP BY 1
            """,
            (player["player_id"],),
        )
        held = {row["shelf"]: row for row in shelves}

        purse = await db.fetch_one(
            """
            SELECT jade_held(%s) AS jade,
                   COALESCE((SELECT pm.quantity FROM player_materials pm
                             WHERE pm.player_id = %s
                               AND pm.material_code = 'spirit_stone'), 0) AS stones,
                   COALESCE((SELECT pm.quantity FROM player_materials pm
                             WHERE pm.player_id = %s
                               AND pm.material_code = 'dungeon_key'), 0) AS keys,
                   game_config_value('daily_dungeon_keys') AS keys_daily
            """,
            (player["player_id"], player["player_id"], player["player_id"]),
        )

        # Three currencies, and the third one is a clock as much as a count:
        # keys come with the daily and nowhere else, so a zero is worth saying
        # rather than leaving out.
        card = embed(
            "\N{MONEY BAG} Balance",
            f"\N{LARGE BLUE DIAMOND} **{thousands(purse['stones'])}** Spirit Stones\n"
            f"\N{GREEN HEART} **{thousands(purse['jade'])}** Spirit Jade\n"
            f"\N{OLD KEY} **{thousands(purse['keys'])}** Dungeon Key"
            + ("" if purse["keys"] == 1 else "s")
            + f" \N{EM DASH} {purse['keys_daily']:g} more with **/daily**",
            colour=COLOUR_DEFAULT,
        )

        # Every shelf, including the empty ones - "no herbs at all" is the
        # answer to a question somebody is asking, and a missing line is not.
        card.add_field(
            name="Materials",
            value="\n".join(
                f"{glyph} **{label}** \N{EM DASH} "
                + (
                    f"{thousands(held[code]['kinds'])} kind(s), "
                    f"{thousands(held[code]['items'])} item(s)"
                    if code in held
                    else "*none*"
                )
                for code, glyph, label, _ in SHELVES
            ),
            inline=False,
        )

        kinds = sum(row["kinds"] for row in shelves)
        items = sum(row["items"] for row in shelves)
        card.set_footer(
            text=f"{thousands(kinds)} kind(s) and {thousands(items)} item(s) in "
            "all \N{EM DASH} /inventory to look through them."
        )
        await interaction.response.send_message(embed=card)

    # -----------------------------------------------------------------------

    @app_commands.command(description="What you are carrying.")
    @app_commands.describe(category="Narrow to one kind of material.")
    @app_commands.choices(
        category=[
            app_commands.Choice(name="Gathering (for Gu refinement)", value="gathering"),
            app_commands.Choice(name="Herbs (for alchemy)", value="herb"),
            app_commands.Choice(name="Ore (for forging)", value="ore"),
            app_commands.Choice(name="Beast (for physique and forging)", value="beast"),
        ]
    )
    async def inventory(
        self,
        interaction: discord.Interaction,
        category: app_commands.Choice[str] | None = None,
    ) -> None:
        player = await require_player(interaction.user)
        # Four shelves out of two categories. Herbs and ore are both
        # `gathering` in the schema and belong to different crafts entirely, so
        # the shelf is derived here rather than being a third category - which
        # would mean editing `gather()`, `region_materials` and every consumer
        # of the split 0017 drew.
        rows = await db.fetch_all(
            """
            WITH held AS (
                SELECT m.name, m.emoji, m.rarity, pm.quantity, ra.sort_order,
                       CASE
                           WHEN o.material_code IS NOT NULL THEN 'ore'
                           WHEN m.tier IS NOT NULL           THEN 'herb'
                           ELSE m.category
                       END AS shelf
                FROM player_materials pm
                JOIN materials m ON m.code = pm.material_code
                JOIN rarities ra ON ra.code = m.rarity
                LEFT JOIN ores o ON o.material_code = pm.material_code
                WHERE pm.player_id = %s AND pm.quantity > 0
            )
            SELECT * FROM held
            WHERE %s::text IS NULL OR shelf = %s
            ORDER BY shelf, sort_order DESC, name
            """,
            (player["player_id"], category.value if category else None,
             category.value if category else None),
        )

        if not rows:
            raise GameError(
                "You are carrying nothing. **/gather**, **/mine** or **/hunt**."
            )

        purse = await db.fetch_value(
            "SELECT jade_held(%s)", (player["player_id"],)
        )
        screen = Satchel(
            interaction.user, rows, purse,
            opened=category.value if category else None,
        )
        await interaction.response.send_message(embed=screen.card(), view=screen)




# ---------------------------------------------------------------------------
# The satchel
# ---------------------------------------------------------------------------
# Four shelves in one embed was four shelves nobody could read. A field holds
# 1024 characters, which is about twenty-two lines of "mark emoji Name x qty",
# so the old screen cut each shelf at twenty and printed a bare ellipsis - a
# player carrying thirty ores saw twenty of them, had no way to reach the rest,
# and was not even told how many were missing.
#
# One shelf at a time, paged, with each shelf button carrying its own count so
# the screen still says where everything is while showing one pile of it.

SHELVES = (
    ("ore", "\N{PICK}", "Ore", "for forging"),
    ("herb", "\N{HERB}", "Herbs", "for alchemy"),
    ("gathering", "\N{FOUR LEAF CLOVER}", "Gathering", "for Gu refinement"),
    ("beast", "\N{PAW PRINTS}", "Beast", "for physique and forging"),
)

# Fifteen entries sits well inside an embed description and leaves room for the
# longest material name in the game.
SATCHEL_PER_PAGE = 15


class ShelfButton(discord.ui.Button):
    """Switch shelves. It carries its own count, so the button is the index."""

    def __init__(
        self, screen: "Satchel", code: str, glyph: str, label: str, held: int
    ) -> None:
        self.screen = screen
        self.code = code
        super().__init__(
            label=f"{label} ({held})",
            emoji=glyph,
            row=0,
            style=(
                discord.ButtonStyle.primary
                if code == screen.shelf
                else discord.ButtonStyle.secondary
            ),
            disabled=held == 0,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        self.screen.shelf = self.code
        self.screen.page = 0
        self.screen.build()
        await interaction.response.edit_message(
            embed=self.screen.card(), view=self.screen
        )


class Satchel(AnsweringView):
    def __init__(
        self,
        user: discord.abc.User,
        rows: list[dict],
        purse: int,
        *,
        opened: str | None = None,
    ) -> None:
        super().__init__(timeout=PICKER_TIMEOUT)
        self.user = user
        self.rows = rows
        self.purse = purse
        # Whichever shelf was asked for, else the first one with anything on
        # it. Opening on an empty Ore shelf when the satchel is full of herbs
        # makes the player press a button to be told what could have been shown.
        self.shelf = opened or next(
            (code for code, *_ in SHELVES if self.held(code)), SHELVES[0][0]
        )
        self.page = 0
        self.build()

    def held(self, code: str) -> int:
        return sum(1 for r in self.rows if r["shelf"] == code)

    def shelf_rows(self) -> list[dict]:
        return [r for r in self.rows if r["shelf"] == self.shelf]

    def page_count(self) -> int:
        return max(1, -(-len(self.shelf_rows()) // SATCHEL_PER_PAGE))

    def build(self) -> None:
        self.clear_items()
        for code, glyph, label, _ in SHELVES:
            self.add_item(ShelfButton(self, code, glyph, label, self.held(code)))
        add_page_buttons(self, row=1)

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "That is not your satchel.", ephemeral=True
            )
            return False
        return True

    def card(self) -> discord.Embed:
        _, glyph, label, purpose = next(
            row for row in SHELVES if row[0] == self.shelf
        )
        mine = self.shelf_rows()
        page = self.page % self.page_count()
        here = mine[page * SATCHEL_PER_PAGE:(page + 1) * SATCHEL_PER_PAGE]

        card = embed(
            f"{glyph} {label} — {purpose}",
            "\n".join(
                f"{RARITY_MARK.get(r['rarity'], '')} {r['emoji']} "
                f"**{r['name']}** ×{thousands(r['quantity'])}"
                for r in here
            )
            or "*Nothing on this shelf.*",
            colour=COLOUR_DEFAULT,
        )
        card.add_field(
            name="\N{GREEN HEART} Spirit Jade",
            value=f"**{thousands(self.purse)}** — refines into nothing, "
            "and everyone takes it.",
            inline=False,
        )
        note = page_note(mine, self.page, "kinds", SATCHEL_PER_PAGE)
        card.set_footer(
            text=(f"{note}  •  " if note else "")
            + f"{len(self.rows)} kinds carried in all"
        )
        return card


# ---------------------------------------------------------------------------
# Pickers
# ---------------------------------------------------------------------------


class OwnedView(AnsweringView):
    """A view only its owner may press."""

    def __init__(self, player_id: int, user: discord.abc.User) -> None:
        super().__init__(timeout=PICKER_TIMEOUT)
        self.player_id = player_id
        self.user = user

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "That is not yours to press. Run the command yourself.", ephemeral=True
            )
            return False
        return True

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True


class DestinationButton(discord.ui.Button):
    def __init__(self, view: "TravelPicker", region: dict) -> None:
        self.picker = view
        self.region = region
        # A shut door is shown and disabled rather than hidden. A region the
        # player cannot see is a region they never learn to want; `begin_travel`
        # refuses it anyway, so this is about the screen telling the truth.
        shut = not region.get("open_to_you", True)
        super().__init__(
            label=f"{region['name']} · {float(region['hours']):.0f}h",
            emoji="🔒" if shut else region["emoji"],
            style=discord.ButtonStyle.secondary,
            disabled=shut,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        try:
            journey = await db.fetch_one(
                "SELECT * FROM begin_travel(%s, %s)",
                (self.picker.player_id, self.region["code"]),
            )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0]) from exc

        for item in self.picker.children:
            item.disabled = True

        card = embed(
            f"{self.region['emoji']} Setting out for {self.region['name']}",
            f"{humanise_duration(float(journey['hours']) * 3600)} on the road.",
            colour=COLOUR_GOOD,
        )
        card.add_field(
            name="Arriving",
            value=discord.utils.format_dt(journey["arrives_at"], style="R"),
        )
        card.set_footer(
            text="You arrive on your own — nothing needs to be running. "
            "/where to check the journey."
        )
        await interaction.response.edit_message(embed=card, view=self.picker)
        self.picker.stop()


class TravelPicker(OwnedView):
    def __init__(self, player_id, user, here: dict, destinations: list[dict]) -> None:
        super().__init__(player_id, user)
        self.here = here
        self.destinations = destinations
        for region in destinations:
            self.add_item(DestinationButton(self, region))

    def prompt(self) -> discord.Embed:
        card = embed(
            "Where to?",
            f"You are in {self.here['emoji']} **{self.here['region_name']}**. "
            "Travel takes real time — the far side of the world is a long walk.",
            colour=COLOUR_INFO,
        )
        card.add_field(
            name="Routes from here",
            value="\n".join(
                f"{r['emoji']} **{r['name']}** — {humanise_duration(float(r['hours']) * 3600)}"
                f"  ·  {SKULL * r['danger_level']}"
                + ("" if r.get("open_to_you", True)
                   else "\n\N{LOCK} *Closed — it takes "
                        f"{r['wants']} to cross.*")
                for r in self.destinations
            ),
            inline=False,
        )
        return card


class FightButton(discord.ui.Button):
    """A rogue is a creature_species row, so the fight they start is the same
    battle a hunt starts. Only what falls off the body differs."""

    def __init__(self, view: "AmbushView") -> None:
        self.ambush = view
        super().__init__(label="Fight", style=discord.ButtonStyle.danger)

    async def callback(self, interaction: discord.Interaction) -> None:
        card, battle = await open_battle(
            self.ambush.player_id, self.ambush.user,
            self.ambush.rogue["species_id"], self.ambush.here["region_code"],
        )
        for item in self.ambush.children:
            item.disabled = True
        await interaction.response.edit_message(embed=card, view=battle)
        battle.message = await interaction.original_response()
        self.ambush.stop()

class AmbushView(OwnedView):
    def __init__(self, player_id, user, here, rogue, technique, body) -> None:
        super().__init__(player_id, user)
        self.here = here
        self.rogue = rogue
        self.technique = technique
        self.body = body
        self.add_item(FightButton(self))


# ---------------------------------------------------------------------------
# Working a seam
# ---------------------------------------------------------------------------


async def build_ambush(player_id: int, user, here: dict, rogue: dict, during: str):
    """The card for a fight nobody asked for, and the view to take it.

    Built rather than sent, because a rogue can now interrupt the third try of
    five - and the screen that has to go on showing the other two is not the
    one carrying the fight.
    """
    body = await db.fetch_one(
        "SELECT current_hp, max_hp FROM player_physique WHERE player_id = %s",
        (player_id,),
    )
    technique = await pick_technique(player_id)

    card = embed(
        f"{BLADES} {rogue['name']}",
        f"You are {during} when someone steps out of the treeline.\n\n"
        f"*{rogue['description']}*",
        colour=COLOUR_BAD,
    )
    # An immortal is named by the realm they stand at. Saying 'Rank 9' of a
    # Yellow Apricot would be true of the bestiary and useless to the player,
    # who is deciding whether this is a fight they can take.
    standing = rogue.get("standing") or f"Rank {rogue['rank']}"

    card.add_field(
        name="Them",
        value=f"{standing} \N{BULLET} {thousands(rogue['base_hp'])} HP "
        f"\N{BULLET} {thousands(rogue['base_attack'])} attack",
    )
    card.add_field(
        name="You",
        value=f"{thousands(body['current_hp'])} / {thousands(body['max_hp'])} HP"
        + (f"\n{technique['name']}" if technique else "\nno technique"),
    )
    card.set_footer(
        text="Rogue immortals carry the essence they climbed on."
        if rogue.get("immortal_rank")
        else "Rogue cultivators carry manual pages. Nothing else does."
    )

    if technique is None or body["current_hp"] <= 0:
        card.add_field(
            name="You cannot fight",
            value="They take what you were carrying and leave. "
            "**/learn** a technique, or wait for your HP.",
            inline=False,
        )
        return card, None

    return card, AmbushView(player_id, user, here, rogue, technique, body)


# One try at each of the three. Each returns the line the tally will show, so
# the screen never has to know which of them it is running.


async def one_gather(player_id: int) -> dict:
    got = await db.fetch_one(
        """
        SELECT g.*, m.emoji
        FROM gather(%s) g JOIN materials m ON m.code = g.material_code
        """,
        (player_id,),
    )
    return {
        "line": f"{RARITY_MARK.get(got['rarity'], '')} {got['emoji']} "
                f"**{got['material_name']}** {TIMES}{got['quantity']}",
        # What the Forager levels bought, said in words on the footer rather
        # than marked on every line. A bare glyph beside each find is not an
        # explanation — it is a thing to wonder about.
        "footer": f"+{got['exp_gained']} Forager EXP — level {got['level_after']}."
                  + (
                      f" Looking at {got['draws']} and keeping the rarest."
                      if got["draws"] > 1
                      else ""
                  ),
    }


async def one_mine(player_id: int) -> dict:
    got = await db.fetch_one("SELECT * FROM mine(%s)", (player_id,))
    note = None
    if got["deepest"] > got["tier_cap"]:
        note = (f"This region runs to **tier {got['deepest']}**. "
                f"You work tier {got['tier_cap']} and below.")
    return {
        "line": f"{RARITY_MARK.get(got['rarity'], '')} {got['emoji']} "
                f"**{got['material_name']}** {TIMES}{got['quantity']} "
                f"\N{BULLET} `T{got['ore_tier']}`"
                + (f"  {RICH} rich seam" if got["rich"] else ""),
        "note": note,
        "footer": f"+{got['exp_gained']} Miner EXP \u2014 level {got['level_after']}.",
    }


async def one_explore(player_id: int) -> dict:
    # LEFT JOIN: an empty-handed walk has no material to describe.
    found = await db.fetch_one(
        """
        SELECT e.*, m.emoji
        FROM explore(%s) e LEFT JOIN materials m ON m.code = e.material_code
        """,
        (player_id,),
    )
    footer = (
        f"+{found['exp_gained']} Explorer EXP — level {found['level_after']}."
    )
    if found["outcome"] == "nothing":
        return {
            "line": "\N{WHITE MEDIUM SQUARE} *Nothing but the walk.*",
            "footer": footer,
        }
    return {
        "line": f"{RARITY_MARK.get(found['rarity'], '')} {found['emoji']} "
                f"**{found['material_name']}** {TIMES}{found['quantity']} "
                f"\N{BULLET} *{found['outcome_name']}*",
        "footer": footer,
    }


class Seam:
    """One of the three ways to work a region, and the words for it."""

    def __init__(self, action, cooldown_key, tries_key, verb, button,
                 emoji, flavour, take) -> None:
        self.action = action
        self.cooldown_key = cooldown_key
        self.tries_key = tries_key
        self.verb = verb
        self.button = button
        self.emoji = emoji
        self.flavour = flavour
        self.take = take


SEAMS = {
    "gather": Seam(
        "gather", "gather_cooldown_minutes", "gather_tries", "bent over a herb",
        "Forage", "\N{HERB}",
        "You work over what grows here. Gathering materials are what Gu "
        "refinement and alchemy consume.",
        one_gather,
    ),
    "mine": Seam(
        "mine", "mine_cooldown_minutes", "mine_tries", "down a shaft",
        "Strike", "\N{PICK}",
        "You break into the stone under the region. Ore is what **/forge** "
        "turns into equipment.",
        one_mine,
    ),
    "explore": Seam(
        "explore", "explore_cooldown_minutes", "explore_tries", "exploring",
        "Search", "\N{LEFT-POINTING MAGNIFYING GLASS}",
        "You walk the region for whatever was left lying around.",
        one_explore,
    ),
}


class SwingButton(discord.ui.Button):
    def __init__(self, screen: "SeamView") -> None:
        self.screen = screen
        super().__init__(
            label=screen.seam.button,
            emoji=screen.seam.emoji,
            style=discord.ButtonStyle.primary,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        screen = self.screen

        # Spent FIRST, and by the database rather than by the counter on this
        # object: two fast clicks are two interactions, and only the row can
        # tell them apart.
        try:
            left = await db.fetch_value(
                "SELECT spend_try(%s, %s)", (screen.player_id, screen.seam.action)
            )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(
                "That set is finished. Run the command again."
            ) from exc

        screen.tries = left

        rogue = await check_ambush(screen.player_id, screen.here["region_code"])
        if rogue is not None:
            screen.last = (
                f"{BLADES} **Interrupted.** Whatever was in the ground is still "
                "in the ground."
            )
            screen.close()
            await interaction.response.edit_message(embed=screen.render(), view=screen)

            card, fight = await build_ambush(
                screen.player_id, screen.user, screen.here, rogue, screen.seam.verb
            )
            await interaction.followup.send(
                embed=card, view=fight if fight is not None else discord.utils.MISSING
            )
            screen.stop()
            return

        try:
            got = await screen.seam.take(screen.player_id)
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0].capitalize()) from exc

        screen.last = got["line"]
        screen.found.append(got["line"])
        screen.note = got.get("note") or screen.note
        screen.footer = got.get("footer") or screen.footer

        if left == 0:
            screen.close()
        await interaction.response.edit_message(embed=screen.render(), view=screen)
        if left == 0:
            screen.stop()


class SeamView(OwnedView):
    """Five tries at one cooldown.

    The count is authoritative in `player_action_tries`, not here: this copy
    exists to draw a number on a card. A view that dies with four tries left
    loses nothing, because running the command again picks them back up.
    """

    def __init__(self, player_id, user, seam: Seam, here: dict,
                 tries: int, *, resumed: bool = False) -> None:
        super().__init__(player_id, user)
        self.seam = seam
        self.here = here
        self.tries = tries
        self.resumed = resumed
        self.found: list[str] = []
        self.last: str | None = None
        self.note: str | None = None
        self.footer: str | None = None
        self.message: discord.Message | None = None
        self.add_item(SwingButton(self))

    def close(self) -> None:
        for item in self.children:
            item.disabled = True

    def render(self) -> discord.Embed:
        head = self.seam.flavour
        road = road_note(self.here)
        if road:
            head = f"{road}\n\n{head}"
        if self.resumed and not self.found:
            head = f"*Picking up where you left off.*\n\n{head}"
        if self.last:
            head = f"{head}\n\n{self.last}"

        card = embed(
            f"{self.here['emoji']} {self.here['region_name']}",
            head,
            colour=COLOUR_GOOD if self.found else COLOUR_DEFAULT,
        )
        card.add_field(
            name=f"Collected ({len(self.found)})",
            value="\n".join(self.found) or "*Nothing yet.*",
            inline=False,
        )
        card.add_field(name="Tries left", value=f"**{self.tries}**")
        if self.note:
            card.add_field(name="Deeper down", value=self.note, inline=False)
        card.set_footer(
            text=self.footer or "One cooldown, five tries. Walking away keeps the rest."
        )
        return card

    async def on_timeout(self) -> None:
        self.close()


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(World(bot))
