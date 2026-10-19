"""Alchemy: /alchemy and /pills.

There is no recipe list, so the screen cannot show you one. What it shows
instead is what is currently in the pot and what that makes it: the total
potency, the grade that buys, and which Path is winning the argument — because
the winning Path is what decides whether this becomes cultivation or health.

The Path agreement is spelled out in words for the same reason the Gu bench
does it. "Wood fights Poison" is a lesson, and a player who learns it by
losing twelve herbs has been taught by an accident.

Nothing here computes a game number. Potency, grade, kind and agreement all
come back from SQL, out of the same tables `brew()` reads.
"""

from typing import Callable

import discord
import psycopg
from discord import app_commands
from discord.ext import commands

from bot import database as db
from bot.character import RARITY_MARK
from bot.formatting import (
    COLOUR_BAD,
    COLOUR_DEFAULT,
    COLOUR_GOOD,
    COLOUR_INFO,
    embed,
    error_embed,
    thousands,
)
from bot.pathpicker import PathPicker, fetch_paths
from bot.picking import (
    PagedPicker,
    add_page_buttons,
    by_type_and_strength,
    page_count,
    page_note,
    page_of,
)
from bot.views import AnsweringModal, AnsweringView, answer_error
from bot.players import GameError, require_player, settle_passive

# The bands `pair_harmony` actually returns: +10 for a Path with itself, +4
# when the chart is silent, -11 one-sided, -22 both ways.
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


# ---------------------------------------------------------------------------
# Reading the cauldron
# ---------------------------------------------------------------------------


async def fetch_skill(player_id: int) -> dict:
    return await db.fetch_one(
        """
        SELECT profession_level(%s, 'alchemy') AS level,
               COALESCE(pp.exp, 0) AS exp,
               COALESCE(pp.successes, 0) AS successes,
               COALESCE(pp.failures, 0) AS failures,
               alchemy_herb_slots(profession_level(%s, 'alchemy')) AS slots,
               alchemy_max_brews(profession_level(%s, 'alchemy')) AS pots
        FROM professions pr
        LEFT JOIN player_professions pp
               ON pp.profession = pr.code AND pp.player_id = %s
        WHERE pr.code = 'alchemy'
        """,
        (player_id, player_id, player_id, player_id),
    )


async def fetch_herbs(player_id: int) -> list[dict]:
    return await db.fetch_all(
        """
        SELECT pm.material_code AS code, m.name, m.tier, m.emoji, m.rarity,
               m.path_code, p.name AS path_name, pm.quantity,
               k.name AS kind_name
        FROM player_materials pm
        JOIN materials m ON m.code = pm.material_code
        JOIN paths p ON p.code = m.path_code
        LEFT JOIN path_pill_kinds ppk ON ppk.path_code = m.path_code
        LEFT JOIN pill_kinds k ON k.code = ppk.kind
        WHERE pm.player_id = %s AND pm.quantity > 0 AND m.tier IS NOT NULL
        ORDER BY m.tier DESC, m.name
        """,
        (player_id,),
    )


async def read_pot(pot: dict[str, int]) -> dict | None:
    """What is in the cauldron and what it would become.

    One query, because the grade, the dominant Path and the kind it makes are
    all decided by tables `brew()` reads and none of them by this file.
    """
    if not pot:
        return None

    codes, amounts = list(pot.keys()), list(pot.values())
    lines = await db.fetch_all(
        """
        SELECT m.name, m.emoji, m.tier, u.quantity, m.tier * u.quantity AS weight,
               p.name AS path_name, m.path_code
        FROM unnest(%s::text[], %s::int[]) AS u (code, quantity)
        JOIN materials m ON m.code = u.code
        JOIN paths p ON p.code = m.path_code
        ORDER BY m.tier * u.quantity DESC, m.name
        """,
        (codes, amounts),
    )
    summary = await db.fetch_one(
        """
        WITH pot AS (
            SELECT m.path_code, m.tier * u.quantity AS weight
            FROM unnest(%s::text[], %s::int[]) AS u (code, quantity)
            JOIN materials m ON m.code = u.code
        ),
        lead AS (
            SELECT path_code FROM pot GROUP BY path_code
            ORDER BY sum(weight) DESC LIMIT 1
        )
        ,
        made AS (
            SELECT l.path_code,
                   COALESCE((SELECT max(pt.tier) FROM pill_tiers pt
                             WHERE pt.potency_required
                                   <= (SELECT sum(weight) FROM pot)), 0) AS grade
            FROM lead l
        )
        SELECT (SELECT sum(weight) FROM pot) AS potency,
               m.path_code AS lead_path,
               p.name AS lead_name,
               k.name AS kind_name,
               k.emoji AS kind_emoji,
               k.description AS kind_text,
               NULLIF(m.grade, 0) AS grade,
               step.name AS upgrade_name,
               step.emoji AS upgrade_emoji,
               step.at_tier AS upgrade_tier
        FROM made m
        JOIN paths p ON p.code = m.path_code
        -- 0180. The kind depends on the GRADE as well as the Path: below a
        -- kind's `min_tier` it falls back. Joining straight through
        -- `path_pill_kinds` promised a Quickened Cultivation that a tier 4
        -- brew was never going to make.
        LEFT JOIN pill_kinds k
               ON k.code = pill_kind_for(m.path_code, m.grade::smallint)
        LEFT JOIN LATERAL (
            SELECT up.name, up.emoji,
                   pill_kind_upgrade_at(m.path_code) AS at_tier
            FROM path_pill_kinds ppk2
            JOIN pill_kinds up ON up.code = ppk2.kind
            WHERE ppk2.path_code = m.path_code
              AND pill_kind_upgrade_at(m.path_code) > m.grade
        ) step ON TRUE
        """,
        (codes, amounts),
    )
    # How each Path in the pot sits with the Path that is winning it.
    agreement = await db.fetch_all(
        """
        SELECT DISTINCT m.path_code, p.name AS path_name,
               pair_harmony(m.path_code, %s) AS agreement
        FROM unnest(%s::text[]) AS u (code)
        JOIN materials m ON m.code = u.code
        JOIN paths p ON p.code = m.path_code
        WHERE m.path_code <> %s
        ORDER BY agreement
        """,
        (summary["lead_path"], codes, summary["lead_path"]),
    )
    return {"lines": lines, **summary, "agreement": agreement}


async def render_cauldron(skill: dict, pot: dict[str, int]) -> discord.Embed:
    read = await read_pot(pot)

    card = embed(
        "\N{ALEMBIC} The cauldron",
        "Herbs, not a recipe. What goes in decides what comes out — the Path "
        "with the most weight behind it decides what the pill *does*, and how "
        "well the Paths agree decides how much of it survives.",
        colour=COLOUR_DEFAULT,
    )
    card.add_field(
        name="Alchemist",
        value=(
            f"Level **{skill['level']}** ({thousands(skill['exp'])} EXP)\n"
            f"**{skill['slots']}** herbs in the cauldron  \N{BULLET}  "
            f"**{skill['pots']}** pots in a run  \N{BULLET}  "
            f"{skill['successes']} brewed, {skill['failures']} spoiled"
        ),
        inline=False,
    )

    if read is None:
        card.add_field(
            name="In the pot",
            value="*Empty. Two herbs at least — one is an ingredient, not a brew.*",
            inline=False,
        )
        return card

    card.add_field(
        name=f"In the pot ({len(pot)}/{skill['slots']})",
        value="\n".join(
            f"{r['emoji']} **{r['name']}** \N{MULTIPLICATION SIGN}{r['quantity']} "
            f"\N{BULLET} tier {r['tier']} {r['path_name']} "
            f"\N{BULLET} {r['weight']} potency"
            for r in read["lines"]
        ),
        inline=False,
    )

    if read["grade"] is None:
        becomes = (
            f"**{thousands(read['potency'])} potency** — not yet enough for anything. "
            "Tier 1 wants 3."
        )
    else:
        becomes = (
            f"**{thousands(read['potency'])} potency** \N{RIGHTWARDS ARROW} a **tier "
            f"{read['grade']}** {read['kind_emoji']} **{read['kind_name']}** pill\n"
            f"*{read['kind_text']}*"
            # Being one grade under the step is the interesting case, not
            # being miles from it. Saying so is the difference between
            # somebody finding Quickened Cultivation and never learning it
            # is there.
            + (f"\n\n\N{UPWARDS BLACK ARROW} At **tier {read['upgrade_tier']}** "
               f"this becomes {read['upgrade_emoji']} "
               f"**{read['upgrade_name']}** instead."
               if read.get("upgrade_name") else "")
        )
    card.add_field(name="Becomes", value=becomes, inline=False)

    if read["agreement"]:
        card.add_field(
            name=f"Against {read['lead_name']}, which is winning the pot",
            value="\n".join(
                f"{agreement_word(a['agreement'])} \N{BULLET} {a['path_name']}"
                for a in read["agreement"]
            ),
            inline=False,
        )
    else:
        card.add_field(
            name="Agreement",
            value=f"All of it is {read['lead_name']}. Nothing in the pot argues.",
            inline=False,
        )

    card.set_footer(
        text="Potency sets the grade; harmony decides how much of that grade you keep. "
        "Below 25 the pot is spoiled and half comes back."
    )
    return card


async def render_result(result: dict) -> discord.Embed:
    if not result["succeeded"]:
        card = embed(
            "\N{COLLISION SYMBOL} The pot is spoiled",
            f"Harmony **{result['harmony']}** — nothing in there was going to "
            "agree with anything else.",
            colour=COLOUR_BAD,
        )
        card.add_field(
            name="Lost",
            value=f"{thousands(result['spent_total'] - result['handed_back'])} of "
            f"{thousands(result['spent_total'])} herbs. "
            f"{thousands(result['handed_back'])} were swept back out.",
            inline=False,
        )
        card.add_field(
            name="Learned anyway",
            value=f"+{result['exp_gained']} Alchemist EXP — level "
            f"{result['level_after']}.",
            inline=False,
        )
        return card

    kind = await db.fetch_one(
        "SELECT name, emoji, description FROM pill_kinds WHERE code = %s",
        (result["pill_kind"],),
    )
    card = embed(
        f"{kind['emoji']} {result['pill_name']}",
        f"Tier {result['pill_tier']} \N{BULLET} harmony **{result['harmony']}** "
        f"\N{BULLET} {thousands(result['potency'])} potency",
        colour=COLOUR_GOOD,
    )
    card.add_field(
        name=f"{result['quantity']} \N{MULTIPLICATION SIGN} {kind['name']}",
        value=f"**{thousands(result['magnitude'])}** each. *{kind['description']}*",
        inline=False,
    )
    card.set_footer(
        text=f"+{result['exp_gained']} Alchemist EXP — level {result['level_after']}. "
        "/pills to take one."
    )
    return card


# ---------------------------------------------------------------------------
# The bench
# ---------------------------------------------------------------------------


class AmountModal(discord.ui.Modal, title="How much goes in?"):
    amount = discord.ui.TextInput(label="Quantity", max_length=12, required=True)

    def __init__(self, screen: "CauldronView", code: str, name: str, held: int) -> None:
        super().__init__()
        self.screen = screen
        self.code = code
        self.amount.placeholder = f"You hold {held} {name}. 0 takes it out."

    async def on_submit(self, interaction: discord.Interaction) -> None:
        try:
            wanted = int(str(self.amount).strip())
        except ValueError as exc:
            raise GameError("That is not a number.") from exc

        if wanted < 0:
            raise GameError("A negative amount of a herb is not a thing.")
        if wanted == 0:
            self.screen.pot.pop(self.code, None)
        else:
            if self.code not in self.screen.pot and len(self.screen.pot) >= self.screen.skill["slots"]:
                raise GameError(
                    f"Your cauldron holds {self.screen.skill['slots']} herbs. "
                    "Take one out, or raise your Alchemist level."
                )
            self.screen.pot[self.code] = wanted

        await self.screen.refresh(interaction, "Into the pot.")

    async def on_error(self, interaction: discord.Interaction, error: Exception) -> None:
        if not await answer_error(interaction, error):
            await super().on_error(interaction, error)


class HerbPicker(discord.ui.Select):
    def __init__(self, screen: "CauldronView", rows: list[dict]) -> None:
        self.screen = screen
        self.rows = {r["code"]: r for r in rows}
        super().__init__(
            placeholder="Which herb?",
            options=[
                discord.SelectOption(
                    label=f"T{r['tier']} {r['name']} \N{MULTIPLICATION SIGN}{thousands(r['quantity'])}"[:100],
                    value=r["code"],
                    description=(
                        f"{r['path_name']} \N{BULLET} {r['kind_name'] or 'no pill kind'}"
                    )[:100],
                    emoji=r["emoji"][:1] if r["emoji"] else None,
                )
                for r in rows
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        row = self.rows[self.values[0]]
        await interaction.response.send_modal(
            AmountModal(self.screen, row["code"], row["name"], row["quantity"])
        )


class PickerView(PagedPicker):
    """The shared paged menu, with this cog's way of answering a refusal."""

    async def on_error(self, interaction, error: Exception, item) -> None:
        if not await answer_error(interaction, error):
            await super().on_error(interaction, error, item)


class CauldronView(AnsweringView):
    def __init__(self, player_id: int, user: discord.abc.User, skill: dict) -> None:
        super().__init__(timeout=600)
        self.player_id = player_id
        self.user = user
        self.skill = skill
        self.pot: dict[str, int] = {}
        self.message: discord.Message | None = None

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message("Not your cauldron.", ephemeral=True)
            return False
        return True

    async def refresh(self, interaction: discord.Interaction, said: str) -> None:
        card = await render_cauldron(self.skill, self.pot)
        if interaction.response.is_done():
            await interaction.followup.send(said, ephemeral=True)
        else:
            await interaction.response.send_message(said, ephemeral=True)
        if self.message is not None:
            await self.message.edit(embed=card, view=self)

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True

    @discord.ui.button(label="Add herb", emoji="\N{HERB}", style=discord.ButtonStyle.secondary)
    async def add(self, interaction: discord.Interaction, button) -> None:
        rows = await fetch_herbs(self.player_id)
        if not rows:
            raise GameError(
                "You are holding no herbs. **/gather** — every region grows its own."
            )
        await interaction.response.send_message(
            "Your herbs, the strongest first. Only the top 25 are listed.",
            view=PickerView(
                lambda page: HerbPicker(self, page), rows, noun="herbs"
            ),
            ephemeral=True,
        )

    @discord.ui.button(label="Empty it", style=discord.ButtonStyle.secondary)
    async def clear(self, interaction: discord.Interaction, button) -> None:
        self.pot.clear()
        await self.refresh(interaction, "Tipped out.")

    @discord.ui.button(label="Brew", style=discord.ButtonStyle.success)
    async def brew(self, interaction: discord.Interaction, button) -> None:
        try:
            result = await db.fetch_one(
                "SELECT * FROM brew(%s, %s, %s)",
                (self.player_id, list(self.pot.keys()), list(self.pot.values())),
            )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0].capitalize()) from exc

        for item in self.children:
            item.disabled = True
        await interaction.response.edit_message(
            embed=await render_result(result), view=self
        )
        self.stop()

    @discord.ui.button(
        label="Brew a run", emoji="\N{ALEMBIC}", style=discord.ButtonStyle.primary
    )
    async def run(self, interaction: discord.Interaction, button) -> None:
        """The same pot, several times, each rolling its own harmony.

        A modal rather than a select: the answer is a number between two and
        ten and typing it is faster than finding it in a list. It also leaves
        the row free, which a select would not.
        """
        if len(self.pot) < 2:
            raise GameError(
                "A run needs a cauldron first. **Add herb** \N{EM DASH} two at least."
            )
        await interaction.response.send_modal(RunModal(self))


class RunModal(AnsweringModal, title="How many pots?"):
    """How many times to brew the cauldron as it stands."""

    times = discord.ui.TextInput(
        label="Pots",
        placeholder="2",
        required=True,
        max_length=2,
    )

    def __init__(self, screen: "CauldronView") -> None:
        super().__init__()
        self.screen = screen
        self.times.placeholder = str(screen.skill["pots"])

    async def on_submit(self, interaction: discord.Interaction) -> None:
        raw = self.times.value.strip()
        if not raw.isdigit() or int(raw) < 1:
            raise GameError(f"**{raw}** is not a number of pots.")

        try:
            run = await db.fetch_one(
                "SELECT * FROM brew_many(%s, %s, %s, %s)",
                (
                    self.screen.player_id,
                    list(self.screen.pot.keys()),
                    list(self.screen.pot.values()),
                    int(raw),
                ),
            )
        except psycopg.errors.CheckViolation as exc:
            said = str(exc).splitlines()[0]
            raise GameError(said[:1].upper() + said[1:]) from exc

        for item in self.screen.children:
            item.disabled = True
        await interaction.response.edit_message(
            embed=render_run(run), view=self.screen
        )
        self.screen.stop()


def render_run(run: dict) -> discord.Embed:
    """What came out of a run.

    Every pot rolled its own harmony, so this reports a SPREAD rather than a
    total - the range is the interesting number, and averaging it away would
    hide the thing that makes a run different from one big pot.
    """
    card = embed(
        f"\N{ALEMBIC} {run['attempts']} pots",
        f"**{run['succeeded']}** came out, **{run['spoiled']}** spoiled "
        f"\N{BULLET} harmony {run['worst_harmony']}\N{EN DASH}{run['best_harmony']}",
        colour=COLOUR_GOOD if run["succeeded"] else COLOUR_BAD,
    )

    made = run["made"] or []
    if made:
        card.add_field(
            name=f"On the shelf ({thousands(run['pills_made'])} pill(s))",
            value="\n".join(
                f"`T{m['tier']}` **{m['name']}** "
                f"\N{MULTIPLICATION SIGN}{m['quantity']} \N{BULLET} "
                f"{thousands(m['magnitude'])} each \N{BULLET} harmony {m['harmony']}"
                for m in made[:12]
            )
            + (f"\n*\N{HORIZONTAL ELLIPSIS} and {len(made) - 12} more, on **/pills***"
               if len(made) > 12 else ""),
            inline=False,
        )

    card.add_field(
        name="The bench",
        value=f"{thousands(run['herbs_spent'])} herb(s) in"
        + (f", {thousands(run['herbs_back'])} raked back"
           if run["herbs_back"] else "")
        + f"  \N{BULLET}  +{thousands(run['exp_gained'])} Alchemy EXP "
        f"(level {run['level_after']})",
        inline=False,
    )
    card.set_footer(text="Every pot rolled on its own. /pills to take one.")
    return card


# ---------------------------------------------------------------------------
# The shelf
# ---------------------------------------------------------------------------


def taken_card(taken: dict) -> discord.Embed:
    """What the pills did.

    `detail` is written by `take_pill`, which is the only thing that knows
    whether the body could hold all of it - and by `take_pills`, which adds
    how many of the batch were actually spent.
    """
    how_many = taken.get("taken") or 1
    card = embed(
        f"\N{PILL} {taken['pill_name']}"
        + (f" \N{MULTIPLICATION SIGN}{how_many}" if how_many > 1 else ""),
        f"**+{thousands(taken['granted'])}** \N{BULLET} {taken['detail']}",
        colour=COLOUR_GOOD if taken["granted"] else COLOUR_INFO,
    )
    card.set_footer(
        text=f"{taken['remaining']} of that batch left."
        if taken["remaining"]
        else "That was the last of that batch."
    )
    return card


class InsightTarget(PathPicker):
    """Where an insight pill is pointed, asked as it is swallowed.

    0163. A brew's lead herb decides the pill's kind, and the kind map sends
    only five Paths in practice to insight - so a Space cultivator could not
    buy, brew, trade or find anything at all that raised Space. The pill still
    says where it came from; this asks where it goes, and the answer is worth
    the same wherever it lands.

    It is its own ephemeral message rather than a step inside the shelf, so
    the shelf survives being answered - which leaves the shelf holding a batch
    that is now smaller, and is why `on_pick` edits that message too.

    It also carries a COUNT since 0399. An insight pill is the one kind with a
    question of its own, and the quantity prompt is asked BEFORE this one - so
    "five into Fire" is two answers in the order somebody would say them, and
    an insight batch is no longer the one thing on the shelf you had to take a
    pill at a time.
    """

    prompt_title = "\N{PILL} Where should this go?"

    def __init__(
        self,
        screen: "ShelfView",
        user: discord.abc.User,
        pill: dict,
        paths: list[dict],
        shelf: discord.Message,
        count: int = 1,
    ) -> None:
        self.screen = screen
        self.pill = pill
        self.shelf = shelf
        self.count = count
        self.taken = False
        self.prompt_body = (
            (f"**{pill['name']}** \N{MULTIPLICATION SIGN}{count}"
             if count > 1 else f"**{pill['name']}**")
            + f" \N{EM DASH} {thousands(pill['magnitude'])} "
            f"insight each, brewed on the {pill['path_name']}.\n"
            "Full strength into whichever Path you point it at."
        )
        super().__init__(user, paths, highlight=pill["path_code"])

    async def on_pick(self, path: dict) -> discord.Embed:
        if self.taken:
            raise GameError("Those have already gone down.")
        try:
            taken = await db.fetch_one(
                "SELECT * FROM take_pills(%s, %s, %s, %s)",
                (self.screen.player_id, self.pill["pill_id"], self.count,
                 path["code"]),
            )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0].capitalize()) from exc

        self.taken = True
        self.screen.rows = await fetch_pills(self.screen.player_id)
        self.screen.build()
        await self.shelf.edit(embed=self.screen.card(), view=self.screen)
        return taken_card(taken)

    def render(self) -> None:
        super().render()
        # One pill, one question. Leaving thirty-four live buttons behind an
        # answered one invites a second press against a pill that is gone.
        if self.taken:
            for item in self.children:
                item.disabled = True


class PillSelect(discord.ui.Select):
    def __init__(self, screen: "ShelfView", rows: list[dict]) -> None:
        self.screen = screen
        super().__init__(
            placeholder="Take one…",
            options=[
                discord.SelectOption(
                    label=f"{r['name']} \N{MULTIPLICATION SIGN}{r['quantity']}"[:100],
                    value=str(r["pill_id"]),
                    description=(
                        f"T{r['tier']} {r['kind_name']} \N{BULLET} "
                        f"{thousands(r['magnitude'])} each"
                        + (" \N{BULLET} your choice of Path"
                           if r["kind"] == "insight" else "")
                    )[:100],
                    emoji=r["kind_emoji"][:1] if r["kind_emoji"] else None,
                )
                for r in rows
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        pill_id = int(self.values[0])
        chosen = next(r for r in self.screen.rows if r["pill_id"] == pill_id)

        # More than one in the batch is a question worth asking, and it is
        # asked FIRST - including for insight, which then asks its own. "Five
        # into Fire" is two answers in the order somebody would say them.
        #
        # One is not a question. A screen that asks "how many?" about a single
        # pill has stopped respecting the person using it.
        if chosen["quantity"] > 1:
            await interaction.response.send_message(
                embed=HowMany.prompt(chosen),
                view=HowMany(self.screen, interaction.user, chosen,
                             interaction.message),
                ephemeral=True,
            )
            return

        if chosen["kind"] == "insight":
            picker = InsightTarget(
                self.screen,
                interaction.user,
                chosen,
                await fetch_paths(),
                interaction.message,
            )
            await interaction.response.send_message(
                embed=picker.prompt(), view=picker, ephemeral=True
            )
            return

        await self.screen.swallow(interaction, pill_id, 1)


class HowMany(AnsweringView):
    """How many of the batch. Its own ephemeral message, like the insight
    picker, so answering it leaves the shelf standing.

    Nothing here has to be careful about asking for too many: `take_pills`
    stops the moment a dose banks nothing and leaves the rest in the bag, so
    "All" is safe to press. A button that is not safe to press is a button
    people do not press.
    """

    def __init__(
        self,
        screen: "ShelfView",
        user: discord.abc.User,
        pill: dict,
        shelf: discord.Message,
    ) -> None:
        super().__init__(timeout=120)
        self.screen = screen
        self.user = user
        self.pill = pill
        self.shelf = shelf
        self.done = False
        self.build()

    @staticmethod
    def prompt(pill: dict) -> discord.Embed:
        return embed(
            f"\N{PILL} {pill['name']}",
            f"You are holding **{pill['quantity']}**, worth "
            f"**{thousands(pill['magnitude'])}** each.\n"
            "Anything the body cannot hold stays in the bag \N{EM DASH} taking "
            "more than is useful costs nothing.",
            colour=COLOUR_INFO,
        )

    def build(self) -> None:
        self.clear_items()
        held = self.pill["quantity"]
        # A short ladder rather than every number: 1, a few, half, all. Any
        # amount past what is useful is refunded by the early stop anyway.
        wanted = sorted({1, 5, 10, max(1, held // 2), held})
        for n in wanted:
            if n <= held:
                self.add_item(TakeSome(self, n, n == held))

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "Not your shelf.", ephemeral=True
            )
            return False
        return True

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True


class TakeSome(discord.ui.Button):
    def __init__(self, picker: HowMany, count: int, is_all: bool) -> None:
        self.picker = picker
        self.count = count
        super().__init__(
            label=("All " + str(count)) if is_all else str(count),
            style=discord.ButtonStyle.primary if is_all
            else discord.ButtonStyle.secondary,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        if self.picker.done:
            raise GameError("Those have already gone down.")
        self.picker.done = True

        for item in self.picker.children:
            item.disabled = True

        # An insight pill still has its own question, and now it is asked with
        # the count already in hand rather than a pill at a time.
        if self.picker.pill["kind"] == "insight":
            onward = InsightTarget(
                self.picker.screen,
                interaction.user,
                self.picker.pill,
                await fetch_paths(),
                self.picker.shelf,
                count=self.count,
            )
            await interaction.response.edit_message(
                embed=onward.prompt(), view=onward
            )
            return

        card = await self.picker.screen.swallow(
            interaction, self.picker.pill["pill_id"], self.count, answer=False
        )
        # The shelf is a message behind this one and is now a batch lighter.
        await self.picker.shelf.edit(
            embed=self.picker.screen.card(), view=self.picker.screen
        )
        await interaction.response.edit_message(embed=card, view=self.picker)


async def fetch_pills(player_id: int) -> list[dict]:
    return await db.fetch_all(
        """
        SELECT pp.pill_id, pp.name, pp.tier, pp.magnitude, pp.quantity, pp.harmony,
               pp.kind, pp.path_code,
               k.name AS kind_name, k.emoji AS kind_emoji, k.description AS kind_text,
               p.name AS path_name
        FROM player_pills pp
        JOIN pill_kinds k ON k.code = pp.kind
        JOIN paths p ON p.code = pp.path_code
        WHERE pp.owner_id = %s
        ORDER BY pp.tier DESC, pp.name
        """,
        (player_id,),
    )


def render_shelf(rows: list[dict], page: int) -> discord.Embed:
    """The shelf, one page of it.

    Ten batches were drawn in full and the rest were a number in the footer.
    Now the embed and the select show the same page, so what you are reading
    is what you can reach.
    """
    shown = page_of(rows, page)
    card = embed(
        "\N{PILL} Your shelf",
        f"**{len(rows)}** batch(es), grouped by what they do.",
        colour=COLOUR_INFO,
    )
    for r in shown[:10]:
        card.add_field(
            name=f"{r['kind_emoji']} {r['name']} \N{MULTIPLICATION SIGN}{r['quantity']}",
            value=(
                f"Tier {r['tier']} {r['kind_name']} \N{BULLET} "
                + ("any Path you choose" if r["kind"] == "insight"
                   else r["path_name"])
                + " "
                f"\N{BULLET} harmony {r['harmony']}\n"
                f"**{thousands(r['magnitude'])}** each — *{r['kind_text']}*"
            ),
            inline=False,
        )
    note = page_note(rows, page, "batches")
    extra = len(shown) - 10
    if extra > 0:
        note = (note + " \N{BULLET} " if note else "") + (
            f"{extra} more on this page, in the list below"
        )
    if note:
        card.set_footer(text=note)
    return card


class ShelfView(AnsweringView):
    """A shelf is sorted by kind, strongest of each first.

    `fetch_pills` orders by tier for the embed's benefit; the picker wants
    the other question answered - "where are my healing pills" - so it groups.
    """

    def __init__(self, player_id: int, user: discord.abc.User, rows: list[dict]) -> None:
        super().__init__(timeout=300)
        self.player_id = player_id
        self.user = user
        self.rows = rows
        self.page = 0
        self.build()

    @property
    def sorted_rows(self) -> list[dict]:
        return by_type_and_strength(
            self.rows,
            kind=lambda r: r["kind_name"],
            # Tier is the grade; magnitude separates two pills of one grade,
            # which harmony can make quite different.
            strength=lambda r: (r["tier"], r["magnitude"]),
        )

    def page_count(self) -> int:
        return page_count(self.rows)

    def card(self) -> discord.Embed:
        return render_shelf(self.sorted_rows, self.page)

    def build(self) -> None:
        self.clear_items()
        rows = self.sorted_rows
        if rows:
            self.add_item(PillSelect(self, page_of(rows, self.page)))
        add_page_buttons(self, row=1)

    async def swallow(
        self,
        interaction: discord.Interaction,
        pill_id: int,
        count: int,
        *,
        answer: bool = True,
    ) -> discord.Embed:
        """Take `count` of one batch and redraw the shelf.

        Both doors into this - a single pill straight off the select, and a
        handful off the quantity prompt - go through here, so they cannot come
        to disagree about what happens afterwards.
        """
        try:
            taken = await db.fetch_one(
                "SELECT * FROM take_pills(%s, %s, %s)",
                (self.player_id, pill_id, count),
            )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0].capitalize()) from exc

        self.rows = await fetch_pills(self.player_id)
        self.build()
        card = taken_card(taken)
        if answer:
            await interaction.response.edit_message(embed=card, view=self)
        return card

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message("Not your shelf.", ephemeral=True)
            return False
        return True

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True


class Alchemy(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @app_commands.command(description="Brew herbs into a pill.")
    async def alchemy(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])

        skill = await fetch_skill(player["player_id"])
        view = CauldronView(player["player_id"], interaction.user, skill)
        await interaction.response.send_message(
            embed=await render_cauldron(skill, view.pot), view=view
        )
        view.message = await interaction.original_response()

    @app_commands.command(description="The pills you have brewed.")
    async def pills(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        rows = await fetch_pills(player["player_id"])
        if not rows:
            raise GameError("You have brewed nothing. **/alchemy**.")

        view = ShelfView(player["player_id"], interaction.user, rows)
        await interaction.response.send_message(embed=view.card(), view=view)


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Alchemy(bot))
