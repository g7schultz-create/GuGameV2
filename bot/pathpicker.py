"""The Path chooser, shared by /focus and /path.

Both commands ask the same question — which of the 28 Paths — and differ only
in what happens once one is pressed. So the paging, the emoji, the ownership
check and the highlight live here once, and each command supplies an `on_pick`.

28 Paths against Discord's ceiling of 25 components means this has to page. It
pages by category rather than by arithmetic: a page that stops halfway through
the combat Paths for no reason is harder to scan than three pages that each
mean something.
"""

import discord

from bot import database as db
from bot.views import AnsweringView
from bot.formatting import COLOUR_INFO, embed

PATHS_PER_ROW = 5
BUTTON_ROWS = 4  # the fifth row is navigation
PICKER_TIMEOUT = 180


async def fetch_paths() -> list[dict]:
    return await db.fetch_all(
        "SELECT code, name, category, emoji, uses_matchups, description "
        "FROM paths ORDER BY sort_order"
    )


def build_pages(paths: list[dict]) -> list[tuple[str, list[dict]]]:
    """Three pages, each one a group a player would think of as a group.

    Combat is 21 Paths and a page holds 20, so it splits in half rather than
    spilling a single Path onto the end of the special/exotic page.
    """
    combat = [p for p in paths if p["category"] == "combat"]
    rest = [p for p in paths if p["category"] != "combat"]
    half = (len(combat) + 1) // 2
    return [
        ("Combat I", combat[:half]),
        ("Combat II", combat[half:]),
        ("Special & Exotic", rest),
    ]


class PathButton(discord.ui.Button):
    def __init__(self, picker: "PathPicker", path: dict, row: int) -> None:
        self.picker = picker
        self.path = path
        super().__init__(
            label=path["name"].replace(" Path", ""),
            emoji=path["emoji"],
            row=row,
            style=(
                discord.ButtonStyle.success
                if path["code"] == picker.highlight
                else discord.ButtonStyle.secondary
            ),
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        card = await self.picker.on_pick(self.path)
        self.picker.highlight = self.path["code"]
        self.picker.render()
        await interaction.response.edit_message(embed=card, view=self.picker)


class PageButton(discord.ui.Button):
    def __init__(self, picker: "PathPicker", step: int, glyph: str) -> None:
        self.picker = picker
        self.step = step
        super().__init__(label=glyph, row=BUTTON_ROWS, style=discord.ButtonStyle.primary)

    async def callback(self, interaction: discord.Interaction) -> None:
        # Wraps rather than disabling at the ends: three pages is few enough
        # that going back from the first should land on the last.
        self.picker.page = (self.picker.page + self.step) % len(self.picker.pages)
        self.picker.render()
        await interaction.response.edit_message(
            embed=self.picker.prompt(), view=self.picker
        )


class PathPicker(AnsweringView):
    """Base class. Subclasses supply `on_pick` and, optionally, extra buttons."""

    prompt_title = "Choose a Path"
    prompt_body = ""

    def __init__(
        self,
        user: discord.abc.User,
        paths: list[dict],
        *,
        highlight: str | None = None,
    ) -> None:
        super().__init__(timeout=PICKER_TIMEOUT)
        self.user = user
        self.pages = build_pages(paths)
        self.highlight = highlight
        self.page = 0
        # Open on the page holding whatever is highlighted, so it is visible
        # rather than two clicks away.
        for index, (_, members) in enumerate(self.pages):
            if any(p["code"] == highlight for p in members):
                self.page = index
                break
        self.render()

    async def on_pick(self, path: dict) -> discord.Embed:
        raise NotImplementedError

    def extra_items(self) -> list[discord.ui.Item]:
        """Buttons for the navigation row beyond paging. Empty by default."""
        return []

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "That is not yours to press. Run the command yourself.",
                ephemeral=True,
            )
            return False
        return True

    def render(self) -> None:
        """Rebuild every component from scratch.

        Cheaper to reason about than mutating labels and styles in place, and
        the highlight then lands on the right button by construction.
        """
        self.clear_items()
        _, members = self.pages[self.page]
        for index, path in enumerate(members):
            self.add_item(
                PathButton(self, path, min(index // PATHS_PER_ROW, BUTTON_ROWS - 1))
            )
        self.add_item(PageButton(self, -1, "\N{BLACK LEFT-POINTING TRIANGLE}"))
        self.add_item(PageButton(self, +1, "\N{BLACK RIGHT-POINTING TRIANGLE}"))
        for item in self.extra_items():
            self.add_item(item)

    def prompt(self) -> discord.Embed:
        title, members = self.pages[self.page]
        card = embed(self.prompt_title, self.prompt_body, colour=COLOUR_INFO)
        card.add_field(
            name=f"{title}  ({self.page + 1}/{len(self.pages)})",
            value=" ".join(
                f"{p['emoji']} {p['name'].replace(' Path', '')}" for p in members
            ),
            inline=False,
        )
        return card

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True
