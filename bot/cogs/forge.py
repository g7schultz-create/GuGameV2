"""Blacksmithing: /forge and /gear.

There is no recipe list, so the screen cannot show you one. What it shows is
what is on the anvil and what that makes it: the slot, the ore holding the
ceiling, the parts deciding what it does, and the Paths arguing about all of
it.

The anvil is the cauldron's shape on purpose. A player who has brewed a pill
already knows how to read this: put material in, watch the preview move, press
the button. Two screens teaching two grammars for one idea is worse than a
screen that repeats itself.

Nothing here computes a game number. Potency, the tier it buys, the quality
band and the Path agreement all come back from SQL, out of the tables
`forge()` reads.
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
    effect_amount,
    embed,
    error_embed,
    percent,
    thousands,
)
from bot.picking import (
    PagedPicker,
    add_page_buttons,
    by_type_and_strength,
    page_count,
    page_note,
    page_of,
)
from bot.views import AnsweringView, answer_error
from bot.players import GameError, require_player, settle_passive

# The bands `pair_harmony` actually returns, the same reading /alchemy uses.
AGREEMENT = (
    (8, "\N{WHITE HEAVY CHECK MARK}", "agrees"),
    (1, "\N{WHITE MEDIUM SQUARE}", "no quarrel"),
    (-15, "\N{WARNING SIGN}", "fights"),
)

ANVIL = "\N{HAMMER AND PICK}"

# Constants rather than inline literals, following world.py: a named escape
# inside an f-string expression is legal on this Python and confusing on any.
TICK = "\N{WHITE HEAVY CHECK MARK}"
DOT = "\N{BULLET}"


def agreement_word(value) -> str:
    for threshold, icon, word in AGREEMENT:
        if value >= threshold:
            return f"{icon} {word}"
    return "\N{CROSS MARK} ruins it"


# ---------------------------------------------------------------------------
# Reading the anvil
# ---------------------------------------------------------------------------


async def fetch_skill(player_id: int) -> dict:
    return await db.fetch_one(
        """
        SELECT profession_level(%s, 'blacksmithing') AS level,
               COALESCE(pp.exp, 0) AS exp,
               COALESCE(pp.successes, 0) AS successes,
               COALESCE(pp.failures, 0) AS failures,
               smith_part_slots(profession_level(%s, 'blacksmithing')) AS parts,
               smith_ore_slots(profession_level(%s, 'blacksmithing')) AS ores,
               smith_tier_cap(profession_level(%s, 'blacksmithing')) AS tier_cap
        FROM professions pr
        LEFT JOIN player_professions pp
               ON pp.profession = pr.code AND pp.player_id = %s
        WHERE pr.code = 'blacksmithing'
        """,
        (player_id, player_id, player_id, player_id, player_id),
    )


async def fetch_ores(player_id: int, tier_cap: int) -> list[dict]:
    """Ore in the pack, deepest first, and only what this anvil can work.

    Filtering here rather than letting `forge()` refuse it means the picker
    never offers a metal that the button would then reject.
    """
    return await db.fetch_all(
        """
        SELECT pm.material_code AS code, m.name, m.emoji, m.rarity,
               o.tier, o.word, p.name AS path_name, m.path_code,
               ef.name AS signature_name, ef.emoji AS signature_emoji,
               pm.quantity
        FROM player_materials pm
        JOIN materials m ON m.code = pm.material_code
        JOIN ores o      ON o.material_code = pm.material_code
        JOIN paths p     ON p.code = m.path_code
        JOIN gu_effects ef ON ef.code = o.signature
        WHERE pm.player_id = %s AND pm.quantity > 0 AND o.tier <= %s
        ORDER BY o.tier DESC, m.name
        """,
        (player_id, tier_cap),
    )


async def fetch_parts(player_id: int) -> list[dict]:
    return await db.fetch_all(
        """
        SELECT pm.material_code AS code, m.name, m.emoji, m.rarity,
               material_grade(m.rarity) AS grade,
               pk.code AS part, pk.name AS part_name, pk.emoji AS part_emoji,
               p.name AS path_name, m.path_code, pm.quantity
        FROM player_materials pm
        JOIN materials m     ON m.code = pm.material_code
        JOIN beast_parts bp  ON bp.material_code = pm.material_code
        JOIN part_kinds pk   ON pk.code = bp.part
        JOIN paths p         ON p.code = m.path_code
        WHERE pm.player_id = %s AND pm.quantity > 0
        ORDER BY material_grade(m.rarity) DESC, m.name
        """,
        (player_id,),
    )


async def read_anvil(
    slot: str, ores: dict[str, int], parts: dict[str, int]
) -> dict | None:
    """What is on the anvil and what it would become.

    One query per question, and every one of them asks the same tables
    `forge()` will ask. The preview is not a second opinion.
    """
    if not ores or not parts:
        return None

    codes, amounts = list(parts.keys()), list(parts.values())
    ore_codes, ore_amounts = list(ores.keys()), list(ores.values())

    # Every metal on the anvil, dearest first - the same order the forge reads
    # them in, so the one at the top is the one that leads.
    metals = await db.fetch_all(
        """
        SELECT m.name, m.emoji, u.quantity, o.tier, m.path_code,
               p.name AS path_name,
               ef.name AS signature_name, ef.emoji AS signature_emoji,
               o.tier::numeric ^ 2 * u.quantity AS potency
        FROM unnest(%s::text[], %s::int[]) AS u (code, quantity)
        JOIN ores o      ON o.material_code = u.code
        JOIN materials m ON m.code = u.code
        JOIN paths p     ON p.code = m.path_code
        JOIN gu_effects ef ON ef.code = o.signature
        ORDER BY o.tier DESC, o.tier::numeric ^ 2 * u.quantity DESC, m.name
        """,
        (ore_codes, ore_amounts),
    )
    lead = metals[0]
    lines = await db.fetch_all(
        """
        SELECT m.name, m.emoji, u.quantity,
               material_grade(m.rarity) AS grade,
               material_grade(m.rarity) ^ 2 * u.quantity AS potency,
               pk.name AS part_name, p.name AS path_name, m.path_code
        FROM unnest(%s::text[], %s::int[]) AS u (code, quantity)
        JOIN materials m    ON m.code = u.code
        JOIN beast_parts bp ON bp.material_code = u.code
        JOIN part_kinds pk  ON pk.code = bp.part
        JOIN paths p        ON p.code = m.path_code
        ORDER BY material_grade(m.rarity) ^ 2 * u.quantity DESC, m.name
        """,
        (codes, amounts),
    )

    ore_potency = sum(int(r["potency"]) for r in metals)
    total = ore_potency + sum(int(r["potency"]) for r in lines)

    grade = await db.fetch_one(
        """
        SELECT (SELECT max(et.tier) FROM equipment_tiers et
                WHERE et.potency_required <= %s) AS by_potency
        """,
        (total,),
    )

    # How each Path on the anvil sits with the metal, which is the foundation
    # and therefore the one that gets to be right.
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
        (lead["path_code"], codes + ore_codes, lead["path_code"]),
    )

    # A reaction the smith could actually hold is worth previewing; one they
    # could not is the lesson they are about to be taught.
    reaction = await db.fetch_one(
        """
        SELECT r.word, r.min_level, r.description, ef.name AS effect_name
        FROM forge_reactions r
        JOIN gu_effects ef ON ef.code = r.effect_code
        JOIN unnest(%s::text[]) AS u (code) ON TRUE
        JOIN materials m ON m.code = u.code
        WHERE (r.path_a = %s AND r.path_b = m.path_code)
           OR (r.path_b = %s AND r.path_a = m.path_code)
        ORDER BY r.min_level
        LIMIT 1
        """,
        (codes, lead["path_code"], lead["path_code"]),
    )

    return {
        "lines": lines,
        "metals": metals,
        "lead": lead,
        "potency": total,
        "ore_potency": ore_potency,
        "by_potency": grade["by_potency"],
        "agreement": agreement,
        "reaction": reaction,
    }


async def render_anvil(
    skill: dict, slot: dict, ores: dict[str, int], parts: dict[str, int]
) -> discord.Embed:
    read = await read_anvil(slot["code"], ores, parts)

    card = embed(
        f"{ANVIL} The anvil",
        "Ore and carcass, not a recipe. Several metals may go on at once and "
        "their potency adds up, but the **best of them decides the ceiling** — "
        "a piece is never deeper than the finest thing in it. The **beast "
        "materials decide what it does**, and how well every Path agrees "
        "decides how much survives the quench.",
        colour=COLOUR_DEFAULT,
    )
    card.add_field(
        name="Blacksmith",
        value=(
            f"Level **{skill['level']}** ({thousands(skill['exp'])} EXP)\n"
            f"Tier **{skill['tier_cap']}** pieces \N{BULLET} **{skill['ores']}** "
            f"metal{'' if skill['ores'] == 1 else 's'} and **{skill['parts']}** "
            f"beast material{'' if skill['parts'] == 1 else 's'} on the anvil  \N{BULLET}  "
            f"{skill['successes']} forged, {skill['failures']} ruined"
        ),
        inline=False,
    )
    card.add_field(
        name="Making",
        value=f"{slot['emoji']} **{slot['name']}** — *{slot['description']}*",
        inline=False,
    )

    if read is None or not ores:
        card.add_field(
            name="Metal",
            value="*Nothing. **/mine** — every region has veins under it.*",
            inline=False,
        )
    else:
        # The leading metal first and marked, because it is the one that sets
        # the ceiling and lends the piece its signature; the rest is weight.
        card.add_field(
            name=f"Metal ({len(ores)}/{skill['ores']})",
            value="\n".join(
                f"{r['emoji']} **{r['name']}** \N{MULTIPLICATION SIGN}{r['quantity']} "
                f"\N{BULLET} tier {r['tier']} {r['path_name']} "
                f"\N{BULLET} {int(r['potency'])} potency"
                + (
                    f"\n     \N{DOWNWARDS ARROW WITH TIP LEFTWARDS} leads \N{BULLET} "
                    f"{r['signature_emoji']} {r['signature_name']}"
                    if r is read["lead"]
                    else ""
                )
                for r in read["metals"]
            ),
            inline=False,
        )

    if read is None:
        card.add_field(
            name="On the anvil",
            value="*Empty. Ore alone is an ingot — something off a beast has to go in.*",
            inline=False,
        )
        return card

    card.add_field(
        name=f"On the anvil ({len(parts)}/{skill['parts']})",
        value="\n".join(
            f"{r['emoji']} **{r['name']}** \N{MULTIPLICATION SIGN}{r['quantity']} "
            f"\N{BULLET} {r['part_name']} \N{BULLET} {r['path_name']} "
            f"\N{BULLET} {int(r['potency'])} potency"
            for r in read["lines"]
        ),
        inline=False,
    )

    reachable = min(
        x for x in (read["by_potency"], read["lead"]["tier"], skill["tier_cap"])
        if x is not None
    ) if read["by_potency"] else None

    # Tier 8 is not reached by weight and a good metal alone. `forge` drops a
    # short attempt to 7 immediately after taking the same LEAST() this line
    # does, so the shortfall has to be asked BEFORE the tier is announced -
    # this screen used to mirror the LEAST and stop, and told clea her anvil
    # would make a tier 8 while the forge quietly made her a tier 7.
    #
    # Asked whenever the WEIGHT alone would carry tier 8, not only when the
    # tier is otherwise within reach: somebody with three thousand iron and a
    # tier 1 metal is owed the summit's shopping list too, and that is what
    # tells them a Blacksmith of 85 and three kinds of tier 8 metal are what
    # they are actually short of.
    short = None
    if read["by_potency"] and read["by_potency"] >= 8:
        short = await db.fetch_value(
            "SELECT pseudo_immortal_shortfall(%s, %s, %s, %s, %s::smallint)",
            (list(ores.keys()), list(ores.values()),
             list(parts.keys()), list(parts.values()), skill["level"]),
        )
        # The downgrade only bites when the tier was otherwise reachable.
        # Below that, something else is already the binding constraint and is
        # named on its own line.
        if short and reachable is not None and reachable >= 8:
            reachable = 7
            downgraded = True
        else:
            downgraded = False
    else:
        downgraded = False

    if reachable is None:
        becomes = (
            f"**{thousands(read['potency'])} potency** — not yet enough "
            "for anything. Tier 1 wants 4."
        )
    else:
        becomes = (
            f"**{thousands(read['potency'])} potency** → "
            f"a **tier {reachable}** piece"
        )
        held_by = []
        if read["by_potency"] > reachable and read["lead"]["tier"] == reachable:
            held_by.append(f"the best metal is tier {read['lead']['tier']}")
        if read["by_potency"] > reachable and skill["tier_cap"] == reachable:
            held_by.append(f"your anvil reaches tier {skill['tier_cap']}")
        if held_by:
            becomes += (
                f"\n*The weight is worth tier {read['by_potency']}, but "
                + " and ".join(held_by)
                + ".*"
            )
        if short and downgraded:
            # The reason for the tier printed above, rather than a footnote
            # attached to a different number.
            becomes += (
                f"\n*The weight would carry tier 8, but Pseudo-Immortal still "
                f"wants {short}.*"
            )
        elif short:
            # The weight is there but something else is the wall. This is the
            # summit's shopping list, not an explanation of the tier above.
            becomes += f"\n*Pseudo-Immortal (tier 8) still wants {short}.*"

    card.add_field(name="Becomes", value=becomes, inline=False)

    if read["agreement"]:
        card.add_field(
            name=f"Against {read['lead']['path_name']}, which the leading metal brings",
            value="\n".join(
                f"{agreement_word(a['agreement'])} \N{BULLET} {a['path_name']}"
                for a in read["agreement"]
            ),
            inline=False,
        )
    else:
        card.add_field(
            name="Agreement",
            value=f"All of it is {read['lead']['path_name']}. Nothing on the anvil argues.",
            inline=False,
        )

    if read["reaction"] is not None:
        r = read["reaction"]
        if skill["level"] >= r["min_level"]:
            card.add_field(
                name=f"\N{FIRE} {r['word']}",
                value=f"You can hold this one. *{r['description']}* "
                f"— it adds {r['effect_name']}.",
                inline=False,
            )
        else:
            card.add_field(
                name=f"\N{WARNING SIGN} {r['word']}, at level {r['min_level']}",
                value="Those two fight, and you are not yet good enough to make "
                "them fight usefully. The penalty stands either way.",
                inline=False,
            )

    card.set_footer(
        text="Potency sets the tier; harmony sets the quality. "
        "Below 25 the piece comes apart and half of it is raked back."
    )
    return card


async def render_batch(result: dict, slot_name: str) -> discord.Embed:
    """A whole sitting, summarised.

    Ten forgings drawn one card each is ten cards nobody reads. What a smith
    wants back is how many held, the best of them and what it cost - so the
    pieces are listed best-first and the arithmetic is done here rather than
    left for them to do.
    """
    made = result["made"] or []
    if not result["succeeded"]:
        card = embed(
            "💥 Nothing held",
            f"{result['attempts']} forgings and every one of them came apart.",
            colour=COLOUR_BAD,
        )
    else:
        card = embed(
            "⚒ The sitting is done",
            f"**{result['succeeded']}** of {result['attempts']} held "
            f"— {result['ruined']} came apart.",
            colour=COLOUR_GOOD if result["succeeded"] else COLOUR_BAD,
        )

    if made:
        lines = [
            f"{RARITY_MARK.get(m['rarity'], '')} **{m['name']}** "
            f"{DOT} {str(m['quality']).title()} {DOT} L{m['level']} T{m['tier']}"
            for m in made[:10]
        ]
        if len(made) > 10:
            lines.append(f"*and {len(made) - 10} more.*")
        card.add_field(name=f"What came off the anvil ({slot_name})",
                       value="\n".join(lines), inline=False)

    card.add_field(
        name="Harmony",
        value=(f"best **{result['best_harmony']}**, worst "
               f"**{result['worst_harmony']}**"
               if result["succeeded"] else "nothing to report"),
        inline=True,
    )
    card.add_field(
        name="Materials",
        value=f"{thousands(result['spent_total'] - result['handed_back'])} spent"
              + (f", {thousands(result['handed_back'])} raked back"
                 if result["handed_back"] else ""),
        inline=True,
    )
    card.set_footer(text=f"Blacksmithing {result['level_after']} "
                         f"{DOT} +{thousands(result['exp_gained'])} exp")
    return card


async def render_result(result: dict) -> discord.Embed:
    if not result["succeeded"]:
        card = embed(
            "\N{COLLISION SYMBOL} The piece comes apart",
            f"Harmony **{result['harmony']}** — nothing on that anvil was going "
            "to hold together.",
            colour=COLOUR_BAD,
        )
        card.add_field(
            name="Lost",
            value=f"{thousands(result['spent_total'] - result['handed_back'])} of "
            f"{thousands(result['spent_total'])} materials. "
            f"{thousands(result['handed_back'])} were raked back out.",
            inline=False,
        )
        card.add_field(
            name="Learned anyway",
            value=f"+{result['exp_gained']} Blacksmith EXP — level "
            f"{result['level_after']}.",
            inline=False,
        )
        return card

    effects = await db.fetch_all(
        """
        SELECT ef.name, ef.emoji, ee.magnitude, ef.is_live, ef.is_base
        FROM equipment_effects ee
        JOIN gu_effects ef ON ef.code = ee.effect_code
        WHERE ee.equipment_id = %s
        ORDER BY ee.magnitude DESC
        """,
        (result["equipment_id"],),
    )
    slot = await db.fetch_one(
        "SELECT name, emoji FROM equipment_slots WHERE code = %s", (result["slot"],)
    )

    card = embed(
        f"{slot['emoji']} {result['item_name']}",
        f"{RARITY_MARK.get(result['quality'], '')} **{result['quality'].title()}** "
        f"tier {result['item_tier']} {slot['name'].lower()} \N{BULLET} harmony "
        f"**{result['harmony']}** \N{BULLET} {thousands(result['potency'])} potency",
        colour=COLOUR_GOOD,
    )
    card.add_field(
        name="It is worth",
        value="\n".join(
            f"{e['emoji']} "
            f"**{effect_amount(e['magnitude'], is_base=e['is_base'])}** "
            f"{e['name']}"
            for e in effects
        )
        or "*nothing measurable, which should not happen*",
        inline=False,
    )
    if result["reaction"]:
        card.add_field(
            name=f"\N{FIRE} {result['reaction']}",
            value="Two Paths that should have ruined each other, held.",
            inline=False,
        )
    card.set_footer(
        text=f"+{result['exp_gained']} Blacksmith EXP — level {result['level_after']}. "
        "/gear to wear it."
    )
    return card


# ---------------------------------------------------------------------------
# The bench
# ---------------------------------------------------------------------------


class AmountModal(discord.ui.Modal):
    amount = discord.ui.TextInput(label="Quantity", max_length=12, required=True)

    def __init__(self, screen: "AnvilView", code: str, name: str, held: int, *, is_ore: bool) -> None:
        super().__init__(title="How much goes in?")
        self.screen = screen
        self.code = code
        self.is_ore = is_ore
        self.amount.placeholder = f"You hold {held} {name}. 0 takes it off."[:100]

    async def on_submit(self, interaction: discord.Interaction) -> None:
        try:
            wanted = int(str(self.amount).strip())
        except ValueError as exc:
            raise GameError("That is not a number.") from exc

        if wanted < 0:
            raise GameError("A negative amount of anything is not a thing.")

        if self.is_ore:
            if wanted == 0:
                self.screen.ores.pop(self.code, None)
                said = "Taken off."
            else:
                if (
                    self.code not in self.screen.ores
                    and len(self.screen.ores) >= self.screen.skill["ores"]
                ):
                    raise GameError(
                        f"Your anvil holds {self.screen.skill['ores']} metals. "
                        "Take one off, or raise your Blacksmith level."
                    )
                self.screen.ores[self.code] = wanted
                said = "On the anvil."
        elif wanted == 0:
            self.screen.parts.pop(self.code, None)
            said = "Taken off."
        else:
            if (
                self.code not in self.screen.parts
                and len(self.screen.parts) >= self.screen.skill["parts"]
            ):
                raise GameError(
                    f"Your anvil holds {self.screen.skill['parts']} beast "
                    "materials. Take one off, or raise your Blacksmith level."
                )
            self.screen.parts[self.code] = wanted
            said = "On the anvil."

        await self.screen.refresh(interaction, said)

    async def on_error(self, interaction: discord.Interaction, error: Exception) -> None:
        if not await answer_error(interaction, error):
            await super().on_error(interaction, error)


class RunsModal(discord.ui.Modal):
    """How many to work at this sitting.

    A modal rather than a row of 2/5/10 buttons: the cap moves with the
    smith's level, so a fixed set of buttons would either offer a number they
    cannot use or hide one they can.
    """

    times = discord.ui.TextInput(label="How many", max_length=3, required=True)

    def __init__(self, screen: "AnvilView", cap: int) -> None:
        super().__init__(title="A sitting at the anvil")
        self.screen = screen
        self.cap = cap
        self.times.placeholder = (
            f"1 to {cap}. Your Blacksmithing works {cap} at once."
        )[:100]

    async def on_submit(self, interaction: discord.Interaction) -> None:
        try:
            wanted = int(str(self.times).strip())
        except ValueError as exc:
            raise GameError("That is not a number.") from exc
        if wanted < 1:
            raise GameError("A sitting of none is not a sitting.")
        if wanted > self.cap:
            raise GameError(
                f"Your Blacksmithing works {self.cap} at a sitting, not {wanted}."
            )
        await self.screen.strike_many(interaction, wanted)

    # The same handler `AmountModal` carries, and for the same reason: a modal
    # that raises without answering leaves the player looking at a spinner.
    # `test_every_modal_answers_too` refuses one that has neither this nor an
    # AnsweringModal base, and it caught this one.
    async def on_error(self, interaction: discord.Interaction, error: Exception) -> None:
        if not await answer_error(interaction, error):
            await super().on_error(interaction, error)


class OrePicker(discord.ui.Select):
    def __init__(self, screen: "AnvilView", rows: list[dict]) -> None:
        self.screen = screen
        self.rows = {r["code"]: r for r in rows}
        super().__init__(
            placeholder="Which metal?",
            options=[
                discord.SelectOption(
                    label=f"T{r['tier']} {r['name']} \N{MULTIPLICATION SIGN}{thousands(r['quantity'])}"[:100],
                    value=r["code"],
                    description=f"{r['path_name']} \N{BULLET} {r['signature_name']}"[:100],
                    emoji=r["emoji"][:1] if r["emoji"] else None,
                )
                for r in rows
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        row = self.rows[self.values[0]]
        await interaction.response.send_modal(
            AmountModal(self.screen, row["code"], row["name"], row["quantity"], is_ore=True)
        )


class PartPicker(discord.ui.Select):
    def __init__(self, screen: "AnvilView", rows: list[dict]) -> None:
        self.screen = screen
        self.rows = {r["code"]: r for r in rows}
        super().__init__(
            placeholder="Which beast material?",
            options=[
                discord.SelectOption(
                    label=f"{r['name']} \N{MULTIPLICATION SIGN}{thousands(r['quantity'])}"[:100],
                    value=r["code"],
                    description=f"{r['part_name']} \N{BULLET} {r['path_name']}"[:100],
                    emoji=r["emoji"][:1] if r["emoji"] else None,
                )
                for r in rows
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        row = self.rows[self.values[0]]
        await interaction.response.send_modal(
            AmountModal(self.screen, row["code"], row["name"], row["quantity"], is_ore=False)
        )


class SlotPicker(discord.ui.Select):
    def __init__(self, screen: "AnvilView", rows: list[dict]) -> None:
        self.screen = screen
        self.rows = {r["code"]: r for r in rows}
        super().__init__(
            placeholder="Making what?",
            options=[
                discord.SelectOption(
                    label=r["name"],
                    value=r["code"],
                    description=r["description"][:100],
                    emoji=r["emoji"][:1] if r["emoji"] else None,
                )
                for r in rows
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        self.screen.slot = self.rows[self.values[0]]
        await self.screen.refresh(interaction, f"Making a {self.screen.slot['name'].lower()}.")


class PickerView(PagedPicker):
    """The shared paged menu, with this cog's way of answering a refusal."""

    async def on_error(self, interaction, error: Exception, item) -> None:
        if not await answer_error(interaction, error):
            await super().on_error(interaction, error, item)


class AnvilView(AnsweringView):
    def __init__(
        self, player_id: int, user: discord.abc.User, skill: dict,
        slots: list[dict], slot: dict,
    ) -> None:
        super().__init__(timeout=600)
        self.player_id = player_id
        self.user = user
        self.skill = skill
        self.slots = slots
        self.slot = slot
        self.ores: dict[str, int] = {}
        self.parts: dict[str, int] = {}
        self.message: discord.Message | None = None

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message("Not your anvil.", ephemeral=True)
            return False
        return True

    async def refresh(self, interaction: discord.Interaction, said: str) -> None:
        card = await render_anvil(self.skill, self.slot, self.ores, self.parts)
        if interaction.response.is_done():
            await interaction.followup.send(said, ephemeral=True)
        else:
            await interaction.response.send_message(said, ephemeral=True)
        if self.message is not None:
            await self.message.edit(embed=card, view=self)

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True

    # Rows are explicit from here down. Six buttons auto-flow to 5 + 1,
    # which strands "Forge many" on a line of its own below Forge;
    # setting them puts the two ways of striking side by side, where
    # the choice between them actually is.
    @discord.ui.button(label="Making", emoji="\N{CROSSED SWORDS}", style=discord.ButtonStyle.secondary, row=0)
    async def choose_slot(self, interaction: discord.Interaction, button) -> None:
        await interaction.response.send_message(
            "What are you making?",
            view=PickerView(lambda page: SlotPicker(self, page), self.slots),
            ephemeral=True,
        )

    @discord.ui.button(label="Metal", emoji="\N{PICK}", style=discord.ButtonStyle.secondary, row=0)
    async def choose_ore(self, interaction: discord.Interaction, button) -> None:
        rows = await fetch_ores(self.player_id, self.skill["tier_cap"])
        if not rows:
            raise GameError(
                "You are holding no ore your anvil can work. **/mine** — every "
                "region has veins under it."
            )
        await interaction.response.send_message(
            "Your ore, the deepest first. Only the top 25 are listed.",
            view=PickerView(
                lambda page: OrePicker(self, page), rows, noun="ores"
            ),
            ephemeral=True,
        )

    @discord.ui.button(label="Add part", emoji="\N{BONE}", style=discord.ButtonStyle.secondary, row=0)
    async def add_part(self, interaction: discord.Interaction, button) -> None:
        rows = await fetch_parts(self.player_id)
        if not rows:
            raise GameError(
                "You are holding nothing off a beast. **/hunt** — every kill "
                "leaves something behind."
            )
        await interaction.response.send_message(
            "What came off the beasts, the best first. Only the top 25 are listed.",
            view=PickerView(
                lambda page: PartPicker(self, page), rows, noun="parts"
            ),
            ephemeral=True,
        )

    @discord.ui.button(label="Clear", style=discord.ButtonStyle.secondary, row=0)
    async def clear(self, interaction: discord.Interaction, button) -> None:
        self.ores.clear()
        self.parts.clear()
        await self.refresh(interaction, "Swept off.")

    @discord.ui.button(label="Forge", style=discord.ButtonStyle.success, row=1)
    async def strike(self, interaction: discord.Interaction, button) -> None:
        if not self.ores:
            raise GameError("A forging starts with ore. Pick a metal.")
        if not self.parts:
            raise GameError("Ore alone is an ingot. Put something off a beast in.")

        try:
            result = await db.fetch_one(
                "SELECT * FROM forge(%s, %s, %s, %s, %s, %s)",
                (
                    self.player_id,
                    self.slot["code"],
                    list(self.ores.keys()),
                    list(self.ores.values()),
                    list(self.parts.keys()),
                    list(self.parts.values()),
                ),
            )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0].capitalize()) from exc

        for item in self.children:
            item.disabled = True
        await interaction.response.edit_message(
            embed=await render_result(result), view=self
        )
        self.stop()

    @discord.ui.button(label="Forge many", emoji="⚒",
                       style=discord.ButtonStyle.primary, row=1)
    async def strike_many_button(self, interaction: discord.Interaction, button) -> None:
        if not self.ores:
            raise GameError("A forging starts with ore. Pick a metal.")
        if not self.parts:
            raise GameError("Ore alone is an ingot. Put something off a beast in.")

        cap = await db.fetch_value(
            "SELECT smith_max_runs(profession_level(%s, 'blacksmithing'))",
            (self.player_id,),
        )
        await interaction.response.send_modal(RunsModal(self, int(cap)))

    async def strike_many(self, interaction: discord.Interaction, times: int) -> None:
        """One call, not a loop of them.

        `forge_many` checks every material for the WHOLE run before spending
        any of it, so a sitting the player cannot afford costs nothing. A loop
        here would forge six of ten and then fail, with six lots of materials
        already gone on what was asked for as one action.
        """
        try:
            result = await db.fetch_one(
                "SELECT * FROM forge_many(%s, %s, %s, %s, %s, %s, %s)",
                (
                    self.player_id,
                    self.slot["code"],
                    list(self.ores.keys()),
                    list(self.ores.values()),
                    list(self.parts.keys()),
                    list(self.parts.values()),
                    times,
                ),
            )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0].capitalize()) from exc

        for item in self.children:
            item.disabled = True
        await interaction.response.edit_message(
            embed=await render_batch(result, self.slot["name"]), view=self
        )
        self.stop()


# ---------------------------------------------------------------------------
# The rack
# ---------------------------------------------------------------------------


async def fetch_gear(player_id: int) -> list[dict]:
    """Everything forged, with what it is worth and whether it is worn.

    The effects come back as one aggregated string rather than a second query
    per piece: a rack of twelve pieces would otherwise be thirteen round trips.
    """
    return await db.fetch_all(
        """
        SELECT pe.equipment_id, pe.name, pe.slot, pe.tier, pe.rarity, pe.harmony,
               pe.level, pe.rank, pe.quality,
               qb.name AS quality_name,
               pe.reaction, s.name AS slot_name, s.emoji AS slot_emoji,
               s.sort_order,
               (q.equipment_id IS NOT NULL) AS worn,
               COALESCE((
                   -- `effect_amount` rather than a fourth hand-rolled copy
                   -- of it. The one that used to live here wrote its own '+'
                   -- in front of the number, which is how a negative base
                   -- stat came out as a doubled sign everywhere it was done
                   -- by hand.
                   --
                   -- Ordered by is_base first: a base stat is counted in
                   -- points and everything else is a fraction, so sorting the
                   -- two together by size ranks 88 Sinew above a doubling and
                   -- calls that the bigger number.
                   SELECT string_agg(
                       ef.emoji || ' ' || ef.name || ' ' ||
                       effect_amount(ee.effect_code, ee.magnitude),
                       chr(10) ORDER BY ef.is_base, ee.magnitude DESC)
                   FROM equipment_effects ee
                   JOIN gu_effects ef ON ef.code = ee.effect_code
                   WHERE ee.equipment_id = pe.equipment_id
               ), 'nothing') AS effect_text,
               -- What the piece pays in total, so "strongest" can mean the
               -- piece that does the most rather than the highest number
               -- stamped on it: a loaded tier 3 beats a hollow tier 4.
               COALESCE((
                   -- Fractions only. A base stat is points rather than a
                   -- share, so adding ten Sinew to four tenths of Evasion
                   -- would rank every boot above every other piece while
                   -- measuring nothing.
                   SELECT sum(ee.magnitude) FROM equipment_effects ee
                   JOIN gu_effects f2 ON f2.code = ee.effect_code
                   WHERE ee.equipment_id = pe.equipment_id
                     AND NOT f2.is_base
               ), 0) AS effect_total
        FROM player_equipment pe
        JOIN equipment_slots s ON s.code = pe.slot
        JOIN equipment_quality_bands qb ON qb.code = pe.quality
        LEFT JOIN player_equipped q ON q.equipment_id = pe.equipment_id
        WHERE pe.owner_id = %s
        ORDER BY (q.equipment_id IS NOT NULL) DESC, s.sort_order, pe.tier DESC, pe.name
        """,
        (player_id,),
    )


# Sorting a rack. Tier is the grade, harmony separates two of the same grade,
# and "best" adds up what a piece actually pays so a tier 3 loaded with useful
# affixes can beat a hollow tier 4.
# The four slots, for the filter row. `equipment_slots` is the authority and a
# test asserts these match it - a button row cannot await a query.
SLOT_BUTTONS = (
    ("weapon", "Weapon", "\N{CROSSED SWORDS}"),
    ("armour", "Armour", "\N{SHIELD}"),
    ("helm", "Helm", "\N{HELMET WITH WHITE CROSS}"),
    ("boots", "Boots", "\N{WOMANS BOOTS}"),
)

GEAR_SORTS = (
    ("best", "Strongest", lambda r: (-float(r["effect_total"]), -r["tier"])),
    ("tier", "Tier", lambda r: (-r["tier"], -r["harmony"])),
    ("harmony", "Harmony", lambda r: (-r["harmony"], -r["tier"])),
    ("name", "Name", lambda r: (r["name"].lower(),)),
)


STAR = "\N{WHITE MEDIUM STAR}"


def gear_line(row: dict, worn_mark: str) -> str:
    """One piece, one line.

    A field each was 59 lines for eight of twenty pieces, and the effects -
    every one of them, one per line - were most of it. The two that matter
    most are the ones a rack is read for; **/forge** shows a piece in full.
    """
    top = row["effect_text"].split(chr(10))[:2]
    affixes = " ".join(t.split(" ", 1)[0] + " " + t.rsplit(" ", 1)[-1]
                       for t in top if t and t != "nothing")
    return (
        f"{worn_mark}{row['slot_emoji']} **{row['name']}** "
        f"{RARITY_MARK.get(row['rarity'], '')} "
        f"{STAR * int(row['rank'])} L{row['level']} T{row['tier']} "
        f"\N{BULLET} {row['quality_name']}"
        + (f" \N{BULLET} {affixes}" if affixes else "")
    )


def chunk_lines(lines: list[str], limit: int = 1024) -> list[str]:
    """Field-sized blocks. Twenty pieces do not fit in one."""
    out: list[str] = []
    for line in lines:
        if out and len(out[-1]) + len(line) + 1 <= limit:
            out[-1] += "\n" + line
        else:
            out.append(line)
    return out


async def render_gear(
    player_id: int,
    rows: list[dict],
    display_name: str,
    *,
    page: int = 0,
    slot: str | None = None,
    sort: str = "best",
    chosen: dict | None = None,
) -> discord.Embed:
    """The rack, one line per piece.

    Every piece of the chosen slot is drawn, because the thing a rack is for
    is comparing pieces of ONE slot against each other - and the old screen
    could not do that at all: it drew eight pieces across all four slots and
    left "12 more on this page, in the list below", so a player could equip
    something they had never been shown.
    """
    worn = [r for r in rows if r["worn"]]
    totals = await db.fetch_all(
        """
        SELECT ef.name, ef.emoji, s.total, s.capped, ef.is_base
        FROM player_equipment_stats s
        JOIN gu_effects ef ON ef.code = s.effect_code
        WHERE s.player_id = %s
        ORDER BY s.total DESC
        """,
        (player_id,),
    )
    empty = await db.fetch_all(
        """
        SELECT s.name, s.emoji FROM equipment_slots s
        WHERE NOT EXISTS (
            SELECT 1 FROM player_equipped q
            WHERE q.player_id = %s AND q.slot = s.code)
        ORDER BY s.sort_order
        """,
        (player_id,),
    )

    card = embed(
        f"{ANVIL} {display_name}'s gear",
        f"{len(worn)} of 4 slots filled, {len(rows)} pieces forged. What a piece "
        "gives is added to the same stack a Gu and a manual feed \N{EM DASH} "
        "never multiplied into it. Most of it is a percentage; Sinew, Hide and "
        "Body are points on your body instead.",
        colour=COLOUR_INFO,
    )

    # The chosen piece in full, which is the thing the rack could not do. A
    # line in the rack shows two of its stats because twenty pieces of five
    # stats each is four hundred lines; one piece can afford all of them.
    if chosen is not None:
        card.add_field(
            name=(f"{chosen['slot_emoji']} {chosen['name']}"
                  + (" (worn)" if chosen["worn"] else ""))[:256],
            value=(
                f"{RARITY_MARK.get(chosen['rarity'], '')} "
                f"**{chosen['rarity'].title()}** {DOT} "
                f"{chosen['quality_name']} {DOT} "
                f"{STAR * int(chosen['rank'])} {DOT} "
                f"level {chosen['level']} {DOT} tier {chosen['tier']}"
                + (f" {DOT} {chosen['reaction']}" if chosen["reaction"] else "")
                + "\n\n" + (chosen["effect_text"] or "nothing")
            )[:1024],
            inline=False,
        )

    if totals:
        card.add_field(
            name="Worn, in total",
            value="\n".join(
                f"{t['emoji']} "
                f"**{effect_amount(t['total'], is_base=t['is_base'])}** "
                f"{t['name']}"
                + ("  \N{BULLET} *at the ceiling*" if t["capped"] else "")
                for t in totals
            ),
            inline=False,
        )
    if empty:
        card.add_field(
            name="Bare",
            value=" \N{BULLET} ".join(f"{e['emoji']} {e['name']}" for e in empty),
            inline=False,
        )

    picked = [r for r in rows if slot is None or r["slot"] == slot]
    key = next(k for code, _label, k in GEAR_SORTS if code == sort)
    # Worn first whatever the sort: it is the thing every other piece is being
    # compared against.
    picked.sort(key=lambda r: (not r["worn"],) + key(r))

    if not picked:
        card.add_field(
            name="Nothing here",
            value="No pieces in that slot yet. **/forge** makes one.",
            inline=False,
        )
        return card

    heading = picked[0]["slot_name"] if slot else "Everything"
    label = next(lbl for code, lbl, _k in GEAR_SORTS if code == sort)

    # A select holds PER_PAGE options and no more, so the card draws the same
    # page the select is offering. Drawing every piece instead is how a rack of
    # seventy-nine listed all seventy-nine and handed over a menu of twenty-
    # five, with nothing on the screen to say which twenty-five - the pieces
    # were not missing, they were on a page nobody was told about.
    #
    # What is worn is drawn on every page: it is the thing the rest are being
    # compared against, and it is reachable through the take-off select rather
    # than this one.
    worn_here = [r for r in picked if r["worn"]]
    spare = [r for r in picked if not r["worn"]]
    shown = worn_here + page_of(spare, page)

    blocks = chunk_lines([
        gear_line(r, TICK + " " if r["worn"] else "\N{IDEOGRAPHIC SPACE}")
        for r in shown
    ])
    for index, block in enumerate(blocks):
        card.add_field(
            name=f"{heading} ({len(picked)}) \N{BULLET} by {label}"
            if index == 0 else "\N{HORIZONTAL ELLIPSIS}",
            value=block,
            inline=False,
        )

    told = page_note(spare, page, "spare")
    card.set_footer(
        text=(f"{told} \N{BULLET} " if told else "")
        + f"{TICK} worn \N{BULLET} the two strongest affixes are shown "
        "\N{BULLET} /forge shows a piece in full"
    )
    return card


class GearSelect(discord.ui.Select):
    def __init__(self, screen: "RackView", rows: list[dict]) -> None:
        self.screen = screen
        super().__init__(
            placeholder="Look at one…",
            row=2,
            options=[
                discord.SelectOption(
                    label=f"{r['name']}"[:100],
                    value=str(r["equipment_id"]),
                    description=(
                        ("worn " + DOT + " " if r["worn"] else "")
                        + f"{r['rarity'].title()} {STAR * int(r['rank'])} "
                        + f"L{r['level']} T{r['tier']} {r['slot_name']}"
                    )[:100],
                    emoji=r["slot_emoji"][:1] if r["slot_emoji"] else None,
                )
                for r in rows
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        # Shows rather than wears. Choosing a piece used to equip it on the
        # spot, so the only way to read what a piece actually gave was to put
        # it on - and the rack itself only ever printed two of its stats.
        self.screen.chosen = next(
            (r for r in self.screen.rows
             if r["equipment_id"] == int(self.values[0])), None)
        self.screen.build()
        await interaction.response.edit_message(
            embed=await render_gear(
                self.screen.player_id, self.screen.rows,
                self.screen.display_name,
                page=self.screen.page, slot=self.screen.slot,
                sort=self.screen.sort, chosen=self.screen.chosen,
            ),
            view=self.screen,
        )


class WearButton(discord.ui.Button):
    """The other half of looking at one."""

    def __init__(self, screen: "RackView", row: dict) -> None:
        self.screen = screen
        self.piece = row
        super().__init__(
            label=f"Wear {row['name']}"[:80],
            emoji=row["slot_emoji"][:1] if row["slot_emoji"] else None,
            style=discord.ButtonStyle.success,
            row=4,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        try:
            done = await db.fetch_one(
                "SELECT * FROM equip(%s, %s)",
                (self.screen.player_id, self.piece["equipment_id"]),
            )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0].capitalize()) from exc

        self.screen.rows = await fetch_gear(self.screen.player_id)
        self.screen.chosen = next(
            (r for r in self.screen.rows
             if r["equipment_id"] == self.piece["equipment_id"]), None)
        self.screen.build()
        card = await render_gear(
            self.screen.player_id, self.screen.rows, self.screen.display_name,
            page=self.screen.page, slot=self.screen.slot,
            sort=self.screen.sort, chosen=self.screen.chosen,
        )
        card.description = (
            f"**{done['item_name']}** is on"
            + (f", replacing {done['replaced']}." if done["replaced"] else ".")
            + "\n\nWhat a piece gives is added to the same stack a Gu "
            "and a manual feed, never multiplied into it."
        )
        await interaction.response.edit_message(embed=card, view=self.screen)


class TakeOffSelect(discord.ui.Select):
    def __init__(self, screen: "RackView", rows: list[dict]) -> None:
        self.screen = screen
        super().__init__(
            placeholder="Take one off…",
            row=3,
            options=[
                discord.SelectOption(
                    label=f"{r['slot_name']}: {r['name']}"[:100],
                    value=r["slot"],
                    emoji=r["slot_emoji"][:1] if r["slot_emoji"] else None,
                )
                for r in rows
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        try:
            was = await db.fetch_value(
                "SELECT unequip(%s, %s)", (self.screen.player_id, self.values[0])
            )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0].capitalize()) from exc

        self.screen.rows = await fetch_gear(self.screen.player_id)
        self.screen.build()
        card = await render_gear(
            self.screen.player_id, self.screen.rows, self.screen.display_name
        )
        card.description = f"**{was}** is off.\n\n" + card.description
        await interaction.response.edit_message(embed=card, view=self.screen)


class SlotButton(discord.ui.Button):
    """One slot, or all of them. Four slots and an All fit one row exactly."""

    def __init__(self, screen: "RackView", code: str | None, label: str,
                 emoji: str | None, held: int) -> None:
        self.screen = screen
        self.code = code
        super().__init__(
            label=f"{label} ({held})",
            emoji=emoji,
            row=0,
            style=(
                discord.ButtonStyle.primary
                if screen.slot == code
                else discord.ButtonStyle.secondary
            ),
            disabled=held == 0,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        self.screen.slot = self.code
        await self.screen.redraw(interaction)


class SortSelect(discord.ui.Select):
    """A rack is read to answer "which of these is better", and the answer
    depends on what better means today - the most total effect, the highest
    grade, the cleanest forging."""

    def __init__(self, screen: "RackView") -> None:
        self.screen = screen
        super().__init__(
            placeholder="Sort by\N{HORIZONTAL ELLIPSIS}",
            row=1,
            options=[
                discord.SelectOption(
                    label=label, value=code, default=code == screen.sort
                )
                for code, label, _key in GEAR_SORTS
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        self.screen.sort = self.values[0]
        await self.screen.redraw(interaction)


class RackView(AnsweringView):
    """Everything forged, narrowed to one slot at a time.

    The old rack drew eight pieces as eight full-width fields - fifty-nine
    lines for eight of luckymate0_0's twenty - and then offered all twenty in
    the select underneath, so the footer had to admit "12 more on this page,
    in the list below". A player could equip a piece the screen had never
    shown them.

    A rack is read to compare pieces of ONE slot, so the slot is the filter
    and every piece of it is drawn, one line each. What the select offers is
    exactly what the card lists.
    """

    def __init__(
        self, player_id: int, user: discord.abc.User, rows: list[dict], display_name: str
    ) -> None:
        super().__init__(timeout=300)
        self.player_id = player_id
        self.user = user
        self.rows = rows
        self.display_name = display_name
        self.page = 0
        self.slot: str | None = None
        self.sort = "best"
        self.chosen: dict | None = None
        self.build()

    def matching(self) -> list[dict]:
        """What the card shows, in the order it shows it - and therefore what
        the select must offer."""
        key = next(k for code, _l, k in GEAR_SORTS if code == self.sort)
        picked = [
            r for r in self.rows if self.slot is None or r["slot"] == self.slot
        ]
        picked.sort(key=lambda r: (not r["worn"],) + key(r))
        return picked

    def page_count(self) -> int:
        return page_count([r for r in self.matching() if not r["worn"]])

    async def card(self) -> discord.Embed:
        return await render_gear(
            self.player_id, self.rows, self.display_name,
            page=self.page, slot=self.slot, sort=self.sort,
            chosen=self.chosen,
        )

    async def redraw(self, interaction: discord.Interaction) -> None:
        self.page = 0
        # A piece from the slot you were just looking at is not on the shelf
        # you have switched to, and leaving it drawn above a rack that does
        # not contain it reads as a bug.
        if self.chosen is not None and self.slot is not None                 and self.chosen["slot"] != self.slot:
            self.chosen = None
        self.build()
        await interaction.response.edit_message(embed=await self.card(), view=self)

    def build(self) -> None:
        self.clear_items()

        held = {}
        for row in self.rows:
            held[row["slot"]] = held.get(row["slot"], 0) + 1
        self.add_item(SlotButton(self, None, "All", "\N{PACKAGE}", len(self.rows)))
        for code, label, glyph in SLOT_BUTTONS:
            self.add_item(SlotButton(self, code, label, glyph, held.get(code, 0)))

        self.add_item(SortSelect(self))

        spare = [r for r in self.matching() if not r["worn"]]
        if spare:
            self.add_item(GearSelect(self, page_of(spare, self.page)))
        # Taking off is offered for whatever is worn in the slot being looked
        # at, so the two selects always talk about the same shelf.
        worn = [
            r for r in self.matching() if r["worn"]
        ]
        if worn:
            self.add_item(TakeOffSelect(self, worn))
        # Row 4 with the pager: every other row is spoken for, and a piece you
        # are looking at is the one you might put on.
        if self.chosen is not None and not self.chosen["worn"]:
            self.add_item(WearButton(self, self.chosen))
        add_page_buttons(self, row=4)

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message("Not your rack.", ephemeral=True)
            return False
        return True

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True


class Forge(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @app_commands.command(description="Forge ore and beast materials into equipment.")
    async def forge(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])

        skill = await fetch_skill(player["player_id"])
        slots = await db.fetch_all(
            "SELECT code, name, emoji, description FROM equipment_slots ORDER BY sort_order"
        )
        view = AnvilView(player["player_id"], interaction.user, skill, slots, slots[0])
        await interaction.response.send_message(
            embed=await render_anvil(skill, view.slot, {}, {}), view=view
        )
        view.message = await interaction.original_response()

    @app_commands.command(description="What you have forged, and what you are wearing.")
    async def gear(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])

        rows = await fetch_gear(player["player_id"])
        if not rows:
            raise GameError("You have forged nothing. **/forge**.")

        await interaction.response.send_message(
            embed=await render_gear(
                player["player_id"], rows, interaction.user.display_name
            ),
            view=RackView(
                player["player_id"], interaction.user, rows, interaction.user.display_name
            ),
        )


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Forge(bot))
