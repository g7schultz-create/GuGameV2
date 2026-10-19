"""Where a cultivator lives: /dwelling.

A thatched hut at Rank 1 and a Grotto-Heaven at Rank 8, with eight rungs in
between. It is the only thing in this game bought once and kept forever, and
the only sink deep enough to want a lifetime of surplus - which is what a game
with faucets and no sinks was missing.

Nothing here computes a bonus. A facility grants an ordinary `gu_effects`
entry through `dwelling_stat`, so a Meditation Chamber's cultivation speed
reaches the settle by exactly the road a Gu's does. This file draws it and
nothing else.

The decision the screen exists to pose: a Cave Abode holds three facilities
and there are ten worth building.
"""

import discord
import psycopg
from discord import app_commands
from discord.ext import commands

from bot import database as db
from bot.formatting import (
    COLOUR_DEFAULT,
    COLOUR_GOOD,
    COLOUR_INFO,
    embed,
    percent,
    thousands,
)
from bot.picking import add_page_buttons, page_count, page_of
from bot.players import GameError, require_player, settle_passive
from bot.views import AnsweringView

JADE = "\N{GREEN HEART}"
STONE = "\N{GEM STONE}"


async def fetch_home(player_id: int) -> dict | None:
    return await db.fetch_one(
        """
        SELECT pd.stage, pd.name AS given_name, s.name, s.emoji, s.description,
               s.flavour, s.facility_slots,
               (SELECT count(*) FROM player_facilities pf
                WHERE pf.player_id = pd.player_id) AS built
        FROM player_dwelling pd
        JOIN dwelling_stages s ON s.stage = pd.stage
        WHERE pd.player_id = %s
        """,
        (player_id,),
    )


async def fetch_standing(player_id: int) -> list[dict]:
    """Every facility, whether or not it has been built. A screen that hid the
    unbuilt ones could not answer "what could go in here", which is the only
    question a player with a free slot has."""
    return await db.fetch_all(
        """
        SELECT f.code, f.name, f.emoji, f.description, f.max_level, f.min_stage,
               f.per_level, e.name AS effect_name, e.emoji AS effect_emoji,
               COALESCE(pf.level, 0) AS level,
               f.per_level * COALESCE(pf.level, 0) AS worth,
               -- Rendered in SQL because `is_base` lives on the effect. Ward
               -- Array grants hide in POINTS since 0444, and a screen that
               -- multiplied it by 100 would call 0.30 a thirty per cent wall.
               effect_amount(f.effect_code,
                             f.per_level * COALESCE(pf.level, 0)) AS worth_said,
               effect_amount(f.effect_code, f.per_level) AS per_level_said,
               c.stone_cost, c.ore_weight, c.beast_weight,
               (SELECT s.name FROM dwelling_stages s WHERE s.stage = f.min_stage)
                   AS needs_stage
        FROM dwelling_facilities f
        JOIN gu_effects e ON e.code = f.effect_code
        LEFT JOIN player_facilities pf
               ON pf.facility = f.code AND pf.player_id = %s
        CROSS JOIN LATERAL facility_cost(
            f.code, (COALESCE(pf.level, 0) + 1)::smallint) c
        ORDER BY f.sort_order
        """,
        (player_id,),
    )


async def fetch_next(player_id: int) -> dict | None:
    return await db.fetch_one("SELECT * FROM dwelling_next(%s)", (player_id,))


async def fetch_blessed(player_id: int) -> dict | None:
    """What the blessed land is condensing, read rather than collected.

    The collecting already happened: every command calls `settle_passive`
    first, and `settle_passive_cultivation` settles the land. Calling
    `blessed_land_settle` again here would be harmless - it only ever pays what
    is owed - but a screen that pays people is a screen you have to be careful
    about, so this one only looks.
    """
    return await db.fetch_one(
        """
        SELECT m.name AS essence_name, m.emoji AS essence_emoji,
               COALESCE(pm.quantity, 0) AS held,
               game_config_value('blessed_land_essence_per_day') AS per_day,
               pd.essence_settled_at
                   + make_interval(secs => (24.0
                       / game_config_value('blessed_land_essence_per_day')
                       * 3600)::int) AS ready_at
        FROM player_dwelling pd
        JOIN player_cultivation pc ON pc.player_id = pd.player_id
        JOIN realms r ON r.realm_id = pc.realm_id
        JOIN immortal_essences e ON e.rank = r.rank
        JOIN materials m ON m.code = e.material_code
        LEFT JOIN player_materials pm
               ON pm.player_id = pd.player_id AND pm.material_code = m.code
        WHERE pd.player_id = %s
          AND pd.stage >= game_config_value('blessed_land_stage')
        """,
        (player_id,),
    )


async def render_home(player_id: int, display_name: str) -> discord.Embed:
    home = await fetch_home(player_id)
    nxt = await fetch_next(player_id)

    if home is None:
        card = embed(
            "\N{DERELICT HOUSE BUILDING} No fixed address",
            f"{display_name} sleeps where the walking stops. A cultivator with "
            "nowhere to return to spends their life carrying everything they "
            "own.",
            colour=COLOUR_INFO,
        )
    else:
        title = home["given_name"] or home["name"]
        card = embed(
            f"{home['emoji']} {title}",
            f"*{home['flavour']}*\n\n{home['description']}",
            colour=COLOUR_DEFAULT,
        )

        standing = [r for r in await fetch_standing(player_id) if r["level"]]
        card.add_field(
            name=f"Standing in it ({home['built']}/{home['facility_slots']})",
            value="\n".join(
                f"{r['emoji']} **{r['name']}** \N{BULLET} level {r['level']}"
                f"/{r['max_level']}\n"
                f"     {r['effect_emoji']} {r['worth_said']} {r['effect_name']}"
                for r in standing
            )
            or "*Bare ground. Something could stand here.*",
            inline=False,
        )

        blessed = await fetch_blessed(player_id)
        if blessed is not None:
            card.add_field(
                name="\N{LOTUS} What it condenses",
                value=f"{blessed['essence_emoji']} **{blessed['essence_name']}** "
                f"\N{BULLET} {int(blessed['per_day'])} a day\n"
                f"Holding {thousands(blessed['held'])} \N{BULLET} next one "
                f"{discord.utils.format_dt(blessed['ready_at'], style='R')}\n"
                "*It keeps working while you are away, up to a day's worth.*",
                inline=False,
            )

    if nxt is None:
        card.add_field(
            name="\N{GLOWING STAR} The last of them",
            value="An Immortal Blessed Land is where the ladder ends. There is "
            "nothing above it to build.",
            inline=False,
        )
        return card

    # Every gate answered separately, so the screen says which one is in the
    # way rather than only that something is.
    gates = [
        (nxt["realm_ok"], f"**{nxt['realm_name']}**"),
        (nxt["stones_ok"], f"{STONE} **{thousands(nxt['stone_cost'])}** spirit stones"),
        (nxt["ore_ok"], f"\N{PICK} **{thousands(nxt['ore_weight'])}** ore weight"),
        (nxt["beast_ok"], f"\N{PAW PRINTS} **{thousands(nxt['beast_weight'])}** beast weight"),
        (nxt["jade_ok"], f"{JADE} **{thousands(nxt['jade_cost'])}** Spirit Jade"),
    ]
    card.add_field(
        name=f"Next: {nxt['emoji']} {nxt['name']}",
        value=f"*{nxt['description']}*\n\n"
        + "\n".join(
            ("\N{WHITE HEAVY CHECK MARK} " if ok else "\N{HEAVY MULTIPLICATION X} ")
            + text
            for ok, text in gates
            if not (text.endswith("Spirit Jade") and nxt["jade_cost"] == 0)
            and not (text.endswith("beast weight") and nxt["beast_weight"] == 0)
            and not (text.endswith("spirit stones") and nxt["stone_cost"] == 0)
            and not (text.endswith("ore weight") and nxt["ore_weight"] == 0)
        )
        + f"\n\nRoom for **{nxt['facility_slots']}** facilities.",
        inline=False,
    )
    return card


class RaiseButton(discord.ui.Button):
    def __init__(self, screen: "DwellingView", label: str) -> None:
        self.screen = screen
        super().__init__(label=label, row=1, style=discord.ButtonStyle.success)

    async def callback(self, interaction: discord.Interaction) -> None:
        try:
            done = await db.fetch_one(
                "SELECT * FROM raise_dwelling(%s)", (self.screen.player_id,)
            )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0].capitalize()) from exc

        card = embed(
            f"\N{GLOWING STAR} {done['name_after']}",
            f"*{done['flavour']}*",
            colour=COLOUR_GOOD,
        )
        if done["name_before"]:
            card.description = (
                f"**{done['name_before']}** \N{RIGHTWARDS ARROW} "
                f"**{done['name_after']}**\n\n" + card.description
            )
        paid = []
        if done["stones_spent"]:
            paid.append(f"{STONE} {thousands(done['stones_spent'])} spirit stones")
        if done["jade_spent"]:
            paid.append(f"{JADE} {thousands(done['jade_spent'])} Spirit Jade")
        for item in (done["ore_spent"] or []) + (done["beast_spent"] or []):
            paid.append(f"{item['name']} \N{MULTIPLICATION SIGN}{item['quantity']}")
        if paid:
            card.add_field(name="What it cost", value=", ".join(paid), inline=False)
        card.add_field(
            name="Room",
            value=f"**{done['slots_after']}** facilities may stand in it.",
            inline=False,
        )

        await self.screen.reload()
        await interaction.response.edit_message(embed=card, view=self.screen)


class FacilitySelect(discord.ui.Select):
    def __init__(self, screen: "DwellingView", rows: list[dict]) -> None:
        self.screen = screen
        super().__init__(
            placeholder="Build or improve\N{HORIZONTAL ELLIPSIS}",
            row=0,
            options=[
                discord.SelectOption(
                    label=(
                        f"{r['name']} \N{BULLET} "
                        + (f"level {r['level']}/{r['max_level']}" if r["level"]
                           else "not built")
                    )[:100],
                    value=r["code"],
                    emoji=r["emoji"][:1] if r["emoji"] else None,
                    description=(
                        f"{r['per_level_said']} {r['effect_name']} a level"
                        if r["level"] < r["max_level"]
                        else "as good as one gets"
                    )[:100],
                )
                for r in rows
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        try:
            done = await db.fetch_one(
                "SELECT * FROM build_facility(%s, %s)",
                (self.screen.player_id, self.values[0]),
            )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0].capitalize()) from exc

        card = embed(
            f"{done['emoji']} {done['name']} \N{BULLET} level {done['level_after']}",
            "Raised." if done["level_before"] else "Built.",
            colour=COLOUR_GOOD,
        )
        # `build_facility` hands back a name and a number but not the effect
        # code, and the code is the only thing that knows whether the number
        # is points or a fraction - so it is asked for rather than guessed.
        granted = await db.fetch_value(
            "SELECT effect_amount(f.effect_code, %s) "
            "FROM dwelling_facilities f WHERE f.code = %s",
            (done["effect_now"], done["facility"]),
        )
        card.add_field(
            name="What it grants",
            value=f"{granted} {done['effect_name']}",
            inline=False,
        )
        paid = []
        if done["stones_spent"]:
            paid.append(f"{STONE} {thousands(done['stones_spent'])} spirit stones")
        for item in (done["ore_spent"] or []) + (done["beast_spent"] or []):
            paid.append(f"{item['name']} \N{MULTIPLICATION SIGN}{item['quantity']}")
        if paid:
            card.add_field(name="What it cost", value=", ".join(paid), inline=False)

        await self.screen.reload()
        await interaction.response.edit_message(embed=card, view=self.screen)


class DwellingView(AnsweringView):
    def __init__(
        self,
        player_id: int,
        user: discord.abc.User,
        home: dict | None,
        nxt: dict | None,
        standing: list[dict],
    ) -> None:
        super().__init__(timeout=300)
        self.player_id = player_id
        self.user = user
        self.home = home
        self.next = nxt
        self.standing = standing
        self.page = 0
        self.build()

    def buildable(self) -> list[dict]:
        """What this dwelling could take: everything its stage allows and that
        is not already finished. An unbuilt facility above the stage is left
        off rather than offered and refused."""
        if self.home is None:
            return []
        return [
            r
            for r in self.standing
            if r["min_stage"] <= self.home["stage"] and r["level"] < r["max_level"]
        ]

    def page_count(self) -> int:
        return page_count(self.buildable())

    async def card(self) -> discord.Embed:
        return await render_home(self.player_id, self.user.display_name)

    async def reload(self) -> None:
        self.home = await fetch_home(self.player_id)
        self.next = await fetch_next(self.player_id)
        self.standing = await fetch_standing(self.player_id)
        self.page = min(self.page, self.page_count() - 1)
        self.build()

    def build(self) -> None:
        self.clear_items()
        options = page_of(self.buildable(), self.page)
        if options:
            self.add_item(FacilitySelect(self, options))
        if self.next and self.next["ready"]:
            self.add_item(
                RaiseButton(
                    self,
                    "Found it" if self.home is None else f"Raise to {self.next['name']}",
                )
            )
        add_page_buttons(self, row=2)

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "Not your dwelling.", ephemeral=True
            )
            return False
        return True

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True


class Dwelling(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @app_commands.command(
        description="Your dwelling, from a thatched hut to a Grotto-Heaven."
    )
    async def dwelling(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])

        home = await fetch_home(player["player_id"])
        nxt = await fetch_next(player["player_id"])
        standing = await fetch_standing(player["player_id"])

        view = DwellingView(player["player_id"], interaction.user, home, nxt, standing)
        await interaction.response.send_message(
            embed=await view.card(),
            view=view if view.children else discord.utils.MISSING,
        )


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Dwelling(bot))
