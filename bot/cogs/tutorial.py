"""The guide: /tutorial.

Twelve pages, one per system, each behind a button. Nothing here is written in
this file — the pages are rows in `tutorial_pages`, so a typo is an UPDATE
rather than a deploy and a new system arrives with its own page.

**The numbers are not written down either.** A page says
`{gather_cooldown_minutes}` and the view substitutes the live value, so the
guide cannot drift from the game it describes. A tutorial that lies is worse
than none: it is the one thing a new player has no way to check.

It needs no character. Somebody deciding whether to register should be able to
read what they would be registering for.
"""

import discord
from discord import app_commands
from discord.ext import commands

from bot import database as db
from bot.views import AnsweringView
from bot.formatting import COLOUR_INFO, embed

# Discord allows five components a row. Twelve pages sit in three.
PER_ROW = 4


async def fetch_pages() -> list[dict]:
    return await db.fetch_all(
        "SELECT code, title, emoji, body FROM tutorial ORDER BY sort_order"
    )


def render(page: dict, total: int, position: int) -> discord.Embed:
    card = embed(f"{page['emoji']} {page['title']}", page["body"], colour=COLOUR_INFO)
    card.set_footer(
        text=f"{position} of {total} \N{BULLET} /tutorial any time \N{BULLET} "
        "every command works as `I <name>` too"
    )
    return card


class PageButton(discord.ui.Button):
    def __init__(self, screen: "TutorialView", page: dict, row: int) -> None:
        self.screen = screen
        self.page = page
        super().__init__(
            label=page["title"],
            emoji=page["emoji"][:1] if page["emoji"] else None,
            row=row,
            style=(
                discord.ButtonStyle.primary
                if page["code"] == screen.showing
                else discord.ButtonStyle.secondary
            ),
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        self.screen.showing = self.page["code"]
        self.screen.build()
        await interaction.response.edit_message(
            embed=render(
                self.page,
                len(self.screen.pages),
                self.screen.index(self.page["code"]),
            ),
            view=self.screen,
        )


class TutorialView(AnsweringView):
    """Public and unowned on purpose.

    Every other view in this bot refuses anyone but the person who opened it,
    because pressing a button on somebody else's screen spends their materials.
    Nothing here is spent, and a guide two people can read together is better
    than one they cannot.
    """

    def __init__(self, pages: list[dict]) -> None:
        super().__init__(timeout=900)
        self.pages = pages
        self.showing = pages[0]["code"]
        self.build()

    def index(self, code: str) -> int:
        return next(i for i, p in enumerate(self.pages) if p["code"] == code) + 1

    def build(self) -> None:
        self.clear_items()
        for position, page in enumerate(self.pages[:20]):
            self.add_item(PageButton(self, page, row=position // PER_ROW))

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True


class Tutorial(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @app_commands.command(description="How the game works, one system at a time.")
    async def tutorial(self, interaction: discord.Interaction) -> None:
        # No `require_player`: somebody deciding whether to register should be
        # able to read what they would be registering for.
        pages = await fetch_pages()
        view = TutorialView(pages)
        await interaction.response.send_message(
            embed=render(pages[0], len(pages), 1), view=view
        )


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Tutorial(bot))
