"""Gu refinement: /refinegu.

A bench, not a form. The base and the secondary are the recipe and there is
nothing to decide about them - you either have them or you go and get them.
The auxiliary pile is the whole game: what you put on it decides how good the
Gu can be, and whether it forms at all.

So this screen spends its space on the auxiliaries. Every one of them says
what it is doing to the mixture in a word, because "Poison fights Wood" is the
lesson, and a player who has to lose 30 jade leaves to learn it has been
taught by an accident rather than by the game.

Nothing here computes a game number. Affinity, measures and potency all come
back from SQL, from the same functions `refine_gu` uses - a second copy of the
formula in Python is a second copy that drifts.
"""

from typing import Callable

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
    error_embed,
    thousands,
)
from bot.picking import (
    PagedPicker,
    add_page_buttons,
    page_count,
    page_of,
)
from bot.character import RARITY_MARK
from bot.views import AnsweringModal, AnsweringView, answer_error
from bot.players import GameError, fetch_player, require_player

STARS = "\N{BLACK STAR}"
PROFESSION = "gu_refining"

# What an affinity number means at a glance. The thresholds are the values
# `pair_harmony` actually returns - +10 for a Path with itself, +4 when the
# matchup chart is silent, -11 one-sided and -22 both ways - so a new entry in
# `path_affinities` lands in the right band without this being touched.
AFFINITY_BANDS = (
    (8, "\N{WHITE HEAVY CHECK MARK}", "belongs"),
    (1, "\N{WHITE MEDIUM SQUARE}", "no quarrel"),
    (-15, "\N{WARNING SIGN}", "fights it"),
)


def affinity_word(value) -> str:
    for threshold, icon, word in AFFINITY_BANDS:
        if value >= threshold:
            return f"{icon} {word}"
    return "\N{CROSS MARK} ruins it"


async def fetch_skill(player_id: int) -> dict:
    return await db.fetch_one(
        """
        SELECT profession_level(%s, 'gu_refining') AS level,
               COALESCE(pp.exp, 0) AS exp,
               COALESCE(pp.successes, 0) AS successes,
               COALESCE(pp.failures, 0) AS failures,
               pr.exp_per_level,
               gu_refine_aux_slots(profession_level(%s, 'gu_refining')) AS slots
        FROM professions pr
        LEFT JOIN player_professions pp
               ON pp.profession = pr.code AND pp.player_id = %s
        WHERE pr.code = 'gu_refining'
        """,
        (player_id, player_id, player_id),
    )


async def fetch_recipe(player_id: int, gu_code: str) -> dict | None:
    """One recipe, with what the player holds of it and what it grants."""
    return await db.fetch_one(
        """
        SELECT c.*,
               p.name AS path_name, p.emoji AS path_emoji,
               game_config_value('gu_max_refinable_rank') AS refine_ceiling,
               material_name(c.base_material) AS base_name,
               material_name(c.secondary_material) AS secondary_name,
               COALESCE(bm.quantity, 0) AS base_held,
               COALESCE(sm.quantity, 0) AS secondary_held,
               material_affinity(c.base_material, c.path_code) AS base_affinity,
               material_affinity(c.secondary_material, c.path_code) AS secondary_affinity,
               (SELECT string_agg(ef.emoji || ' ' || ef.name || ' '
                                  || effect_amount(ef.code, te.magnitude),
                                  ', ' ORDER BY ef.sort_order)
                FROM gu_type_effects te
                JOIN gu_effects ef ON ef.code = te.effect_code
                WHERE te.gu_type_id = c.gu_type_id) AS effects
        FROM gu_recipe_costs c
        JOIN paths p ON p.code = c.path_code
        LEFT JOIN player_materials bm
               ON bm.player_id = %s AND bm.material_code = c.base_material
        LEFT JOIN player_materials sm
               ON sm.player_id = %s AND sm.material_code = c.secondary_material
        WHERE c.gu_code = %s
        """,
        (player_id, player_id, gu_code),
    )


async def fetch_bench(gu_path: str, aux: dict[str, int]) -> tuple[list[dict], float]:
    """What the auxiliary pile is worth, straight out of SQL.

    Returns the rows and the total potency, which is what buys stars.
    """
    if not aux:
        return [], 0.0

    rows = await db.fetch_all(
        """
        WITH bench AS (
            SELECT u.code, u.quantity,
                   material_name(u.code) AS name,
                   m.path_code,
                   ra.sort_order / 10.0 AS per_measure,
                   material_affinity(u.code, %s) AS affinity,
                   LEAST(game_config_value('gu_refine_aux_measures'),
                         u.quantity::numeric
                         / game_config_value('gu_refine_aux_unit')) AS measures
            FROM unnest(%s::text[], %s::int[]) AS u (code, quantity)
            JOIN materials m ON m.code = u.code
            JOIN rarities ra ON ra.code = m.rarity
        )
        SELECT b.*, p.name AS path_name,
               (SELECT COALESCE(sum(x.per_measure * x.measures), 0) FROM bench x) AS potency
        FROM bench b
        LEFT JOIN paths p ON p.code = b.path_code
        ORDER BY b.affinity DESC, b.name
        """,
        (gu_path, list(aux.keys()), list(aux.values())),
    )
    return rows, float(rows[0]["potency"]) if rows else 0.0


async def star_ceiling(potency: float) -> int:
    return await db.fetch_value(
        "SELECT COALESCE(max(stars), 1) FROM gu_refine_grades WHERE min_potency <= %s",
        (potency,),
    )


async def render_bench(
    recipe: dict,
    skill: dict,
    aux: dict[str, int],
    *,
    locked: bool = False,
    closed: bool = False,
) -> discord.Embed:
    rows, potency = await fetch_bench(recipe["path_code"], aux)
    ceiling = await star_ceiling(potency)

    card = embed(
        f"{recipe['emoji']} {recipe['gu_name']}",
        f"{recipe['path_emoji']} {recipe['path_name']} \N{BULLET} rank "
        f"{recipe['rank']} {recipe['rarity']} \N{BULLET} costs "
        f"{recipe['size']} of your aperture\n"
        f"*{recipe['effects'] or 'Nothing yet.'}*",
        colour=COLOUR_DEFAULT,
    )

    def ingredient(label: str, name: str, need: int, held: int, affinity) -> str:
        mark = (
            "\N{WHITE HEAVY CHECK MARK}" if held >= need else "\N{HEAVY MULTIPLICATION X}"
        )
        return (
            f"{mark} **{label}** — {name} "
            f"{thousands(held)}/{thousands(need)}\n     {affinity_word(affinity)}"
        )

    card.add_field(
        name="The recipe",
        value="\n".join(
            (
                ingredient(
                    "Base",
                    recipe["base_name"],
                    recipe["base_quantity"],
                    recipe["base_held"],
                    recipe["base_affinity"],
                ),
                ingredient(
                    "Secondary",
                    recipe["secondary_name"],
                    recipe["secondary_quantity"],
                    recipe["secondary_held"],
                    recipe["secondary_affinity"],
                ),
            )
        ),
        inline=False,
    )

    if rows:
        lines = [
            f"{affinity_word(r['affinity'])} **{r['name']}** "
            f"\N{MULTIPLICATION SIGN}{thousands(r['quantity'])} "
            f"\N{BULLET} {r['path_name'] or 'no Path'} "
            f"\N{BULLET} {float(r['measures']):.1f} measure(s)"
            for r in rows
        ]
    else:
        lines = ["*Empty. The Gu will form, and it will be a one-star Gu.*"]

    card.add_field(
        name=f"Auxiliary ({len(aux)}/{skill['slots']})",
        value="\n".join(lines),
        inline=False,
    )
    card.add_field(
        name="What the pile is worth",
        value=(
            f"Potency **{potency:.1f}** — enough for **{STARS * ceiling}** "
            f"({ceiling} star{'s' if ceiling != 1 else ''}), "
            "if the harmony holds."
        ),
        inline=False,
    )
    # A locked recipe is drawn in full and says the one thing that is wrong
    # with it. Half a screen plus a refusal teaches nothing about the Gu.
    if closed:
        card.add_field(
            name="🔒 Not yet",
            value=f"A {recipe['gu_name']} is **rank {recipe['rank']}**, and "
            f"the bench has not been opened past **rank "
            f"{recipe['refine_ceiling']}**. No amount of levelling changes "
            "that — the world has to open it.",
            inline=False,
        )
    elif locked:
        card.add_field(
            name="🔒 Not yet",
            value=f"A {recipe['gu_name']} takes **Gu Refiner level "
            f"{recipe['required_level']}**, and you are level "
            f"{skill['level']}. Refine something simpler first — even a "
            "failure teaches.",
            inline=False,
        )
    card.set_footer(
        text="Potency buys the ceiling; harmony decides how much of it you keep. "
        "The same Path agrees with itself — the rest is the matchup chart."
    )
    return card


async def render_result(result: dict, rank: int | None = None) -> discord.Embed:
    """`rank` is the bench's, not the result's - `refine_gu` returns what was
    made without saying how deep it is, and the recipe on screen already knows.
    Optional so a failure, which made nothing, need not supply one."""
    if not result["succeeded"]:
        card = embed(
            "The mixture came apart",
            f"Harmony **{result['harmony_score']}** — too little for anything "
            "to hold its shape.",
            colour=COLOUR_BAD,
        )
        card.add_field(
            name="Lost",
            value=f"{thousands(result['spent_total'] - result['handed_back'])} "
            f"of {thousands(result['spent_total'])} materials. "
            f"{thousands(result['handed_back'])} were swept back up.",
            inline=False,
        )
        card.add_field(
            name="Learned anyway",
            value=f"+{result['exp_gained']} Gu Refiner EXP — level "
            f"{result['level_after']}.",
            inline=False,
        )
        card.set_footer(
            text="Auxiliaries whose Path the Gu fights are what does this."
        )
        return card

    card = embed(
        f"{STARS * result['stars_made']} {result['made_name']}"
        + (f" \N{MIDDLE DOT} rank {rank}" if rank else ""),
        f"Harmony **{result['harmony_score']}** \N{BULLET} potency "
        f"**{float(result['potency_score']):.1f}** \N{BULLET} "
        f"{thousands(result['spent_total'])} materials consumed",
        colour=COLOUR_GOOD,
    )
    card.add_field(
        name="Stars",
        value=f"**{result['stars_made']} of 5.** Each star above the first adds "
        "a quarter again to everything it grants.",
        inline=False,
    )
    card.add_field(
        name="Harmony",
        value=f"**{result['harmony_score']}** is carried on the Gu itself, for "
        "the killer-move fusion it may end up in.",
        inline=False,
    )
    card.set_footer(
        text=f"+{result['exp_gained']} Gu Refiner EXP — level "
        f"{result['level_after']}. /gu to take it into your aperture."
    )
    return card


# ---------------------------------------------------------------------------
# The bench
# ---------------------------------------------------------------------------


class AuxQuantityModal(discord.ui.Modal, title="How much goes in?"):
    amount = discord.ui.TextInput(label="Quantity", max_length=12, required=True)

    def __init__(self, screen: "BenchView", code: str, name: str, held: int) -> None:
        super().__init__()
        self.screen = screen
        self.code = code
        self.amount.placeholder = f"You hold {held} {name}. 0 takes it off the bench."

    async def on_submit(self, interaction: discord.Interaction) -> None:
        try:
            wanted = int(str(self.amount).strip())
        except ValueError as exc:
            raise GameError("That is not a number.") from exc

        if wanted < 0:
            raise GameError("A negative amount of a herb is not a thing.")
        if wanted == 0:
            self.screen.aux.pop(self.code, None)
        else:
            if (
                self.code not in self.screen.aux
                and len(self.screen.aux) >= self.screen.skill["slots"]
            ):
                raise GameError(
                    f"Your bench holds {self.screen.skill['slots']} auxiliary "
                    "materials. Take one off, or raise your Gu Refiner level."
                )
            self.screen.aux[self.code] = wanted

        await self.screen.refresh(interaction, "On the bench.")

    async def on_error(self, interaction: discord.Interaction, error: Exception) -> None:
        if not await answer_error(interaction, error):
            await super().on_error(interaction, error)


class AuxPicker(discord.ui.Select):
    """Ephemeral, so a player only ever browses their own stores."""

    def __init__(self, screen: "BenchView", rows: list[dict]) -> None:
        self.screen = screen
        self.rows = {r["code"]: r for r in rows}
        super().__init__(
            placeholder="Which material?",
            options=[
                discord.SelectOption(
                    label=f"{r['name']} \N{MULTIPLICATION SIGN}{thousands(r['quantity'])}"[:100],
                    value=r["code"],
                    description=(
                        f"{r['path_name'] or 'no Path'} · {r['rarity']} · "
                        f"{affinity_word(r['affinity'])}"
                    )[:100],
                )
                for r in rows
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        row = self.rows[self.values[0]]
        await interaction.response.send_modal(
            AuxQuantityModal(self.screen, row["code"], row["name"], row["quantity"])
        )


class PickerView(PagedPicker):
    """The shared paged menu, with this cog's way of answering a refusal."""

    async def on_error(self, interaction, error: Exception, item) -> None:
        if not await answer_error(interaction, error):
            await super().on_error(interaction, error, item)


class BenchView(AnsweringView):
    def __init__(
        self,
        player_id: int,
        user: discord.abc.User,
        recipe: dict,
        skill: dict,
        *,
        locked: bool = False,
    ) -> None:
        super().__init__(timeout=600)
        self.player_id = player_id
        self.user = user
        self.recipe = recipe
        self.skill = skill
        self.locked = locked
        self.aux: dict[str, int] = {}
        self.message: discord.Message | None = None
        # Browsable, not usable. The buttons stay visible rather than being
        # removed, so the screen reads as the same bench you will use later.
        if locked:
            for item in self.children:
                item.disabled = True

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message("Not your bench.", ephemeral=True)
            return False
        return True

    async def refresh(self, interaction: discord.Interaction, said: str) -> None:
        """Answer the presser, then redraw the bench.

        The bench is edited through the stored message rather than through the
        interaction, because a quantity arrives from a modal opened off an
        ephemeral picker - three messages away from the one being redrawn.
        """
        self.recipe = await fetch_recipe(self.player_id, self.recipe["gu_code"])
        card = await render_bench(
            self.recipe, self.skill, self.aux, locked=self.locked
        )

        if interaction.response.is_done():
            await interaction.followup.send(said, ephemeral=True)
        else:
            await interaction.response.send_message(said, ephemeral=True)

        if self.message is not None:
            await self.message.edit(embed=card, view=self)

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True

    @discord.ui.button(label="Add material", style=discord.ButtonStyle.secondary)
    async def add(self, interaction: discord.Interaction, button) -> None:
        rows = await db.fetch_all(
            """
            SELECT pm.material_code AS code, material_name(pm.material_code) AS name,
                   pm.quantity, m.rarity, p.name AS path_name,
                   material_affinity(pm.material_code, %s) AS affinity
            FROM player_materials pm
            JOIN materials m ON m.code = pm.material_code
            LEFT JOIN paths p ON p.code = m.path_code
            WHERE pm.player_id = %s AND pm.quantity > 0
              AND pm.material_code NOT IN (%s, %s)
            ORDER BY material_affinity(pm.material_code, %s) DESC, m.rarity DESC,
                     pm.quantity DESC
            """,
            (
                self.recipe["path_code"],
                self.player_id,
                self.recipe["base_material"],
                self.recipe["secondary_material"],
                self.recipe["path_code"],
            ),
        )
        if not rows:
            raise GameError(
                "You are holding nothing to put in. **/gather** in a region, or "
                "kill something."
            )
        await interaction.response.send_message(
            "Your stores, the ones this Gu likes best first.",
            view=PickerView(
                lambda page: AuxPicker(self, page), rows, noun="materials"
            ),
            ephemeral=True,
        )

    @discord.ui.button(label="Clear the bench", style=discord.ButtonStyle.secondary)
    async def clear(self, interaction: discord.Interaction, button) -> None:
        self.aux.clear()
        await self.refresh(interaction, "Swept clean.")

    @discord.ui.button(label="Refine", style=discord.ButtonStyle.success)
    async def refine(self, interaction: discord.Interaction, button) -> None:
        await self.work(interaction, 1)

    @discord.ui.button(label="Work a run", style=discord.ButtonStyle.primary)
    async def run(self, interaction: discord.Interaction, button) -> None:
        """How many, asked only when more than one is possible.

        The ceiling is the Gu Refining ladder, the same shape an alchemist's
        pots climb - so a refiner who knows what `/brew` does already knows
        what this does.
        """
        most = await db.fetch_value(
            "SELECT gu_refine_max_runs(profession_level(%s, 'gu_refining'))",
            (self.player_id,),
        )
        if not most or most < 2:
            raise GameError(
                "Your Gu Refining works one at a time. The run grows with the "
                "profession \N{EM DASH} **/professions**."
            )
        await interaction.response.send_message(
            embed=embed(
                "\N{HAMMER AND WRENCH} How many?",
                f"Your Gu Refining works up to **{most}** at a time.\n"
                "The whole run is checked before any of it is spent, so a run "
                "you cannot afford costs nothing.",
                colour=COLOUR_INFO,
            ),
            view=RunLength(self, interaction.user, most, interaction.message),
            ephemeral=True,
        )

    async def work(
        self,
        interaction: discord.Interaction,
        times: int,
        *,
        answer: bool = True,
    ) -> discord.Embed:
        """One refinement or a run of them, through the one function.

        Both buttons come here so the single and the run cannot come to
        disagree about what happens to the bench afterwards.
        """
        try:
            result = await db.fetch_one(
                "SELECT * FROM refine_many(%s, %s, %s, %s, %s)",
                (
                    self.player_id,
                    self.recipe["gu_type_id"],
                    list(self.aux.keys()),
                    list(self.aux.values()),
                    times,
                ),
            )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0].capitalize()) from exc

        for item in self.children:
            item.disabled = True
        card = await render_run(result, self.recipe)
        if answer:
            await interaction.response.edit_message(embed=card, view=self)
            self.stop()
        return card


class RunLength(AnsweringView):
    """How many refinements. Its own ephemeral message so the bench survives
    being answered."""

    def __init__(
        self,
        bench: "BenchView",
        user: discord.abc.User,
        most: int,
        shelf: discord.Message,
    ) -> None:
        super().__init__(timeout=120)
        self.bench = bench
        self.user = user
        self.shelf = shelf
        self.done = False
        # A short ladder rather than every number, the same shape the pill
        # shelf offers: a couple, a handful, and everything you can work.
        for n in sorted({2, 3, 5, most}):
            if 2 <= n <= most:
                self.add_item(RunOf(self, n, n == most))

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "Not your bench.", ephemeral=True
            )
            return False
        return True

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True


class RunOf(discord.ui.Button):
    def __init__(self, picker: RunLength, count: int, is_most: bool) -> None:
        self.picker = picker
        self.count = count
        super().__init__(
            label=f"{count} in a row",
            style=discord.ButtonStyle.primary if is_most
            else discord.ButtonStyle.secondary,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        if self.picker.done:
            raise GameError("That run has already been worked.")
        self.picker.done = True
        for item in self.picker.children:
            item.disabled = True

        card = await self.picker.bench.work(interaction, self.count, answer=False)
        await self.picker.shelf.edit(embed=card, view=self.picker.bench)
        await interaction.response.edit_message(embed=card, view=self.picker)
        self.picker.bench.stop()


async def render_run(result: dict, recipe: dict) -> discord.Embed:
    """What a run came to.

    A run of one is still a run, and reads as the single refinement it is -
    `render_result` said it better for that case and still does, so one
    attempt is handed straight to it.
    """
    if result["attempts"] == 1:
        made = (result["made"] or [None])[0]
        return await render_result(
            {
                "succeeded": result["succeeded"] > 0,
                "harmony_score": result["best_harmony"],
                "potency_score": result["best_potency"],
                "stars_made": result["best_stars"],
                "new_gu_id": made["gu_id"] if made else None,
                "made_name": made["name"] if made else None,
                "exp_gained": result["exp_gained"],
                "level_after": result["level_after"],
                "spent_total": result["materials_spent"],
                "handed_back": result["materials_back"],
            },
            recipe["rank"],
        )

    card = embed(
        f"\N{HAMMER AND WRENCH} A run of {result['attempts']}",
        f"**{result['succeeded']}** formed, **{result['spoiled']}** spoiled.",
        colour=COLOUR_GOOD if result["succeeded"] else COLOUR_BAD,
    )
    card.add_field(
        name="The bench",
        value=(
            f"Harmony {result['worst_harmony']}\N{EN DASH}{result['best_harmony']} "
            f"\N{BULLET} best {result['best_stars']}\N{BLACK STAR}\n"
            f"{thousands(result['materials_spent'])} materials in, "
            f"{thousands(result['materials_back'])} handed back"
        ),
        inline=False,
    )
    if result["made"]:
        card.add_field(
            name=f"What came off it ({result['succeeded']})",
            value="\n".join(
                f"{g['emoji']} **{g['name']}** \N{BULLET} "
                f"{g['stars']}\N{BLACK STAR} \N{BULLET} harmony {g['harmony']}"
                for g in result["made"][:12]
            ),
            inline=False,
        )
    card.set_footer(
        text=f"+{thousands(result['exp_gained'])} Gu Refining "
        f"\N{BULLET} level {result['level_after']}"
    )
    return card


# ---------------------------------------------------------------------------
# The book
# ---------------------------------------------------------------------------
# 35 recipes against Discord's ceiling of 25 options in a select, so the book
# filters first and pages second. The filters are a ladder rather than a set
# of toggles: everything you could start now, everything only a trip out is
# stopping, then everything there is. Each one is a superset of the one before
# it, so pressing along the row always shows you MORE - which is the direction
# somebody hunting for a particular Gu is travelling.

PER_PAGE = 25

# Discord allows 1024 characters in a field. The list draws two lines per
# recipe now, so it is measured rather than counted; the slack is for the
# "and N more" that follows it.
LIST_LIMIT = 900

MARKS = {"ready": "\N{WHITE HEAVY CHECK MARK}", "reach": "\N{WHITE MEDIUM SQUARE}",
         "locked": "\N{LOCK}"}

FILTERS = (
    ("ready", "Ready", "you hold everything it asks for"),
    ("reach", "In reach", "the bench will take it"),
    ("all", "Every recipe", "including the ones above your level"),
)


def standing(row: dict) -> str:
    """One of three states, named the same way everywhere it is drawn."""
    if row["ready"]:
        return "ready"
    return "reach" if row["level_ok"] else "locked"


def matches(row: dict, mode: str, tier: int | None = None,
            rarity: str | None = None, query: str | None = None) -> bool:
    """The four axes together.

    State says how close you are to making it and tier says which stretch of
    the ladder you are shopping on. Those two were never quite enough: 3,035
    recipes over nine ranks still leaves 300-odd on a rank, and the thing
    people actually ask for is "the good ones" or one Gu by name.

    So quality and a name search join them. All four narrow independently -
    picking Legendary does not clear your rank, and searching does not clear
    either - because a filter that silently resets another is one you have to
    re-set every time you use it.
    """
    if tier is not None and row["rank"] != tier:
        return False
    if rarity is not None and row["rarity"] != rarity:
        return False
    if query:
        # Name only, and folded: somebody typing "moonlight" should not have
        # to know whether the book capitalises it.
        if query.lower() not in (row["gu_name"] or "").lower():
            return False
    if mode == "ready":
        return row["ready"]
    if mode == "reach":
        return row["level_ok"]
    return True


async def fetch_book(player_id: int) -> list[dict]:
    return await db.fetch_all("SELECT * FROM gu_recipe_book(%s)", (player_id,))


class RecipeSelect(discord.ui.Select):
    def __init__(self, book: "BookView", rows: list[dict]) -> None:
        self.book = book
        super().__init__(
            placeholder="Open a recipe\N{HORIZONTAL ELLIPSIS}",
            row=0,
            options=[
                discord.SelectOption(
                    label=f"{MARKS[standing(r)]} {r['gu_name']}"[:100],
                    value=r["gu_code"],
                    # What is in the way, or what it costs when nothing is.
                    # What it makes always, then what is in the way or what
                    # it costs. A price with no idea what it buys is not a
                    # thing anybody can choose between 2,869 of.
                    description=(
                        f"{r['effects']} \N{BULLET} "
                        + (
                            r["blocker"]
                            or f"{r['base_quantity']}x {r['base_name']}, "
                               f"{r['secondary_quantity']}x {r['secondary_name']}"
                        )
                    )[:100],
                    emoji=r["emoji"][:1] if r["emoji"] else None,
                )
                for r in rows
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        await open_bench(interaction, self.book.player_id, self.values[0])


class FilterButton(discord.ui.Button):
    def __init__(self, book: "BookView", mode: str, label: str, count: int) -> None:
        self.book = book
        self.mode = mode
        super().__init__(
            label=f"{label} ({count})"[:80],
            row=1,
            style=(
                discord.ButtonStyle.success
                if mode == book.mode
                else discord.ButtonStyle.secondary
            ),
            disabled=count == 0 and mode != book.mode,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        self.book.mode = self.mode
        self.book.page = 0
        self.book.build()
        await interaction.response.edit_message(
            embed=self.book.card(), view=self.book
        )


class RankSelect(discord.ui.Select):
    """Nine ranks and "any", in one row instead of ten buttons.

    They were two rows of buttons, which is half the view's whole budget spent
    on one axis - and it is why there was nowhere to put quality or a search.
    A select says the same thing in one row and has room for rank ten the day
    somebody writes it.
    """

    def __init__(self, book: "BookView") -> None:
        self.book = book
        counts = {
            t: sum(1 for r in book.rows
                   if matches(r, book.mode, t, book.rarity, book.query))
            for t in range(1, 10)
        }
        any_count = sum(1 for r in book.rows
                        if matches(r, book.mode, None, book.rarity, book.query))
        super().__init__(
            placeholder="Which rank?",
            row=2,
            options=[
                discord.SelectOption(
                    label=f"Any rank ({any_count})",
                    value="any",
                    default=book.tier is None,
                )
            ] + [
                discord.SelectOption(
                    label=f"Rank {t} ({counts[t]})",
                    value=str(t),
                    default=book.tier == t,
                )
                for t in range(1, 10)
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        self.book.tier = None if self.values[0] == "any" else int(self.values[0])
        self.book.widen()
        self.book.page = 0
        self.book.build()
        await interaction.response.edit_message(
            embed=self.book.card(), view=self.book
        )


class QualitySelect(discord.ui.Select):
    """The axis people actually shop on.

    Rank is how deep a Gu is and quality is how good it is, and they are not
    the same question - a rank 3 Legendary and a rank 6 Common sit nowhere
    near each other on the bench. Counted within whatever else is selected, so
    a zero here means "none of these under your current filters" rather than
    "none exist".
    """

    def __init__(self, book: "BookView", rarities: list[str]) -> None:
        self.book = book
        counts = {
            q: sum(1 for r in book.rows
                   if matches(r, book.mode, book.tier, q, book.query))
            for q in rarities
        }
        any_count = sum(1 for r in book.rows
                        if matches(r, book.mode, book.tier, None, book.query))
        super().__init__(
            placeholder="Which quality?",
            row=3,
            options=[
                discord.SelectOption(
                    label=f"Any quality ({any_count})",
                    value="any",
                    default=book.rarity is None,
                )
            ] + [
                discord.SelectOption(
                    label=f"{q.title()} ({counts[q]})",
                    value=q,
                    default=book.rarity == q,
                    emoji=RARITY_MARK.get(q),
                )
                for q in rarities
            ][:24],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        self.book.rarity = None if self.values[0] == "any" else self.values[0]
        self.book.widen()
        self.book.page = 0
        self.book.build()
        await interaction.response.edit_message(
            embed=self.book.card(), view=self.book
        )


class SearchModal(AnsweringModal):
    """By name, because three thousand recipes is past browsing."""

    wanted = discord.ui.TextInput(
        label="Name contains",
        placeholder="moonlight",
        required=False,
        max_length=40,
    )

    def __init__(self, book: "BookView") -> None:
        super().__init__(title="Find a recipe")
        self.book = book
        if book.query:
            self.wanted.default = book.query

    async def on_submit(self, interaction: discord.Interaction) -> None:
        # Empty clears it, which is also how you get back out of a search
        # that found nothing.
        self.book.query = str(self.wanted).strip() or None
        self.book.widen()
        self.book.page = 0
        self.book.build()
        await interaction.response.edit_message(
            embed=self.book.card(), view=self.book
        )


class SearchButton(discord.ui.Button):
    def __init__(self, book: "BookView") -> None:
        self.book = book
        super().__init__(
            label="Search" if not book.query else f"“{book.query}”",
            emoji="\N{LEFT-POINTING MAGNIFYING GLASS}",
            row=1,
            style=(discord.ButtonStyle.primary if book.query
                   else discord.ButtonStyle.secondary),
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        await interaction.response.send_modal(SearchModal(self.book))


class BookPageButton(discord.ui.Button):
    def __init__(self, book: "BookView", step: int, glyph: str) -> None:
        self.book = book
        self.step = step
        super().__init__(label=glyph, row=4, style=discord.ButtonStyle.primary)

    async def callback(self, interaction: discord.Interaction) -> None:
        self.book.page = (self.book.page + self.step) % self.book.pages()
        self.book.build()
        await interaction.response.edit_message(
            embed=self.book.card(), view=self.book
        )


class BookView(AnsweringView):
    def __init__(
        self,
        player_id: int,
        user: discord.abc.User,
        rows: list[dict],
        skill: dict,
    ) -> None:
        super().__init__(timeout=300)
        self.player_id = player_id
        self.user = user
        self.rows = rows
        self.skill = skill
        # Open on the narrowest filter that has anything in it. A screen that
        # opens on an empty list has answered "what can I make" with "nothing"
        # when the true answer was "nothing yet, and here is what to go and get".
        self.mode = next(
            (m for m, _, _ in FILTERS if any(matches(r, m) for r in rows)), "all"
        )
        # Opens on the whole ladder. Picking a rank is how you narrow it, and
        # somebody who has not picked one yet has not told us where to look.
        self.tier: int | None = None
        # Quality and a name, both off until asked for. Every rarity the book
        # actually contains, deepest last, so the menu matches the game rather
        # than a hard-coded list that drifts when a rarity is added.
        self.rarity: str | None = None
        self.query: str | None = None
        # `RARITY_MARK` is already ordered shallowest to deepest and already
        # matches `rarities.sort_order` in the database. Reused rather than
        # restated so a rarity added later appears here without a second list
        # to remember.
        self.rarities = [
            q for q in RARITY_MARK
            if any(r["rarity"] == q for r in rows)
        ]
        self.page = 0
        self.build()

    def visible(self) -> list[dict]:
        return [r for r in self.rows
                if matches(r, self.mode, self.tier, self.rarity, self.query)]

    def widen(self) -> None:
        """Never answer a narrowing with a blank screen.

        Rank and quality compose with the state filter, so a rank can be empty
        under Ready and full under Every recipe. The rank BUTTONS did this and
        the selects that replaced them have to keep doing it - otherwise
        picking rank 4 answers "nothing" when the true answer is "nothing you
        can start today, and here is the list".

        A search that matches nothing anywhere is left alone: no state filter
        can rescue a word that is not in the book, and the card says how to
        clear it.
        """
        if self.visible():
            return
        for mode, _, _ in FILTERS:
            if any(matches(r, mode, self.tier, self.rarity, self.query)
                   for r in self.rows):
                self.mode = mode
                return

    def pages(self) -> int:
        return max(1, -(-len(self.visible()) // PER_PAGE))

    def build(self) -> None:
        self.clear_items()
        shown = self.visible()
        page = shown[self.page * PER_PAGE:(self.page + 1) * PER_PAGE]
        if page:
            self.add_item(RecipeSelect(self, page))
        for mode, label, _ in FILTERS:
            self.add_item(
                FilterButton(
                    self, mode, label,
                    sum(1 for r in self.rows
                        if matches(r, mode, self.tier, self.rarity, self.query)),
                )
            )
        self.add_item(SearchButton(self))
        # Every count on these is a count WITHIN whatever else is selected, so
        # a zero means "none of those under your current filters" rather than
        # "none exist". Two selects rather than ten buttons: the ranks used to
        # take rows 2 and 3 outright, which is why there was no room for
        # quality or a search until now.
        self.add_item(RankSelect(self))
        if self.rarities:
            self.add_item(QualitySelect(self, self.rarities))
        # Paging appears only when there is a second page, so the common case
        # is not two dead buttons.
        if self.pages() > 1:
            self.add_item(BookPageButton(self, -1, "\N{LEFTWARDS BLACK ARROW}"))
            self.add_item(BookPageButton(self, 1, "\N{BLACK RIGHTWARDS ARROW}"))

    def _lines(self, page: list[dict]) -> str:
        """As many recipes as fit, and an honest count of what did not.

        Two lines each - what it makes, then what is in the way - so a
        fixed count would overrun Discord's 1024 on a page of long names,
        and an overrun field costs the whole embed rather than the tail.
        """
        out: list[str] = []
        used = 0
        for r in page:
            line = (
                f"{MARKS[standing(r)]} {r['emoji']} **{r['gu_name']}** "
                f"`R{r['rank']}` {r['effects']}\n"
                + (f"     *{r['blocker']}*" if r["blocker"] else "     *ready*")
            )
            if used + len(line) + 1 > LIST_LIMIT and out:
                break
            out.append(line)
            used += len(line) + 1
        body = "\n".join(out)
        if len(page) > len(out):
            body += (
                f"\n*\N{HORIZONTAL ELLIPSIS} and {len(page) - len(out)} more in the "
                "list below.*"
            )
        return body

    def card(self) -> discord.Embed:
        shown = self.visible()
        blurb = next(text for m, _, text in FILTERS if m == self.mode)

        card = embed(
            "\N{ALEMBIC} Gu Refining",
            "A Gu is a **base** in bulk, a **secondary** that gives it its "
            "nature, and whatever **auxiliary** materials you decide to throw "
            "in. The first two are the price. The third is the decision.",
            colour=COLOUR_INFO,
        )
        card.add_field(
            name="Gu Refiner",
            value=(
                f"Level **{self.skill['level']}** "
                f"({thousands(self.skill['exp'])} EXP)\n"
                f"**{self.skill['slots']}** auxiliary materials on the bench  "
                f"\N{BULLET}  {self.skill['successes']} refined, "
                f"{self.skill['failures']} spoiled"
            ),
            inline=False,
        )

        page = shown[self.page * PER_PAGE:(self.page + 1) * PER_PAGE]
        card.add_field(
            name=(
                # Every axis that is narrowing the list, named. A screen
                # showing 4 of 3,035 has to say WHY, or the answer reads
                # as "there are four" instead of "you asked for four".
                f"Showing {len(shown)} \N{BULLET} {blurb}"
                + ("" if self.tier is None else f" \N{BULLET} rank {self.tier}")
                + ("" if self.rarity is None
                   else f" \N{BULLET} {self.rarity}")
                + ("" if not self.query
                   else f" \N{BULLET} matching “{self.query}”")
            ),
            value=self._lines(page)
            or ("*Nothing matches. Search again with an empty box to clear it.*" if self.query else "*Nothing here.*"),
            inline=False,
        )
        if self.pages() > 1:
            card.set_footer(
                text=f"Page {self.page + 1} of {self.pages()}. Every recipe opens, "
                "including the ones you cannot make yet."
            )
        else:
            card.set_footer(
                text="Every recipe opens, including the ones you cannot make yet "
                "\N{EM DASH} a locked one still shows you what to go and get."
            )
        return card

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "Not your workshop.", ephemeral=True
            )
            return False
        return True

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True


async def open_bench(interaction: discord.Interaction, player_id: int, gu_code: str) -> None:
    """Open a recipe. A recipe above your level opens too, and says so.

    It used to refuse. But "what do I need to be able to make this" is the
    question a crafting screen exists to answer, and refusing to draw the
    recipe answered it with the name of a level and nothing else.
    """
    recipe = await fetch_recipe(player_id, gu_code)
    if recipe is None:
        raise GameError(f"There is no recipe for `{gu_code}`.")

    skill = await fetch_skill(player_id)
    # Two gates, and they say different things. A rank the bench has not been
    # opened to does not care what level you are, so it is asked first and it
    # gets its own message - telling somebody to reach level 52 for a Gu that
    # is shut at any level sends them on a grind that would not have worked.
    closed = recipe["rank"] > recipe["refine_ceiling"]
    locked = closed or skill["level"] < recipe["required_level"]

    view = BenchView(player_id, interaction.user, recipe, skill, locked=locked)
    card = await render_bench(recipe, skill, view.aux, locked=locked, closed=closed)
    if interaction.response.is_done():
        view.message = await interaction.followup.send(embed=card, view=view)
    else:
        await interaction.response.send_message(embed=card, view=view)
        view.message = await interaction.original_response()


class GuRefine(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @app_commands.command(description="Refine materials into a Gu.")
    @app_commands.describe(gu="Which Gu to make. Leave it out to see what you can.")
    async def refinegu(
        self, interaction: discord.Interaction, gu: str | None = None
    ) -> None:
        player = await require_player(interaction.user)

        if gu is not None:
            await open_bench(interaction, player["player_id"], gu)
            return

        skill = await fetch_skill(player["player_id"])
        rows = await fetch_book(player["player_id"])
        if not rows:
            raise GameError("There are no Gu recipes in this world yet.")

        view = BookView(player["player_id"], interaction.user, rows, skill)
        await interaction.response.send_message(embed=view.card(), view=view)

    @refinegu.autocomplete("gu")
    async def gu_autocomplete(
        self, interaction: discord.Interaction, current: str
    ) -> list[app_commands.Choice[str]]:
        """Typing a name is the fastest way to a Gu you already know of, so
        this lists every recipe rather than only the reachable ones - and
        marks each with what the book would say about it, ready first.
        """
        player = await fetch_player(interaction.user.id)
        if player is None:
            return []

        rows = await db.fetch_all(
            """
            SELECT b.gu_code, b.gu_name, b.rank, b.ready, b.level_ok, b.blocker,
                   b.base_quantity, b.base_name
            FROM gu_recipe_book(%s) b
            WHERE b.gu_name ILIKE %s
            ORDER BY b.ready DESC, b.level_ok DESC, b.required_level, b.gu_name
            LIMIT 25
            """,
            (player["player_id"], f"%{current}%"),
        )
        return [
            app_commands.Choice(
                name=(
                    f"{MARKS[standing(r)]} {r['gu_name']} \N{BULLET} "
                    + (r["blocker"] or f"{r['base_quantity']}x {r['base_name']}")
                )[:100],
                value=r["gu_code"],
            )
            for r in rows
        ]


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(GuRefine(bot))


