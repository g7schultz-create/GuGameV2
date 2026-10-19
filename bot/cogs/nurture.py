"""Feeding a Gu: /nurture.

`player_gu.stars` has always decided how strong a Gu is - `player_gu_stats`
scales every effect by `1 + gu_star_step * (stars - 1)`, so five stars is
double one - and nothing has ever raised them. Meanwhile duplicates of a type
you already hold pile up with nothing to do but be sold.

This is the bridge. Going to star N eats N spares of the same type and a purse
of stones, and the Gu keeps its own row, its own harmony and the day it was
found. That is the difference between nurturing one and replacing it.

Every gate is `gu_nursery`'s, which is also what `nurture_gu` reads. The
screen picks; it does not decide.
"""

import discord
import psycopg
from discord import app_commands
from discord.ext import commands

from bot import database as db
from bot.formatting import (
    COLOUR_BAD,
    COLOUR_DEFAULT,
    COLOUR_GOOD,
    COLOUR_INFO,
    embed,
    thousands,
)
from bot.picking import PER_PAGE, add_page_buttons, page_count, page_note, page_of
from bot.players import GameError, require_player
from bot.views import AnsweringView

STONE = "\N{LARGE BLUE DIAMOND}"
STAR = "\N{WHITE MEDIUM STAR}"
MAX_STARS = 5


def refuse(exc: psycopg.errors.CheckViolation) -> GameError:
    said = str(exc).splitlines()[0]
    return GameError(said[:1].upper() + said[1:])


async def fetch_nursery(player_id: int) -> list[dict]:
    """One row per KIND of Gu, not one per Gu.

    Somebody holding sixteen Bookworms does not want sixteen identical lines
    and does not care which of them is fed - so the screen offers the best
    copy of each type, which is the one worth keeping, and everything else of
    that type is its spares.

    Ones already at five stars are left out entirely: there is nothing to
    offer and a row saying so on every screen would bury the ones there is.
    """
    return await db.fetch_all(
        """
        SELECT DISTINCT ON (n.gu_type_id) n.*
        FROM gu_nursery n
        JOIN player_gu g ON g.gu_id = n.gu_id
        WHERE n.player_id = %s AND n.next_stars <= %s
        ORDER BY n.gu_type_id, n.stars DESC, g.harmony DESC, n.gu_id
        """,
        (player_id, MAX_STARS),
    )


def stars_of(row: dict) -> str:
    return STAR * row["stars"] + "\N{MEDIUM WHITE CIRCLE}" * (
        MAX_STARS - row["stars"]
    )


def nursery_line(row: dict) -> str:
    ready = row["spares"] >= row["copies_needed"] and row["stones_held"] >= row["stone_cost"]
    glyph = "\N{WHITE HEAVY CHECK MARK}" if ready else "\N{HOURGLASS WITH FLOWING SAND}"

    if row["spares"] < row["copies_needed"]:
        short = row["copies_needed"] - row["spares"]
        why = f"{short} more {row['name']} to feed it"
    elif row["stones_held"] < row["stone_cost"]:
        short = row["stone_cost"] - row["stones_held"]
        why = f"{thousands(short)} {STONE} short"
    else:
        why = (
            f"eats {row['copies_needed']} spare(s) and "
            f"{thousands(row['stone_cost'])} {STONE}"
        )

    return (
        f"{glyph} {row['emoji']} **{row['name']}** \N{BULLET} rank {row['rank']}\n"
        f"\N{IDEOGRAPHIC SPACE}{stars_of(row)} \N{RIGHTWARDS ARROW} "
        f"{STAR * row['next_stars']} \N{BULLET} {row['spares']} spare(s)\n"
        f"\N{IDEOGRAPHIC SPACE}*{why}*"
    )


def render(rows: list[dict], page: int) -> discord.Embed:
    shown = page_of(rows, page, 5)
    card = embed(
        f"{STAR} The nursery",
        "A Gu grows on its own kind. Feeding it spares of the same type raises "
        "its stars, and every star is a quarter more of everything it does "
        "\N{EM DASH} five stars is double one.\n\n"
        "*The Gu you feed keeps its own harmony and the day you found it. Only "
        "the spares are spent.*",
        colour=COLOUR_INFO if rows else COLOUR_DEFAULT,
    )
    if not rows:
        card.add_field(
            name="Nothing to feed",
            value="Every Gu you carry is either at five stars or the only one "
            "of its kind. **/hunt** turns up more.",
            inline=False,
        )
        return card

    card.add_field(
        name=f"Your Gu ({len(rows)})",
        value="\n\n".join(nursery_line(row) for row in shown),
        inline=False,
    )
    ready = sum(
        1 for r in rows
        if r["spares"] >= r["copies_needed"] and r["stones_held"] >= r["stone_cost"]
    )
    note = page_note(rows, page, "Gu", 5)
    card.set_footer(
        text=(f"{note}  \N{BULLET}  " if note else "")
        + (f"{ready} ready to feed" if ready else "none ready to feed yet")
    )
    return card


class Confirm(AnsweringView):
    """The spares are eaten. Worth showing the number first."""

    def __init__(self, screen: "Nursery", row: dict) -> None:
        super().__init__(timeout=180)
        self.screen = screen
        self.row = row

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.screen.user.id:
            await interaction.response.send_message(
                "Those are not your Gu.", ephemeral=True
            )
            return False
        return True

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True

    @discord.ui.button(
        label="Feed it", emoji="\N{WHITE MEDIUM STAR}",
        style=discord.ButtonStyle.success,
    )
    async def go(self, interaction: discord.Interaction, button) -> None:
        try:
            done = await db.fetch_one(
                "SELECT * FROM nurture_gu(%s, %s)",
                (self.screen.player_id, self.row["gu_id"]),
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        for item in self.children:
            item.disabled = True
        self.stop()

        card = embed(
            f"{STAR} {done['gu_name']} is stronger",
            f"{STAR * done['stars_before']} \N{RIGHTWARDS ARROW} "
            f"**{STAR * done['stars_after']}**\n\n"
            f"Everything it does is now "
            f"**{1 + 0.25 * (done['stars_after'] - 1):.2f}\N{MULTIPLICATION SIGN}** "
            "what a fresh one of its kind manages.",
            colour=COLOUR_GOOD,
        )
        card.add_field(
            name="Fed on",
            value=f"{done['eaten']} spare(s) \N{BULLET} "
            f"{thousands(done['stones_spent'])} {STONE}",
            inline=False,
        )
        card.set_footer(
            text=f"{done['spares_left']} spare(s) of it left \N{BULLET} "
            f"{thousands(done['stones_left'])} Spirit Stones"
        )
        await interaction.response.edit_message(embed=card, view=self)


class GuSelect(discord.ui.Select):
    def __init__(self, screen: "Nursery", rows: list[dict]) -> None:
        self.screen = screen
        self.rows = {str(r["gu_id"]): r for r in rows}
        super().__init__(
            placeholder="Feed one\N{HORIZONTAL ELLIPSIS}",
            options=[
                discord.SelectOption(
                    label=f"{r['name']} {STAR * r['stars']}"[:100],
                    value=str(r["gu_id"]),
                    description=(
                        f"to {r['next_stars']} stars \N{BULLET} "
                        f"{r['copies_needed']} spare(s) of {r['spares']} "
                        f"\N{BULLET} {thousands(r['stone_cost'])} stones"
                    )[:100],
                    emoji=r["emoji"][:1] if r["emoji"] else None,
                )
                for r in rows
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        row = self.rows[self.values[0]]
        card = embed(
            f"{STAR} Feed {row['name']} to {row['next_stars']} stars?",
            f"**{row['copies_needed']}** spare {row['name']} go into it, and "
            f"**{thousands(row['stone_cost'])}** {STONE}.\n\n"
            "*The weakest spares are taken first. This one keeps its harmony "
            "and its history.*",
            colour=COLOUR_BAD,
        )
        await interaction.response.edit_message(
            embed=card, view=Confirm(self.screen, row)
        )


class Nursery(AnsweringView):
    def __init__(self, player_id: int, user: discord.abc.User, rows: list[dict]) -> None:
        super().__init__(timeout=300)
        self.player_id = player_id
        self.user = user
        self.rows = rows
        self.page = 0
        self.build()

    def ready(self) -> list[dict]:
        return [
            r for r in self.rows
            if r["spares"] >= r["copies_needed"]
            and r["stones_held"] >= r["stone_cost"]
        ]

    def page_count(self) -> int:
        return page_count(self.rows, 5)

    def card(self) -> discord.Embed:
        return render(self.rows, self.page)

    def build(self) -> None:
        self.clear_items()
        # Only the ones a press would actually work on. The rest are on the
        # card with the reason, which is more use than a dead option.
        can = self.ready()
        if can:
            self.add_item(GuSelect(self, can[:PER_PAGE]))
        add_page_buttons(self, row=1)

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "Those are not your Gu.", ephemeral=True
            )
            return False
        return True

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True


class Nurture(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @app_commands.command(
        description="Feed spare Gu to one you are keeping, and raise its stars."
    )
    async def nurture(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        rows = await fetch_nursery(player["player_id"])

        if not rows:
            raise GameError(
                "You carry no Gu that could take another star. They come off "
                "beasts \N{EM DASH} **/hunt** \N{EM DASH} and a second of a "
                "kind you already have is what feeds the first."
            )

        view = Nursery(player["player_id"], interaction.user, rows)
        await interaction.response.send_message(embed=view.card(), view=view)


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Nurture(bot))
