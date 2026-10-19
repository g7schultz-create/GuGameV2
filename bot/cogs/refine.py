"""Refinement: /refine.

Tier is what you put in; harmony is how much of it survived. The pages' total
power decides the finished manual's tier, and harmony multiplies the budget
that tier grants - so a manual refined at 90+ harmony is worth more than its
tier says, and one scraped together at 40 is worth considerably less.

That is why `manual_total_bonus` is a function and not a CHECK constraint:
exceeding the tier budget is the reward for refining well, not a bug.
"""

import discord
import psycopg
from discord import app_commands
from discord.ext import commands

from bot import database as db
from bot.character import RARITY_MARK
from bot.cogs.manuals import bonus_lines
from bot.formatting import (
    COLOUR_BAD,
    COLOUR_GOOD,
    COLOUR_INFO,
    embed,
    percent,
    thousands,
)
from bot.picking import (
    add_page_buttons,
    by_type_and_strength,
    page_count,
    page_note,
    page_of,
)
from bot.views import AnsweringView
from bot.players import GameError, require_player

HARMONY_BANDS = (
    (100, "Dao Resonance", COLOUR_GOOD),
    (90, "Perfect Harmony", COLOUR_GOOD),
    (75, "Excellent", COLOUR_GOOD),
    (60, "Good", COLOUR_INFO),
    (40, "Stable", COLOUR_INFO),
    (20, "Poor", COLOUR_INFO),
)


def harmony_band(value: int) -> tuple[str, discord.Colour]:
    for threshold, label, colour in HARMONY_BANDS:
        if value >= threshold:
            return label, colour
    return "Chaotic", COLOUR_BAD


async def render_refinement(result: dict) -> discord.Embed:
    label, colour = harmony_band(result["harmony"])

    if not result["succeeded"]:
        card = embed(
            "Refinement failure",
            "The pages reject one another.\n\n"
            f"Harmony **{result['harmony']}** — {label}",
            colour=COLOUR_BAD,
        )
        card.add_field(
            name="Lost",
            value=f"{result['destroyed']} page(s). The rest survived.",
            inline=False,
        )
        card.add_field(
            name="Learned anyway",
            value=f"+{result['exp_gained']} Refinement EXP — "
            f"level {result['level_after']}.",
            inline=False,
        )
        card.set_footer(text="Even a failure teaches the shape of the mistake.")
        return card

    manual = await db.fetch_one(
        """
        SELECT m.*, mt.bonus_budget,
               string_agg(DISTINCT p.name, ' / ') AS paths,
               string_agg(DISTINCT t.name, ', ') AS unlocks
        FROM manuals m
        JOIN manual_tiers mt ON mt.tier = m.tier
        LEFT JOIN manual_paths mp ON mp.manual_id = m.manual_id
        LEFT JOIN paths p ON p.code = mp.path_code
        LEFT JOIN manual_techniques mtq ON mtq.manual_id = m.manual_id
        LEFT JOIN techniques t ON t.technique_id = mtq.technique_id
        WHERE m.manual_id = %s
        GROUP BY m.manual_id, mt.bonus_budget
        """,
        (result["manual_id"],),
    )

    card = embed(
        f"{RARITY_MARK.get(result['quality'], '')} {result['manual_name']}",
        f"{result['quality'].title()} tier {result['tier']} "
        f"{result['archetype']} manual\n"
        f"Harmony **{result['harmony']}** — {label}",
        colour=colour,
    )
    card.add_field(name="Paths", value=manual["paths"] or "Untyped.", inline=False)

    granted, _ = bonus_lines(manual)
    card.add_field(
        name="While equipped",
        value="\n".join(granted) or "Nothing worth carrying.",
        inline=False,
    )

    retained = float(result["retained"])
    budget = float(manual["bonus_budget"])
    lift = await db.fetch_value(
        "SELECT budget_multiplier FROM manual_qualities WHERE rarity = %s",
        (result["quality"],),
    )
    card.add_field(
        name="Retention",
        value=(
            f"{percent(retained - 1)} of the pages' potential survived.\n"
            f"A Tier {result['tier']} budget of {percent(budget, signed=False)} "
            f"became {percent(budget * retained, signed=False)}."
        ),
        inline=False,
    )
    # The last roll is the part worth naming: harmony bought the draws, and
    # this is what came up.
    card.add_field(
        name="The last roll",
        value=(
            f"{result['draws']} draw(s) at the ladder \N{RIGHTWARDS ARROW} "
            f"{RARITY_MARK.get(result['quality'], '')} "
            f"**{result['quality'].title()}**"
            + (f", worth {percent(float(lift) - 1)} on top." if lift and float(lift) > 1
               else " — the common end of it.")
        ),
        inline=False,
    )
    if manual["unlocks"]:
        card.add_field(name="Unlocks", value=manual["unlocks"], inline=False)

    card.set_footer(
        text=f"+{result['exp_gained']} Refinement EXP — level "
        f"{result['level_after']}. /equipment to carry it."
    )
    return card


# The bands `pair_harmony` returns, read the way /alchemy and /forge read them
# so one player learns one vocabulary.
AGREEMENT = (
    (8, "\N{WHITE HEAVY CHECK MARK}", "agrees"),
    (1, "\N{WHITE MEDIUM SQUARE}", "no quarrel"),
    (-15, "\N{WARNING SIGN}", "fights"),
)


def agreement_word(value) -> str:
    for threshold, icon, word in AGREEMENT:
        if value >= threshold:
            return f"{icon} {word}"
    return "\N{CROSS MARK} ruins it"


async def render_forecast(player_id: int, page_ids: list[int]) -> discord.Embed:
    """What the pages are worth, before anything is spent.

    Every number here comes out of `refine_forecast()`, which is the same
    function `refine()` calls — so this cannot promise a tier the refinement
    then fails to produce.

    What it deliberately does NOT show is the outcome. Eight points of the
    harmony are a roll, and a screen that showed the finished manual before
    asking permission would be a free reroll: decline, refine again, keep the
    good one. So this is a range and a shape, and the dice come after Refine.
    """
    look = await db.fetch_one(
        """
        SELECT f.*,
               (SELECT rr.label FROM refinement_retention rr
                WHERE rr.min_harmony <= round(f.base_harmony)
                ORDER BY rr.min_harmony DESC LIMIT 1)          AS band,
               refinement_keep(round(f.base_harmony)::smallint) AS keep,
               manual_quality_draws(round(f.base_harmony)::smallint) AS draws,
               mt.bonus_budget,
               game_config_value('refinement_failure_threshold') AS threshold
        FROM refine_forecast(%s, %s) f
        JOIN manual_tiers mt ON mt.tier = f.forecast_tier
        """,
        (player_id, page_ids),
    )
    if look is None:
        raise GameError("Those pages could not be read.")

    paths = await db.fetch_all(
        """
        SELECT DISTINCT p.name, p.emoji,
               pair_harmony(mp.path_code, %s) AS agreement
        FROM manual_pages mp
        JOIN paths p ON p.code = mp.path_code
        WHERE mp.page_id = ANY (%s) AND mp.path_code <> %s
        ORDER BY agreement
        """,
        (look["dominant"], page_ids, look["dominant"]),
    )
    lead = await db.fetch_one(
        "SELECT name, emoji FROM paths WHERE code = %s", (look["dominant"],)
    )

    base = float(look["base_harmony"])
    low, high = max(0, round(base - 4)), min(140, round(base + 4))
    doomed = high < float(look["threshold"])

    card = embed(
        f"Refine {look['pages']} page(s)?",
        "This is what they are worth **before** the last eight points of luck.",
        colour=COLOUR_BAD if doomed else COLOUR_INFO,
    )
    card.add_field(
        name="Becomes",
        value=(
            f"A **tier {look['forecast_tier']}** {look['archetype']} manual\n"
            f"{lead['emoji']} led by the **{lead['name']}** "
            f"\N{BULLET} {thousands(look['total_power'])} page power"
        ),
        inline=False,
    )
    card.add_field(
        name="Harmony",
        value=(
            f"**{low}–{high}** \N{BULLET} likely *{look['band']}*\n"
            f"Keeps **{percent(float(look['keep']), signed=False)}** of a tier "
            f"{look['forecast_tier']} budget — "
            f"{percent(float(look['bonus_budget']) * float(look['keep']), signed=False)}"
            " to spread across its bonuses."
        ),
        inline=False,
    )
    # Whether this pile teaches a move, and which. Derived from the page ids
    # rather than rolled, so what the bench promises here is exactly what the
    # refining produces - `refine` asks the same `refine_technique_for`.
    move = await db.fetch_one(
        "SELECT * FROM refine_technique_preview(%s, %s)", (player_id, page_ids)
    )
    if move and move["carries"]:
        card.add_field(
            name="\N{CLOSED BOOK} It will teach a technique",
            value=(
                f"**{move['name']}** \N{BULLET} rank {move['rank']}\n"
                f"{thousands(move['power'])} base power"
                + (f" \N{BULLET} {move['path_name']}" if move["path_name"] else "")
                + f"\n*Because {move['reason']}.*"
            ),
            inline=False,
        )
    elif move:
        card.add_field(
            name="\N{CLOSED BOOK} No technique",
            value=f"*{move['reason'].capitalize()}.*",
            inline=False,
        )

    if paths:
        card.add_field(
            name=f"Against the {lead['name']}, which leads",
            value="\n".join(
                f"{agreement_word(p['agreement'])} \N{BULLET} {p['emoji']} {p['name']}"
                for p in paths
            ),
            inline=False,
        )
    else:
        card.add_field(
            name="Agreement",
            value=f"All of it is the {lead['name']}. Nothing on the bench argues.",
            inline=False,
        )

    card.add_field(
        name="The last roll",
        value=(
            f"**{look['draws']}** draw(s) at the quality ladder — common through "
            "extreme, and the best of them is the one you keep. Every 25 harmony "
            "buys another."
        ),
        inline=False,
    )
    if doomed:
        card.add_field(
            name="\N{WARNING SIGN} This will fail",
            value=f"Below **{int(look['threshold'])}** the pages reject one "
            "another and a third of them are lost. Take the arguing Path out.",
            inline=False,
        )
    card.set_footer(text="Nothing is spent until you press Refine.")
    return card


# How the shelf may be arranged, and what each arrangement is worth.
#
# These are not three cosmetic sorts. `refine_forecast` scores a batch with
#
#     + 6   per extra page of the leading Path
#     - 5   per additional distinct Path
#     + 5   per repeated page type
#     - 3.5 per tier of spread between the highest and lowest page
#
# so each grouping brings together the pages that pay each of those terms.
# Path first because +6 against -5 is the widest swing of the three.
GROUPINGS = (
    ("path", "By Path", "path_name", "+6 each, and no -5 for a stranger"),
    ("type", "By type", "type_name", "+5 for every repeat"),
    ("tier", "By tier", "tier", "no -3.5 for a spread"),
)


class PageSelect(discord.ui.Select):
    """The pages themselves, ticked up across as many screens as it takes.

    A refinement takes two or more pages and Discord posts a multi-select's
    values only when it is submitted, so this used to send straight to the
    forecast and a batch could only ever be drawn from one screenful. Tick two
    on this page, turn to the next, come back, and they were bare again -
    which is what a refiner holding five hundred pages ran into every time.

    So the ticks are kept by the screen rather than by the select. Each page
    answers for its own pages and for none of the others, exactly the way
    `PathFilter` handles Paths that do not fit in one slice, and a separate
    button sends the batch off once there are two of them.
    """

    def __init__(self, view: "RefineView", pages: list[dict]) -> None:
        self.refinery = view
        self.shown = [p["page_id"] for p in pages]
        total = len(view.visible_pages())
        arranged = next(
            label for code, label, _, _ in GROUPINGS if code == view.group
        ).lower()
        picked = view.picked
        super().__init__(
            placeholder=(
                (f"{len(picked)} picked \N{BULLET} " if picked else "")
                + f"Pick up to {view.cap} pages, {arranged}"
                + (f" ({len(pages)} of {total} here)" if total > len(pages) else "")
            )[:150],
            row=0,
            # Nothing ticked is a real answer here: it is how a page ticked
            # earlier is taken back off.
            min_values=0,
            max_values=max(1, min(view.cap, len(pages), 25)),
            options=[
                discord.SelectOption(
                    label=(
                        f"T{p['tier']} {p['path_name'].replace(' Path', '')} "
                        f"{p['type_name']}"
                    )[:100],
                    value=str(p["page_id"]),
                    default=p["page_id"] in picked,
                    description=(
                        f"power {p['power']}, quality {p['quality']}%"
                        + (f" · {p['trait_name']}" if p["trait_name"] else "")
                    )[:100],
                )
                for p in pages
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        self.refinery.apply_page_choice(self.shown, [int(v) for v in self.values])
        self.refinery.build()
        await interaction.response.edit_message(
            embed=self.refinery.card(), view=self.refinery
        )


class RefineNowButton(discord.ui.Button):
    """Sends off what has been ticked, from however many screens it took."""

    def __init__(self, screen: "RefineView") -> None:
        self.screen = screen
        n = len(screen.picked)
        over = n > screen.cap
        super().__init__(
            label=(
                f"Refine {n} pages" if 2 <= n <= screen.cap
                else f"{n} picked \N{EM DASH} {screen.cap} at most" if over
                else f"Pick {2 - n} more" if n < 2
                else f"Refine {n} pages"
            )[:80],
            emoji="\N{ALEMBIC}",
            style=(
                discord.ButtonStyle.success
                if 2 <= n <= screen.cap
                else discord.ButtonStyle.secondary
            ),
            disabled=not (2 <= n <= screen.cap),
            row=2,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        chosen = self.screen.ordered_picks()
        confirm = ConfirmView(self.screen.player_id, self.screen.user, chosen)
        await interaction.response.edit_message(
            embed=await render_forecast(self.screen.player_id, chosen),
            view=confirm,
        )
        self.screen.stop()


class ClearPicksButton(discord.ui.Button):
    """Ticks made on a screen you have since paged away from can only be taken
    off from that screen, so there has to be one place that clears all of
    them."""

    def __init__(self, screen: "RefineView") -> None:
        self.screen = screen
        super().__init__(
            label="Clear picks",
            style=discord.ButtonStyle.secondary,
            disabled=not screen.picked,
            row=2,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        self.screen.picked.clear()
        self.screen.build()
        await interaction.response.edit_message(
            embed=self.screen.card(), view=self.screen
        )


class ConfirmView(AnsweringView):
    """The pages are chosen; nothing is spent yet.

    A separate view rather than another button on the picker, because the
    choice has been made by the time this appears and re-opening the select
    would invite a second set of pages onto a screen describing the first.
    """

    def __init__(self, player_id: int, user: discord.abc.User, pages: list[int]) -> None:
        super().__init__(timeout=180)
        self.player_id = player_id
        self.user = user
        self.pages = pages

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "Those are not your pages.", ephemeral=True
            )
            return False
        return True

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True

    @discord.ui.button(label="Refine", style=discord.ButtonStyle.success)
    async def go(self, interaction: discord.Interaction, button) -> None:
        try:
            result = await db.fetch_one(
                "SELECT * FROM refine(%s, %s)", (self.player_id, self.pages)
            )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0]) from exc

        for item in self.children:
            item.disabled = True
        await interaction.response.edit_message(
            embed=await render_refinement(result), view=self
        )
        self.stop()

    @discord.ui.button(label="Back off", style=discord.ButtonStyle.secondary)
    async def stop_it(self, interaction: discord.Interaction, button) -> None:
        for item in self.children:
            item.disabled = True
        await interaction.response.edit_message(
            embed=embed(
                "Left on the bench",
                "The pages are where you left them. **/refine** when you want them.",
                colour=COLOUR_INFO,
            ),
            view=self,
        )
        self.stop()


def render_shelf(
    pages: list[dict], group: str, page: int, cap: int,
    filtered: list[str] | None = None,
    picked: list[dict] | None = None,
) -> discord.Embed:
    """The shelf, arranged the way the buttons say.

    The counts matter more than the list: "you hold four Fire pages" is what
    tells somebody there is a good refinement available, and it is exactly
    the number the +6 term is paid on.
    """
    label, key, why = next(
        (label, key, why) for code, label, key, why in GROUPINGS if code == group
    )

    card = embed(
        "Refinement",
        "Pages of one Path refine easily. Paths that fight each other in "
        "the matchup chart fight each other on the page too \N{EM DASH} and a "
        "skilled refiner can turn that conflict into something neither page "
        "could have been alone.",
        colour=COLOUR_INFO,
    )

    # Biggest group first: it is the one worth refining.
    tally: dict[str, int] = {}
    for entry in pages:
        name = f"Tier {entry['tier']}" if key == "tier" else entry[key]
        tally[name] = tally.get(name, 0) + 1
    ranked = sorted(tally.items(), key=lambda kv: (-kv[1], kv[0]))

    card.add_field(
        name=f"{label} \N{BULLET} {why}",
        value="\n".join(
            f"**{n}** \N{MULTIPLICATION SIGN} {name}"
            + ("  \N{WHITE HEAVY CHECK MARK}" if n >= 2 else "")
            for name, n in ranked[:10]
        )
        + (
            f"\n*\N{HORIZONTAL ELLIPSIS} and {len(ranked) - 10} more*"
            if len(ranked) > 10
            else ""
        ),
        inline=False,
    )
    if not any(n >= 2 for _, n in ranked):
        card.add_field(
            name="Nothing pairs, arranged this way",
            value="Every group holds one page. Try another arrangement \N{EM DASH} "
            "a batch of strangers still refines, it just scores badly.",
            inline=False,
        )

    if filtered:
        card.add_field(
            name=f"Showing {len(filtered)} Path(s)",
            value=", ".join(f"**{name.replace(' Path', '')}**" for name in filtered)
            + f"  \N{BULLET}  {len(pages)} page(s)"
            + (
                "\n*"
                + ("Nothing here at all" if not pages else "Only one page here")
                + " \N{EM DASH} a refinement needs two, so add another Path.*"
                if len(pages) < 2
                else ""
            ),
            inline=False,
        )

    # What is ticked, wherever it was ticked. The select can only show the
    # screen it is on, so this is the only place a batch gathered across four
    # pages is visible as one thing.
    if picked:
        card.add_field(
            name=f"In the cauldron \N{BULLET} {len(picked)} of {cap}",
            value="\n".join(
                f"**T{p['tier']}** {p['path_name'].replace(' Path', '')} "
                f"{p['type_name'].lower()} \N{BULLET} power {p['power']}, "
                f"quality {p['quality']}%"
                for p in picked[:cap]
            )
            + (
                f"\n*\N{HORIZONTAL ELLIPSIS} and {len(picked) - cap} over the "
                f"limit \N{EM DASH} untick some.*"
                if len(picked) > cap
                else ""
            ),
            inline=False,
        )

    note = page_note(pages, page, "pages")
    card.set_footer(
        text=(note + " \N{BULLET} " if note else "")
        + f"Up to {cap} pages at once. Ticks are kept as you turn the page, "
        "so a batch can be gathered from anywhere on the shelf. "
        + ("Narrow it with the Path slot below. " if not filtered else "")
        + "Tier comes from total page power; harmony decides how much of "
        "that tier's budget you get."
    )
    return card


PATHS_PER_SLICE = 25


class PathFilter(discord.ui.Select):
    """Which Paths the shelf is showing. The second slot on this screen.

    `PageSelect` can only refine what is in front of it - Discord posts a
    multi-select's values on submit, so turning the page throws away what was
    ticked on the one before. That was survivable at twenty pages and absurd
    at five hundred: a refiner holding pages in all 34 Paths could only
    combine Lightning with Wind if the two happened to land in the same slice
    of 25, and had no way to make them.

    So the arrangement buttons say how the shelf is *sorted* and this says
    what is *on* it. Tick Lightning and Wind here and every page of both is in
    one list, which is the list `PageSelect` is allowed to draw from.

    Multi-select, and each slice governs only its own Paths - so a Path
    chosen on an earlier slice stays chosen. Nothing is submitted twice and
    nothing is silently dropped.
    """

    def __init__(self, view: "RefineView", held: list[tuple[str, str, int]]) -> None:
        self.refinery = view
        shown = view.path_slice(held)
        chosen = view.chosen_paths
        super().__init__(
            placeholder=(
                "Which Paths? "
                + (f"({len(chosen)} chosen)" if chosen else "all of them")
                + (f" \N{BULLET} {view.path_slice_note(held)}"
                   if len(held) > PATHS_PER_SLICE else "")
            )[:150],
            row=3,
            # Nothing ticked is a real answer: it means this slice contributes
            # no Paths, which is how a filter is taken back off.
            min_values=0,
            max_values=len(shown),
            options=[
                discord.SelectOption(
                    label=f"{name.replace(' Path', '')} \N{MULTIPLICATION SIGN}{n}"[:100],
                    value=code,
                    default=code in chosen,
                    description=f"{n} page(s) held"
                    + ("" if n >= 2 else " \N{EM DASH} refines as a stranger"),
                )
                for code, name, n in shown
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        self.refinery.apply_path_choice(self.values)
        self.refinery.build()
        await interaction.response.edit_message(
            embed=self.refinery.card(), view=self.refinery
        )


class TypeFilter(discord.ui.Select):
    """Which KINDS of page the shelf is showing. The third slot.

    Path was the only axis, and it is the wrong one on its own: a refiner
    who wants a Refinement manual holds Refinement pages scattered across a
    dozen Paths, and a refiner aiming at one Path still has to pick out the
    Attack pages from the Cultivation ones by eye. The two questions are
    independent - which Path the manual leans on, and what the pages TEACH -
    so they get a filter each and compose.

    Eleven kinds fit one select outright, so unlike the Paths this needs no
    slicing. Multi-select and `min_values=0`, the same as the Path filter:
    ticking nothing is how a filter is taken back off.
    """

    def __init__(self, view: "RefineView", held: list[tuple[str, str, int]]) -> None:
        self.refinery = view
        chosen = view.chosen_types
        super().__init__(
            placeholder=(
                "Which kinds of page? "
                + (f"({len(chosen)} chosen)" if chosen else "all of them")
            )[:150],
            row=1,
            min_values=0,
            max_values=len(held),
            options=[
                discord.SelectOption(
                    label=f"{name} \N{MULTIPLICATION SIGN}{n}"[:100],
                    value=code,
                    default=code in chosen,
                    description=f"{n} page(s) held"
                    + ("" if n >= 2 else " \N{EM DASH} refines as a stranger"),
                )
                for code, name, n in held
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        self.refinery.chosen_types = set(self.values)
        self.refinery.page = 0
        self.refinery.build()
        await interaction.response.edit_message(
            embed=self.refinery.card(), view=self.refinery
        )


class ClearFilter(discord.ui.Button):
    def __init__(self, screen: "RefineView") -> None:
        self.screen = screen
        super().__init__(
            # It clears both axes now, so naming one of them would be a lie
            # about what pressing it does.
            label="Clear filters",
            row=2,
            style=discord.ButtonStyle.secondary,
            disabled=not (screen.chosen_paths or screen.chosen_types),
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        self.screen.chosen_paths.clear()
        self.screen.chosen_types.clear()
        self.screen.page = 0
        self.screen.build()
        await interaction.response.edit_message(
            embed=self.screen.card(), view=self.screen
        )


class PathSliceButton(discord.ui.Button):
    """More Paths than a select holds. Only appears when that is true."""

    def __init__(self, screen: "RefineView", step: int, glyph: str) -> None:
        self.screen = screen
        self.step = step
        super().__init__(label=glyph, row=4, style=discord.ButtonStyle.primary)

    async def callback(self, interaction: discord.Interaction) -> None:
        slices = self.screen.path_slice_count()
        self.screen.path_page = (self.screen.path_page + self.step) % slices
        self.screen.build()
        await interaction.response.edit_message(
            embed=self.screen.card(), view=self.screen
        )


class GroupButton(discord.ui.Button):
    """Rearrange the shelf. It does not change what is on it."""

    def __init__(self, screen: "RefineView", code: str, label: str) -> None:
        self.screen = screen
        self.code = code
        super().__init__(
            label=label,
            # Row 4 since the kind filter took row 1. Sorting and filtering
            # are different questions and the screen now has one row each.
            row=4,
            style=(
                discord.ButtonStyle.success
                if code == screen.group
                else discord.ButtonStyle.secondary
            ),
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        self.screen.group = self.code
        self.screen.page = 0
        self.screen.build()
        await interaction.response.edit_message(
            embed=self.screen.card(), view=self.screen
        )


class RefineView(AnsweringView):
    def __init__(self, player_id: int, user: discord.abc.User, pages, cap: int) -> None:
        super().__init__(timeout=300)
        self.player_id = player_id
        self.user = user
        self.pages = pages
        self.cap = cap
        self.page = 0
        # Path is the default because it is the widest swing on the score.
        self.group = "path"
        # Empty means every Path, which is what the screen opens on.
        self.chosen_paths: set[str] = set()
        # And the same for what the pages TEACH. Independent of the Path: a
        # Refinement manual is made of Refinement pages whatever Paths they
        # came from, and a single-Path pile still has half a dozen kinds in it.
        self.chosen_types: set[str] = set()
        self.path_page = 0
        # Pages ticked so far, across however many screens they came from.
        # The select cannot hold this: Discord hands back only what was on the
        # screen that was submitted.
        self.picked: set[int] = set()
        self.build()

    def held_paths(self) -> list[tuple[str, str, int]]:
        """The Paths this refiner actually holds pages in, fullest first.

        Ordered by how many rather than by `sort_order`, because the question
        the filter answers is "what do I have enough of to refine" - and with
        more Paths than a select holds, the ones worth refining have to be on
        the first slice rather than wherever the canon order puts them.
        """
        tally: dict[str, tuple[str, int]] = {}
        for entry in self.pages:
            name, n = tally.get(entry["path_code"], (entry["path_name"], 0))
            tally[entry["path_code"]] = (name, n + 1)
        return sorted(
            ((code, name, n) for code, (name, n) in tally.items()),
            key=lambda row: (-row[2], row[1]),
        )

    def pinned_paths(
        self, held: list[tuple[str, str, int]] | None = None
    ) -> list[tuple[str, str, int]]:
        """The Paths already chosen, which every slice carries.

        Without this a Path chosen on one slice is invisible on the next: the
        filter is still applied and the shelf is still narrowed, but the
        dropdown shows nothing ticked, which reads as the filter having been
        cleared by turning the page. It also means the only way to UNTICK a
        Path was to find the slice it came from.

        Truncated if somebody has chosen more Paths than a select holds. Ones
        that fall off stay chosen, because `apply_path_choice` only forgets
        what it can see.
        """
        held = self.held_paths() if held is None else held
        return [row for row in held if row[0] in self.chosen_paths][
            : PATHS_PER_SLICE - 1
        ]

    def browsable_paths(
        self, held: list[tuple[str, str, int]] | None = None
    ) -> list[tuple[str, str, int]]:
        """The rest, which is what the slice arrows actually walk through."""
        held = self.held_paths() if held is None else held
        pinned = {row[0] for row in self.pinned_paths(held)}
        return [row for row in held if row[0] not in pinned]

    def path_slice_room(self, held: list[tuple[str, str, int]] | None = None) -> int:
        return max(1, PATHS_PER_SLICE - len(self.pinned_paths(held)))

    def path_slice_count(self) -> int:
        held = self.held_paths()
        return page_count(self.browsable_paths(held), self.path_slice_room(held))

    def path_slice(
        self, held: list[tuple[str, str, int]] | None = None
    ) -> list[tuple[str, str, int]]:
        held = self.held_paths() if held is None else held
        return self.pinned_paths(held) + page_of(
            self.browsable_paths(held), self.path_page, self.path_slice_room(held)
        )

    def path_slice_note(self, held: list[tuple[str, str, int]]) -> str:
        """Deliberately not `page_note`, which opens with "Page N of M" - two
        of those on one screen read as one paginator, and neither is.

        Counts the browsable Paths rather than all of them, because the chosen
        ones ride along on every slice and are not part of what the arrows
        walk through.
        """
        rest = self.browsable_paths(held)
        room = self.path_slice_room(held)
        slices = max(1, page_count(rest, room))
        first = (self.path_page % slices) * room + 1
        shown = len(page_of(rest, self.path_page, room))
        return f"Paths {first}\N{EN DASH}{first + shown - 1} of {len(rest)}"

    def apply_path_choice(self, values: list[str]) -> None:
        """Take one slice's answer without disturbing the others.

        A slice speaks for its own Paths and for none of the rest, so a Path
        ticked on an earlier slice survives a later one being submitted -
        which is the whole reason Lightning and Wind can be chosen together
        even when they fall either side of the 25-option ceiling.

        Kept out of the callback because it is the only real thinking on this
        screen, and logic inside an interaction handler can only be tested by
        faking an interaction.
        """
        mine = {code for code, _, _ in self.path_slice()}
        self.chosen_paths -= mine
        self.chosen_paths |= set(values)
        self.page = 0

    def apply_page_choice(self, shown: list[int], values: list[int]) -> None:
        """Take one screen's answer without disturbing the others.

        The same rule the Path filter follows: a screen speaks for the pages
        that were on it and for none of the rest, so a page ticked two screens
        ago survives this one being submitted - and unticking still works,
        because a page that was shown and came back unticked is dropped.
        """
        self.picked -= set(shown)
        self.picked |= set(values)

    def ordered_picks(self) -> list[int]:
        """The batch, in the order the shelf is arranged rather than the order
        they happened to be ticked - so the forecast reads like the screen."""
        order = {p["page_id"]: n for n, p in enumerate(self.sorted_pages())}
        return sorted(self.picked, key=lambda page_id: order.get(page_id, 1 << 30))

    def picked_pages(self) -> list[dict]:
        held = {p["page_id"]: p for p in self.pages}
        return [held[i] for i in self.ordered_picks() if i in held]

    def held_types(self) -> list[tuple[str, str, int]]:
        """The kinds this refiner actually holds, fullest first.

        Counted against the PATH filter rather than the whole shelf, so the
        numbers answer "what is on the shelf I am looking at" - picking
        Lightning and then reading "Attack x2" means two Lightning Attack
        pages, which is the question somebody narrowing twice is asking.
        """
        after_path = (
            self.pages if not self.chosen_paths
            else [p for p in self.pages if p["path_code"] in self.chosen_paths]
        )
        tally: dict[str, tuple[str, int]] = {}
        for entry in after_path:
            name, n = tally.get(entry["type_code"], (entry["type_name"], 0))
            tally[entry["type_code"]] = (name, n + 1)
        return sorted(
            ((code, name, n) for code, (name, n) in tally.items()),
            key=lambda row: (-row[2], row[1]),
        )

    def visible_pages(self) -> list[dict]:
        """The shelf the filters left. No filter is every page.

        Two axes now, and they narrow independently - a Path chosen does not
        clear a kind and a kind does not clear a Path.
        """
        shelf = self.pages
        if self.chosen_paths:
            shelf = [p for p in shelf if p["path_code"] in self.chosen_paths]
        if self.chosen_types:
            shelf = [p for p in shelf if p["type_code"] in self.chosen_types]
        return shelf

    def filter_names(self) -> list[str]:
        chosen = self.chosen_paths
        return [name for code, name, _ in self.held_paths() if code in chosen]

    def sorted_pages(self) -> list[dict]:
        key = next(k for code, _, k, _ in GROUPINGS if code == self.group)
        return by_type_and_strength(
            self.visible_pages(),
            # Tier sorts as a number and the other two as text; `str` on a
            # tier would put 10 before 2, so it is padded rather than cast.
            kind=(
                (lambda p: f"{p['tier']:03d}")
                if key == "tier"
                else (lambda p: p[key])
            ),
            # Within a group: the strongest page first. Tier is the grade,
            # power and quality separate two of a grade and both feed the
            # refinement directly.
            strength=lambda p: (p["tier"], p["power"], p["quality"]),
            name=lambda p: p["type_name"],
        )

    def page_count(self) -> int:
        return page_count(self.visible_pages())

    def card(self) -> discord.Embed:
        return render_shelf(
            self.visible_pages(), self.group, self.page, self.cap,
            self.filter_names(), self.picked_pages(),
        )

    def build(self) -> None:
        self.clear_items()
        # One page on the screen is now worth showing. The select used to ask
        # for two at once and Discord refuses a select whose min_values
        # exceeds its options; it asks for none at all now, because the batch
        # is kept by the screen and a lone page here pairs with one from
        # somewhere else.
        showing = page_of(self.sorted_pages(), self.page)
        if showing:
            self.add_item(PageSelect(self, showing))

        # Row 1 was the three sort buttons; they move down so the kind filter
        # can have a row of its own. Eleven kinds need a select, a select
        # needs a whole row, and all five were already spoken for.
        kinds = self.held_types()
        if len(kinds) > 1:
            self.add_item(TypeFilter(self, kinds))

        self.add_item(RefineNowButton(self))
        self.add_item(ClearPicksButton(self))
        add_page_buttons(self, row=2)

        held = self.held_paths()
        if len(held) > 1:
            self.add_item(PathFilter(self, held))
        # Offered whenever either filter is on, since it now clears both.
        if self.chosen_paths or self.chosen_types:
            self.add_item(ClearFilter(self))

        for code, label, _, _ in GROUPINGS:
            self.add_item(GroupButton(self, code, label))
        if len(held) > 1 and self.path_slice_count() > 1:
            self.add_item(
                PathSliceButton(self, -1, "\N{LEFTWARDS BLACK ARROW} Paths")
            )
            self.add_item(
                PathSliceButton(self, +1, "Paths \N{BLACK RIGHTWARDS ARROW}")
            )

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "Those are not your pages.", ephemeral=True
            )
            return False
        return True

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True


class Refine(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @app_commands.command(description="Combine manual pages into a manual.")
    async def refine(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)

        skill = await db.fetch_one(
            """
            SELECT COALESCE(pr.level, 1) AS level,
                   COALESCE(pr.exp, 0) AS exp,
                   COALESCE(pr.refined, 0) AS refined,
                   COALESCE(pr.failures, 0) AS failures,
                   refinement_max_pages(COALESCE(pr.level, 1)::smallint) AS cap
            FROM (SELECT 1) _
            LEFT JOIN player_refinement pr ON pr.player_id = %s
            """,
            (player["player_id"],),
        )

        pages = await db.fetch_all(
            """
            SELECT p.page_id, p.tier, p.power, p.quality,
                   p.path_code, pa.name AS path_name,
                   -- The code as well as the name, for the kind filter:
                   -- filtering on a display name works until somebody renames
                   -- one, and the code is what `page_types` is keyed on.
                   p.page_type AS type_code,
                   ty.name AS type_name, tr.name AS trait_name
            FROM manual_pages p
            JOIN paths pa ON pa.code = p.path_code
            JOIN page_types ty ON ty.code = p.page_type
            LEFT JOIN page_traits tr ON tr.code = p.trait
            WHERE p.owner_id = %s AND p.consumed_at IS NULL
            ORDER BY p.tier DESC, p.power DESC
            """,
            (player["player_id"],),
        )
        if len(pages) < 2:
            raise GameError(
                "Refinement needs at least two pages. They come off rogue "
                "cultivators, who turn up while you are hunting, gathering or "
                "exploring."
            )

        view = RefineView(player["player_id"], interaction.user, pages, skill["cap"])
        card = view.card()
        card.insert_field_at(
            0,
            name="Refinement skill",
            value=(
                f"Level **{skill['level']}** ({thousands(skill['exp'])} EXP)\n"
                f"Holding **{len(pages)}** page(s)  ·  "
                f"{skill['refined']} refined, {skill['failures']} failed"
            ),
            inline=False,
        )
        await interaction.response.send_message(embed=card, view=view)


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Refine(bot))
