"""The board: /leaderboard.

Five ways of being ahead, and this file decides none of them. `leaderboard()`
ranks and words every row; the buttons only choose which board to ask for.

That matters more here than on most screens. A leaderboard is the one place
where a number the game computes and a number a screen computes being
different is not a cosmetic bug - it is an argument between players.
"""

import discord
from discord import app_commands
from discord.ext import commands

from bot import database as db
from bot.formatting import COLOUR_INFO, embed
from bot.players import require_player, settle_passive
from bot.views import AnsweringView

# Board code, button label, the emoji it is titled with, and the line under
# the title. Order is the order of the buttons.
BOARDS = (
    ("cultivation", "Cultivation", "\N{MOUNTAIN}",
     "How far along the road, realm first. A Core Formation cultivator is "
     "ahead of a Foundation one whatever the raw number says."),
    ("boss", "World beasts", "\N{VOLCANO}",
     "Everything ever taken off a world beast \N{EM DASH} the only score here "
     "earned entirely in company."),
    ("crafting", "Crafting", "\N{HAMMER AND PICK}",
     "Every trade added up: Blacksmith, Alchemist, Miner, Forager, Explorer, "
     "Gu Refiner and Refiner."),
    ("techniques", "Techniques", "\N{CROSSED SWORDS}",
     "What you could actually bring to a fight \N{EM DASH} learned outright, "
     "plus whatever an equipped manual is lending you."),
    ("wealth", "Wealth", "\N{MONEY BAG}",
     "Spirit Stones and Spirit Jade. The auction house is left out; it holds "
     "what everyone has listed."),
)

PLACES = {1: "\N{FIRST PLACE MEDAL}", 2: "\N{SECOND PLACE MEDAL}",
          3: "\N{THIRD PLACE MEDAL}"}
SHOWN = 10


def board_of(code: str) -> tuple[str, str, str, str]:
    return next(b for b in BOARDS if b[0] == code)


async def fetch_board(code: str, limit: int = SHOWN) -> list[dict]:
    return await db.fetch_all(
        "SELECT * FROM leaderboard(%s, %s)", (code, limit)
    )


async def standing(code: str, player_id: int) -> dict | None:
    """Where the reader is, when they are not on the page.

    A board that shows ten names and nothing else answers "who is winning"
    and refuses "where am I", which is the question the person who opened it
    actually has.
    """
    rows = await db.fetch_all("SELECT * FROM leaderboard(%s, %s)", (code, 500))
    for row in rows:
        if row["player_id"] == player_id:
            return {"row": row, "of": len(rows)}
    return None


def line(row: dict, *, mine: bool) -> str:
    mark = PLACES.get(row["place"], f"`{row['place']:>2}`")
    return (
        f"{mark} **{row['discord_name']}** \N{EM DASH} {row['headline']}"
        + ("  \N{LEFTWARDS BLACK ARROW} *you*" if mine else "")
        + f"\n\N{IDEOGRAPHIC SPACE}*{row['detail']}*"
    )


async def render(code: str, player_id: int) -> discord.Embed:
    _, label, glyph, blurb = board_of(code)
    rows = await fetch_board(code)

    card = embed(f"{glyph} {label}", blurb, colour=COLOUR_INFO)

    if not rows:
        card.add_field(
            name="Nobody yet",
            value="Nothing has been recorded on this board. Be the first.",
            inline=False,
        )
        return card

    card.add_field(
        name=f"Top {len(rows)}",
        value="\n".join(
            line(r, mine=r["player_id"] == player_id) for r in rows
        ),
        inline=False,
    )

    # Only when they are not already above. Telling somebody in third place
    # that they are in third place is noise.
    if not any(r["player_id"] == player_id for r in rows):
        me = await standing(code, player_id)
        card.set_footer(
            text=(f"You are {me['row']['place']} of {me['of']} "
                  f"\N{BULLET} {me['row']['headline']}")
            if me else "You are not on this board yet."
        )
    return card


class BoardButton(discord.ui.Button):
    def __init__(self, screen: "BoardView", code: str, label: str, glyph: str) -> None:
        self.screen = screen
        self.code = code
        super().__init__(
            label=label,
            emoji=glyph,
            style=(
                discord.ButtonStyle.success
                if code == screen.board
                else discord.ButtonStyle.secondary
            ),
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        self.screen.board = self.code
        self.screen.build()
        await interaction.response.edit_message(
            embed=await render(self.code, self.screen.player_id),
            view=self.screen,
        )


class BoardView(AnsweringView):
    """Anybody may press. A leaderboard read by one person is a leaderboard
    with half its purpose removed - but it redraws for whoever pressed, so
    the "you" marker follows the reader rather than the opener."""

    def __init__(self, player_id: int, board: str = "cultivation") -> None:
        super().__init__(timeout=300)
        self.player_id = player_id
        self.board = board
        self.build()

    def build(self) -> None:
        self.clear_items()
        for code, label, glyph, _ in BOARDS:
            self.add_item(BoardButton(self, code, label, glyph))

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True


class Leaderboard(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @app_commands.command(description="Who is ahead, and at what.")
    @app_commands.describe(board="Which board to open on.")
    @app_commands.choices(board=[
        app_commands.Choice(name=label, value=code)
        for code, label, _, _ in BOARDS
    ])
    async def leaderboard(
        self,
        interaction: discord.Interaction,
        board: app_commands.Choice[str] | None = None,
    ) -> None:
        player = await require_player(interaction.user)
        # So the cultivation board is not showing everybody an hour stale.
        await settle_passive(player["player_id"])

        code = board.value if board else "cultivation"
        view = BoardView(player["player_id"], code)
        await interaction.response.send_message(
            embed=await render(code, player["player_id"]), view=view
        )


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Leaderboard(bot))
