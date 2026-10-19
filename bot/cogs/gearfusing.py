"""Gear fusing: /fusegear.

The anvil's other job. A duplicate stops being something to sell and becomes
what a star costs, which is the same bargain the servants have had since 0415.

Its own cog rather than another screen bolted onto `/gear`: the rack already
spends four of its five rows on slot buttons, a sort and two selects, and
fusing needs two selects of its own plus a button. There was no room, and a
screen that does two jobs badly is worse than two that each do one.

The rule this screen is built around is that it only ever offers a pairing
`fuse_equipment` will accept - same slot, same level, same rank, not worn. A
select that lists something the function then refuses is a screen arguing with
itself, and the player is the one who has to work out which of them is right.
"""

import discord
import psycopg
from discord import app_commands
from discord.ext import commands

from bot import database as db
from bot.character import RARITY_MARK
from bot.formatting import (
    COLOUR_BAD,
    COLOUR_GOOD,
    COLOUR_INFO,
    embed,
)
from bot.picking import add_page_buttons, page_count, page_note, page_of
from bot.players import GameError, require_player, settle_passive
from bot.views import AnsweringView

DOT = "\N{BULLET}"
STAR = "\N{WHITE MEDIUM STAR}"
HAMMER = "\N{HAMMER}"


async def fetch_fusable(player_id: int) -> list[dict]:
    """Everything that could go on the anvil, which is everything not worn.

    Worn gear is excluded in the QUERY rather than filtered afterwards, so the
    screen cannot offer a piece the function will refuse.
    """
    return await db.fetch_all(
        """
        SELECT pe.equipment_id, pe.name, pe.slot, pe.tier, pe.rarity,
               pe.level, pe.rank, pe.quality,
               s.name AS slot_name, s.emoji AS slot_emoji,
               qb.name AS quality_name,
               l.max_rank,
               (SELECT count(*) FROM equipment_effects ee
                WHERE ee.equipment_id = pe.equipment_id) AS stat_count,
               -- The stats themselves, not just how many. A fuse keeps the
               -- better of each, so "4 stats" is exactly the wrong thing to
               -- show somebody deciding which piece to spend.
               COALESCE((
                   SELECT string_agg(
                       ef.emoji || ' ' || ef.name || ' ' ||
                       effect_amount(ee.effect_code, ee.magnitude),
                       chr(10) ORDER BY ef.is_base, ee.magnitude DESC)
                   FROM equipment_effects ee
                   JOIN gu_effects ef ON ef.code = ee.effect_code
                   WHERE ee.equipment_id = pe.equipment_id
               ), 'nothing') AS stat_text
        FROM player_equipment pe
        JOIN equipment_slots s ON s.code = pe.slot
        JOIN equipment_quality_bands qb ON qb.code = pe.quality
        JOIN equipment_level_scales l ON l.level = pe.level
        LEFT JOIN player_equipped q ON q.equipment_id = pe.equipment_id
        WHERE pe.owner_id = %s AND q.equipment_id IS NULL
        ORDER BY pe.slot, pe.level DESC, pe.rank DESC, pe.equipment_id
        """,
        (player_id,),
    )


def piece_label(row: dict) -> str:
    return f"{RARITY_MARK.get(row['rarity'], '')} {row['name']}"[:100]


def piece_note(row: dict) -> str:
    return (
        f"{STAR * int(row['rank'])} L{row['level']} "
        f"{row['rarity'].title()} {DOT} {row['quality_name']}"
    )[:100]


class Keeper(discord.ui.Select):
    """The piece that survives."""

    def __init__(self, screen: "FuseView", rows: list[dict]) -> None:
        self.screen = screen
        self.rows = {str(r["equipment_id"]): r for r in rows}
        super().__init__(
            placeholder="Which piece are you raising?",
            row=1,
            options=[
                discord.SelectOption(
                    label=piece_label(r),
                    value=str(r["equipment_id"]),
                    description=piece_note(r),
                    emoji=r["slot_emoji"][:1] if r["slot_emoji"] else None,
                )
                for r in rows
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        self.screen.keeper = self.rows[self.values[0]]
        # A fodder chosen for the previous keeper almost certainly no longer
        # matches it, and silently keeping the pick is how somebody spends the
        # wrong piece.
        self.screen.fodder = None
        self.screen.build()
        await interaction.response.edit_message(
            embed=await self.screen.card(), view=self.screen
        )


class Fodder(discord.ui.Select):
    """What gets eaten. Only ever what the fuse would actually accept."""

    def __init__(self, screen: "FuseView", rows: list[dict]) -> None:
        self.screen = screen
        self.rows = {str(r["equipment_id"]): r for r in rows}
        super().__init__(
            placeholder="Which duplicate is being spent?",
            row=2,
            options=[
                discord.SelectOption(
                    label=piece_label(r),
                    value=str(r["equipment_id"]),
                    description=piece_note(r),
                    emoji=r["slot_emoji"][:1] if r["slot_emoji"] else None,
                )
                for r in rows
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        self.screen.fodder = self.rows[self.values[0]]
        self.screen.build()
        await interaction.response.edit_message(
            embed=await self.screen.card(), view=self.screen
        )


class FuseButton(discord.ui.Button):
    def __init__(self, screen: "FuseView", odds: float) -> None:
        self.screen = screen
        super().__init__(
            label=f"Fuse \N{EM DASH} {round(odds * 100)} in 100",
            emoji=HAMMER,
            style=discord.ButtonStyle.danger,
            row=3,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        try:
            got = await db.fetch_one(
                "SELECT * FROM fuse_equipment(%s, %s, %s)",
                (
                    player["player_id"],
                    self.screen.keeper["equipment_id"],
                    self.screen.fodder["equipment_id"],
                ),
            )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0].capitalize()) from exc

        if got["succeeded"]:
            card = embed(
                f"{HAMMER} {got['name_after']}",
                f"It holds. **{STAR * int(got['rank_after'])}**",
                colour=COLOUR_GOOD,
            )
            card.add_field(
                name="What it is now",
                value=f"{RARITY_MARK.get(got['rarity_after'], '')} "
                      f"{got['rarity_after'].title()} {DOT} "
                      f"{got['quality_after'].title()} {DOT} "
                      f"{got['improved']} stat(s) carried across",
                inline=False,
            )
        else:
            card = embed(
                f"{HAMMER} It does not take",
                f"The duplicate is spent and **{got['name_after']}** is "
                f"unchanged at {STAR * int(got['rank_before'])}.",
                colour=COLOUR_BAD,
            )
            card.add_field(
                name="The odds were",
                value=f"{round(float(got['chance']) * 100)} in a hundred. "
                      "They improve with Blacksmithing.",
                inline=False,
            )

        await self.screen.reload(player["player_id"])
        await interaction.response.edit_message(
            embed=await self.screen.card(), view=self.screen
        )
        await interaction.followup.send(embed=card)


class FuseView(AnsweringView):
    """Two pieces in, one out."""

    def __init__(
        self, player_id: int, user: discord.abc.User, rows: list[dict]
    ) -> None:
        super().__init__(timeout=300)
        self.player_id = player_id
        self.user = user
        self.rows = rows
        self.keeper: dict | None = None
        self.fodder: dict | None = None
        self.page = 0
        self.odds = 0.0
        self.build()

    async def reload(self, player_id: int) -> None:
        self.rows = await fetch_fusable(player_id)
        # Whichever of the two survived the fuse is kept selected; whichever
        # was eaten is dropped, because it is not there any more.
        for which in ("keeper", "fodder"):
            held = getattr(self, which)
            if held is not None:
                setattr(self, which, next(
                    (r for r in self.rows
                     if r["equipment_id"] == held["equipment_id"]), None))
        self.page = 0
        self.build()

    def raisable(self) -> list[dict]:
        """Pieces not already at the ceiling their realm allows."""
        return [r for r in self.rows if int(r["rank"]) < int(r["max_rank"])]

    def matches(self) -> list[dict]:
        """What may be fed to the chosen keeper - `fuse_equipment`'s own rule,
        asked here so the screen never offers a pairing it will refuse."""
        if self.keeper is None:
            return []
        k = self.keeper
        return [
            r for r in self.rows
            if r["equipment_id"] != k["equipment_id"]
            and r["slot"] == k["slot"]
            and int(r["level"]) == int(k["level"])
            and int(r["rank"]) == int(k["rank"])
        ]

    def page_count(self) -> int:
        return page_count(self.raisable())

    def build(self) -> None:
        self.clear_items()
        shown = page_of(self.raisable(), self.page)
        if shown:
            self.add_item(Keeper(self, shown))
            add_page_buttons(self, row=0)
        if self.keeper is not None:
            pair = self.matches()
            if pair:
                self.add_item(Fodder(self, pair[:25]))
            if self.fodder is not None:
                self.add_item(FuseButton(self, self.odds))

    async def card(self) -> discord.Embed:
        card = embed(
            f"{HAMMER} The anvil, again",
            "Two of a kind go in. One comes out a star higher, or the "
            "duplicate is spent and nothing changes.",
            colour=COLOUR_INFO,
        )

        spare = self.raisable()
        if not spare:
            card.add_field(
                name="Nothing to raise",
                value="Everything you are not wearing is already at the "
                      "ceiling its realm allows \N{EM DASH} or there is "
                      "nothing off your back to work on.",
                inline=False,
            )
            return card

        if self.keeper is None:
            card.add_field(
                name=f"{len(spare)} piece(s) could be raised",
                value=page_note(spare, self.page, "piece")
                      or "Choose the one you are keeping.",
                inline=False,
            )
            return card

        k = self.keeper
        card.add_field(
            name=f"Keeping {k['name']}",
            value=f"{RARITY_MARK.get(k['rarity'], '')} {k['rarity'].title()} "
                  f"{DOT} {k['quality_name']} {DOT} {STAR * int(k['rank'])} "
                  f"{DOT} level {k['level']}\n"
                  f"{k['stat_text']}\n\n"
                  f"**{STAR * (int(k['rank']) + 1)}** if it holds "
                  f"(gear of this realm stops at {k['max_rank']}).",
            inline=False,
        )

        pair = self.matches()
        if not pair:
            card.add_field(
                name="Nothing matches it",
                value=f"A fuse needs another **{k['slot_name'].lower()}** of "
                      f"**level {k['level']}** at **{STAR * int(k['rank'])}**. "
                      "The names need not match \N{EM DASH} the forge rarely "
                      "makes the same one twice.",
                inline=False,
            )
            return card

        self.odds = float(await db.fetch_value(
            "SELECT fuse_chance(%s, %s::smallint)",
            (self.player_id, int(k["rank"]) + 1),
        ))

        if self.fodder is None:
            card.add_field(
                name=f"{len(pair)} could be spent",
                value="Choose which duplicate goes in.",
                inline=False,
            )
        else:
            f = self.fodder
            card.add_field(
                name=f"Spending {f['name']}",
                value=f"{RARITY_MARK.get(f['rarity'], '')} {f['rarity'].title()} "
                      f"{DOT} {f['quality_name']}\n"
                      f"{f['stat_text']}\n\n"
                      "It is gone whether it takes or not.",
                inline=False,
            )

        card.add_field(
            name="Odds",
            value=f"**{round(self.odds * 100)} in a hundred.** The survivor "
                  "keeps the better of each stat, the better rarity and the "
                  "better quality.",
            inline=False,
        )
        return card


class Fusing(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    # `fusegear` rather than `fuse`: `/fuse` already belongs to manual pages
    # in `fusion.py`, and discord.py refuses a duplicate name outright - the
    # whole test suite errored on CommandAlreadyRegistered the moment this cog
    # was registered. Named the way `/refinegu` distinguishes itself from
    # `/refine`.
    @app_commands.command(
        name="fusegear",
        description="Fuse a duplicate into a piece of gear to raise it a star.",
    )
    async def fusegear(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])

        rows = await fetch_fusable(player["player_id"])
        if not rows:
            raise GameError(
                "Nothing on the anvil. Fusing needs two pieces you are not "
                "wearing \N{EM DASH} take something off, or **/forge**."
            )

        view = FuseView(player["player_id"], interaction.user, rows)
        await interaction.response.send_message(
            embed=await view.card(), view=view
        )


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Fusing(bot))
