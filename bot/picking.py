"""Lists longer than Discord will show.

A select holds 25 options and not one more. Every screen in this bot that
lists what a player owns was written with `rows[:25]` on the end of it, which
is not a limit so much as a quiet disappearance: the 26th pill, the 26th Gu,
the 26th piece of gear were not merely unreachable, they were unmentioned.
And the ones cut were whichever sorted last, so a player collecting a set
would watch the newest thing never arrive.

The fix has two halves, and both belong here rather than in nine screens.

**Order.** Sorted by type, then by strength descending inside it. Type first
because "my healing pills" is how a player thinks about a shelf; strength
descending because within a type the strongest is nearly always the one being
looked for. A flat alphabetical list is only useful to somebody who already
knows the name of the thing they want.

**Pages.** 25 at a time, with the page turned by two buttons that appear only
when there is a second page. Wrapping rather than disabling at the ends, the
way `pathpicker` already does it - going back from the first page landing on
the last is what somebody hunting through four pages actually wants.

A screen opts in by holding a `page`, calling `page_of()` when it builds its
select, and adding `PageButtons` when `page_count()` says there is more than
one. Nothing here knows what is being listed.
"""

from typing import Any, Callable, Iterable, Sequence

import discord

from bot.views import AnsweringModal, AnsweringView

# Discord's ceiling on a select, and the reason this module exists. It is a
# default rather than the law: an embed's ceiling is its 4096 characters, which
# a screen drawing three lines per row reaches a long way before 25 of them.
PER_PAGE = 25


def page_count(rows: Sequence[Any], per_page: int = PER_PAGE) -> int:
    return max(1, -(-len(rows) // per_page))


def page_of(rows: Sequence[Any], page: int, per_page: int = PER_PAGE) -> list[Any]:
    """The slice a select may show. Out-of-range pages wrap rather than empty."""
    if not rows:
        return []
    page %= page_count(rows, per_page)
    return list(rows[page * per_page:(page + 1) * per_page])


def by_type_and_strength(
    rows: Iterable[dict],
    *,
    kind: Callable[[dict], Any],
    strength: Callable[[dict], Any],
    name: Callable[[dict], str] = lambda r: str(r.get("name", "")),
) -> list[dict]:
    """Group by type, strongest first inside each, ties broken by name.

    `strength` returns whatever sorts - a number, or a tuple for "rank, then
    stars". It is negated by sorting descending rather than by asking callers
    to remember a minus sign, because a caller who forgets one produces a list
    that is subtly backwards and looks fine.
    """
    return sorted(
        rows, key=lambda r: (str(kind(r)), _Descending(strength(r)), name(r))
    )


class _Descending:
    """Sorts a value backwards without requiring it to be a number.

    `strength` may be a tuple like (rank, stars), which cannot simply be
    negated. Reversing the whole sort is not an option either - it would put
    the type names in reverse order too.
    """

    __slots__ = ("value",)

    def __init__(self, value: Any) -> None:
        self.value = value

    def __lt__(self, other: "_Descending") -> bool:
        return other.value < self.value

    def __eq__(self, other: object) -> bool:
        return isinstance(other, _Descending) and other.value == self.value


class PageButton(discord.ui.Button):
    """One step through a paged view.

    The view it belongs to must hold a `page`, know how many `page_count()`
    there are, and `build()` its own components.

    `card()` is optional. A screen with an embed supplies one - and it may be
    a coroutine, because half the screens in this bot build their embed with a
    query in it. An ephemeral one-shot menu has no embed at all, and for those
    turning the page redraws only the components.
    """

    def __init__(self, screen: discord.ui.View, step: int, glyph: str, row: int) -> None:
        self.screen = screen
        self.step = step
        super().__init__(label=glyph, row=row, style=discord.ButtonStyle.primary)

    async def callback(self, interaction: discord.Interaction) -> None:
        self.screen.page = (self.screen.page + self.step) % self.screen.page_count()
        self.screen.build()

        draw = getattr(self.screen, "card", None)
        if draw is None:
            await interaction.response.edit_message(view=self.screen)
            return

        card = draw()
        if hasattr(card, "__await__"):
            card = await card
        await interaction.response.edit_message(embed=card, view=self.screen)


def add_page_buttons(screen: discord.ui.View, *, row: int = 4) -> None:
    """Two buttons, and only when they would do something."""
    if screen.page_count() > 1:
        screen.add_item(PageButton(screen, -1, "\N{LEFTWARDS BLACK ARROW}", row))
        screen.add_item(PageButton(screen, 1, "\N{BLACK RIGHTWARDS ARROW}", row))


def page_note(
    rows: Sequence[Any], page: int, noun: str = "items", per_page: int = PER_PAGE
) -> str:
    """What the footer says about a list that did not fit.

    Empty when everything fits, so a screen can append it unconditionally and
    stay silent in the common case. `noun` is written as the caller wants it
    read - an appended "s" turns "jar entry" into "jar entrys".
    """
    pages = page_count(rows, per_page)
    if pages <= 1:
        return ""
    shown = page_of(rows, page, per_page)
    first = (page % pages) * per_page + 1
    return (
        f"Page {page % pages + 1} of {pages} \N{BULLET} "
        f"{noun} {first}\N{EN DASH}{first + len(shown) - 1} of {len(rows)}"
    )


def _searchable(row) -> str:
    """The text a row is found by.

    Rows come from five different cogs and none of them share a shape, so this
    tries the names they actually use before falling back to the whole row.
    """
    for key in ("name", "label", "ref", "code"):
        try:
            value = row[key]
        except (KeyError, TypeError, IndexError):
            continue
        if value:
            return str(value)
    return str(row)


class FindModal(AnsweringModal):
    """Type part of a name instead of paging to it."""

    def __init__(self, screen: "PagedPicker") -> None:
        super().__init__(title=f"Find among your {screen.noun}")
        self.screen = screen
        self.term = discord.ui.TextInput(
            label="Part of the name",
            placeholder="key",
            required=False,
            max_length=60,
        )
        self.add_item(self.term)

    async def on_submit(self, interaction: discord.Interaction) -> None:
        self.screen.term = str(self.term.value).strip()
        self.screen.page = 0
        self.screen.build()
        await interaction.response.edit_message(view=self.screen)


class FindButton(discord.ui.Button):
    def __init__(self, screen: "PagedPicker") -> None:
        self.screen = screen
        showing = screen.term
        super().__init__(
            label=(f'"{showing}" \N{MULTIPLICATION SIGN}' if showing else "Find\N{HORIZONTAL ELLIPSIS}"),
            emoji=None if showing else "\N{LEFT-POINTING MAGNIFYING GLASS}",
            style=discord.ButtonStyle.primary if showing else discord.ButtonStyle.secondary,
            row=2,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        # A live search is cleared by pressing it; an empty one opens the box.
        if self.screen.term:
            self.screen.term = ""
            self.screen.page = 0
            self.screen.build()
            await interaction.response.edit_message(view=self.screen)
        else:
            await interaction.response.send_modal(FindModal(self.screen))


class PagedPicker(AnsweringView):
    """A one-shot ephemeral menu, however long the list behind it is.

    It used to take a built select and show whatever fitted, which meant the
    26th thing you owned could not be chosen and was not mentioned. It takes
    the rows and a way to build a select from one page of them instead.

    Paging made everything reachable and did not make anything findable: a
    cultivator with eighty-one kinds of material looking for their Dungeon Keys
    was four pages of guessing away from them. So it also searches.

    Every cog had its own copy of this. They differed only in which base class
    answered a refusal raised inside the select, which is what `on_error` is
    for - subclass it, delegate, and inherit the paging.
    """

    def __init__(
        self,
        make_select: Callable[[list], discord.ui.Select],
        rows: list,
        *,
        noun: str = "items",
        timeout: float = 180,
    ) -> None:
        super().__init__(timeout=timeout)
        self.make_select = make_select
        self.rows = rows
        self.noun = noun
        self.page = 0
        self.term = ""
        self.build()

    def showing(self) -> list:
        if not self.term:
            return self.rows
        needle = self.term.casefold()
        found = [r for r in self.rows if needle in _searchable(r).casefold()]
        # A search that finds nothing shows everything rather than an empty
        # menu, which discord.py refuses to render at all.
        return found or self.rows

    def page_count(self) -> int:
        return page_count(self.showing())

    def build(self) -> None:
        self.clear_items()
        rows = self.showing()
        self.add_item(self.make_select(page_of(rows, self.page)))
        add_page_buttons(self, row=1)
        # Only worth offering when there is more than one screenful to hunt
        # through; below that the menu already shows everything.
        if len(self.rows) > PER_PAGE:
            self.add_item(FindButton(self))
