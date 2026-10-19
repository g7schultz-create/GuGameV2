"""The furnace: /smelt.

A forging takes ore AND a beast material, so beast materials are what a smith
actually runs out of - one cultivator here holds 28,227 ore against 199 parts.
Nearly eleven thousand of those rocks are tier 1, and the ore is the ceiling
on the piece, so a tier 1 ingot makes a tier 1 item forever. That is a
material the game hands out by the hundred and gave no way to spend.

So this is the furnace rather than the anvil: ore melted down for the practice
of melting it, no beast material and no piece at the end. It is deliberately
much worse per rock than forging - an efficient tier 1 forging is 15 EXP a
potency and this is 0.25 - because it is not competing with forging. It is
what you do with the ore you were never going to forge.

By the tier rather than by the rock, because the whole complaint is that there
are twenty-eight thousand of them and picking is not the problem. That is also
what made 0168 necessary: Spirit Stone is a tier 1 ore as well as the money,
which the anvil could afford to ignore because it takes one ore at a time and
asks how much. A "Melt all" button cannot.

Nothing here computes a game number: `smelt_many` decides what a cartload is
worth, and refuses the same things this screen declines to offer.
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
from bot.players import GameError, require_player
from bot.views import AnsweringView

ORE = "\N{PICK}"
FURNACE = "\N{FIRE}"

# Five to a row, and a smith who can work every tier has seven of them.
TIERS_PER_ROW = 5


def refuse(exc: psycopg.errors.CheckViolation) -> GameError:
    said = str(exc).splitlines()[0]
    return GameError(said[:1].upper() + said[1:])


async def fetch_furnace(player_id: int) -> dict:
    """Everything the screen needs, out of the same tables the function reads.

    `smith_tier_cap` is asked for rather than restated: it is the gate the
    furnace enforces and the reason the low tiers are the ones a new smith can
    melt at all.
    """
    skill = await db.fetch_one(
        """
        SELECT profession_level(%s, 'blacksmithing') AS level,
               smith_tier_cap(profession_level(%s, 'blacksmithing')) AS tier_cap,
               COALESCE((SELECT pp.exp FROM player_professions pp
                         WHERE pp.player_id = %s
                           AND pp.profession = 'blacksmithing'), 0) AS exp,
               game_config_value('smelt_exp_per_potency') AS rate
        """,
        (player_id, player_id, player_id),
    )
    ore = await db.fetch_all(
        """
        SELECT o.tier, m.code, m.name, m.emoji, pm.quantity,
               o.tier::numeric ^ 2 * pm.quantity AS potency
        FROM player_materials pm
        JOIN ores o ON o.material_code = pm.material_code
        JOIN materials m ON m.code = pm.material_code
        WHERE pm.player_id = %s AND pm.quantity > 0
          -- Spirit Stone is a tier 1 ore AND the currency, so a furnace that
          -- melts by the cartload has to leave it out of the cart. 0168.
          AND NOT EXISTS (SELECT 1 FROM currency_materials cm
                          WHERE cm.material_code = pm.material_code)
        ORDER BY o.tier, m.name
        """,
        (player_id,),
    )
    return {"skill": skill, "ore": ore}


def by_tier(ore: list[dict], cap: int) -> list[dict]:
    """One row a tier, meltable ones first and the rest still shown.

    Ore above the cap is listed rather than hidden: "you are holding 321 rocks
    you cannot work yet" is the reason to keep levelling, and a screen that
    drops them silently is a screen that says they do not exist.
    """
    tiers: dict[int, dict] = {}
    for row in ore:
        seat = tiers.setdefault(
            row["tier"],
            {"tier": row["tier"], "kinds": 0, "quantity": 0, "potency": 0},
        )
        seat["kinds"] += 1
        seat["quantity"] += row["quantity"]
        seat["potency"] += float(row["potency"])
    for seat in tiers.values():
        seat["meltable"] = seat["tier"] <= cap
    return [tiers[t] for t in sorted(tiers)]


def worth(potency: float, rate: float) -> int:
    """What the furnace will pay, drawn the way the function computes it."""
    return max(1, round(potency * rate))


def render(state: dict) -> discord.Embed:
    skill = state["skill"]
    cap = skill["tier_cap"]
    rate = float(skill["rate"])
    rows = by_tier(state["ore"], cap)

    card = embed(
        f"{FURNACE} The furnace",
        "Ore melted down for the practice of it \N{EM DASH} no beast material "
        "and no piece at the end. Worth far less a rock than forging, and the "
        "only thing there is to do with ore you will never forge.",
        colour=COLOUR_INFO,
    )
    card.add_field(
        name="Blacksmith",
        value=f"Level **{skill['level']}** ({thousands(skill['exp'])} EXP) "
        f"\N{BULLET} the furnace reaches **tier {cap}**",
        inline=False,
    )

    can = [r for r in rows if r["meltable"]]
    cannot = [r for r in rows if not r["meltable"]]

    if can:
        card.add_field(
            name="What you can melt",
            value="\n".join(
                f"`T{r['tier']}` **{thousands(r['quantity'])}** ore "
                f"({r['kinds']} kind(s)) \N{EM DASH} "
                f"**{thousands(worth(r['potency'], rate))}** EXP"
                for r in can
            )
            + f"\n\n**All of it:** {thousands(sum(r['quantity'] for r in can))} "
            f"ore \N{EM DASH} "
            f"**{thousands(worth(sum(r['potency'] for r in can), rate))}** EXP",
            inline=False,
        )
    else:
        card.add_field(
            name="Nothing to melt",
            value="No ore at or below tier "
            f"{cap}. **/mine** turns some up.",
            inline=False,
        )

    if cannot:
        card.add_field(
            name="Too hot to work yet",
            value="\n".join(
                f"`T{r['tier']}` {thousands(r['quantity'])} ore"
                for r in cannot
            )
            + "\n*Raise your Blacksmith level and the furnace reaches them.*",
            inline=False,
        )

    card.set_footer(
        text="A tier 6 rock is worth thirty-six tier 1 ones, here and on the "
        "anvil alike. Melting is not undoable."
    )
    return card


def confirm_card(quantity: int, exp: int, what: str) -> discord.Embed:
    return embed(
        f"{FURNACE} Melt {what}?",
        f"**{thousands(quantity)}** ore into the furnace for "
        f"**{thousands(exp)}** Blacksmith EXP.\n\n"
        "*The ore is gone afterwards. There is no piece at the end of this.*",
        colour=COLOUR_BAD,
    )


def done_card(got: dict) -> discord.Embed:
    card = embed(
        f"{FURNACE} {thousands(got['melted'])} ore, melted",
        f"**+{thousands(got['exp_gained'])}** Blacksmith EXP "
        f"\N{EM DASH} level **{got['level_after']}**"
        + (f" *(was {got['level_before']})*"
           if got["level_after"] != got["level_before"] else ""),
        colour=COLOUR_GOOD,
    )
    if got["tier_cap_after"] > got["tier_cap_before"]:
        card.add_field(
            name="The furnace reaches further",
            value=f"Tier **{got['tier_cap_before']}** \N{RIGHTWARDS ARROW} "
            f"**{got['tier_cap_after']}**. Ore that was too hot to work is "
            "on the anvil now, and in the furnace.",
            inline=False,
        )
    card.set_footer(text=f"{thousands(got['kinds'])} kind(s) went in.")
    return card


class Confirm(AnsweringView):
    """Melting is not undoable, and the whole point is doing it by the
    cartload - so the number is put in front of somebody before it happens."""

    def __init__(
        self,
        screen: "FurnaceView",
        codes: list[str],
        quantities: list[int],
        quantity: int,
        exp: int,
    ) -> None:
        super().__init__(timeout=180)
        self.screen = screen
        self.codes = codes
        self.quantities = quantities
        self.quantity = quantity
        self.exp = exp

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.screen.user.id:
            await interaction.response.send_message(
                "That is not your furnace.", ephemeral=True
            )
            return False
        return True

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True

    @discord.ui.button(label="Melt it", style=discord.ButtonStyle.danger)
    async def go(self, interaction: discord.Interaction, button) -> None:
        try:
            got = await db.fetch_one(
                "SELECT * FROM smelt_many(%s, %s, %s)",
                (self.screen.player_id, self.codes, self.quantities),
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        for item in self.children:
            item.disabled = True
        self.stop()
        await interaction.response.edit_message(embed=done_card(got), view=self)

    @discord.ui.button(label="Back off", style=discord.ButtonStyle.secondary)
    async def stop_it(self, interaction: discord.Interaction, button) -> None:
        for item in self.children:
            item.disabled = True
        self.stop()
        await interaction.response.edit_message(
            embed=embed(
                "Left in the cart",
                "The ore is where you left it. **/smelt** when you want it gone.",
                colour=COLOUR_DEFAULT,
            ),
            view=self,
        )


class TierButton(discord.ui.Button):
    def __init__(self, screen: "FurnaceView", row: dict, rate: float, seat: int) -> None:
        self.screen = screen
        self.tier = row["tier"]
        super().__init__(
            label=f"T{row['tier']} \N{BULLET} {thousands(row['quantity'])} "
            f"\N{RIGHTWARDS ARROW} {thousands(worth(row['potency'], rate))} EXP"[:80],
            row=seat // TIERS_PER_ROW,
            style=discord.ButtonStyle.secondary,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        await self.screen.ask(interaction, tier=self.tier)


class MeltAll(discord.ui.Button):
    def __init__(self, screen: "FurnaceView", quantity: int, exp: int, seat: int) -> None:
        self.screen = screen
        super().__init__(
            label=f"Melt all \N{BULLET} {thousands(quantity)} ore"[:80],
            emoji="\N{FIRE}",
            row=seat,
            style=discord.ButtonStyle.danger,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        await self.screen.ask(interaction, tier=None)


class FurnaceView(AnsweringView):
    def __init__(self, player_id: int, user: discord.abc.User, state: dict) -> None:
        super().__init__(timeout=300)
        self.player_id = player_id
        self.user = user
        self.state = state
        self.build()

    @property
    def cap(self) -> int:
        return self.state["skill"]["tier_cap"]

    @property
    def rate(self) -> float:
        return float(self.state["skill"]["rate"])

    def meltable(self, tier: int | None = None) -> list[dict]:
        """The ore rows a press is about: one tier, or everything workable."""
        return [
            row for row in self.state["ore"]
            if row["tier"] <= self.cap and (tier is None or row["tier"] == tier)
        ]

    def build(self) -> None:
        self.clear_items()
        rows = [r for r in by_tier(self.state["ore"], self.cap) if r["meltable"]]
        for seat, row in enumerate(rows):
            self.add_item(TierButton(self, row, self.rate, seat))
        if len(rows) > 1:
            self.add_item(MeltAll(
                self,
                sum(r["quantity"] for r in rows),
                worth(sum(r["potency"] for r in rows), self.rate),
                seat=min(4, (len(rows) - 1) // TIERS_PER_ROW + 1),
            ))

    async def ask(self, interaction: discord.Interaction, *, tier: int | None) -> None:
        picked = self.meltable(tier)
        if not picked:
            raise GameError("There is no ore of that tier left to melt.")

        quantity = sum(r["quantity"] for r in picked)
        exp = worth(sum(float(r["potency"]) for r in picked), self.rate)
        what = f"every tier {tier} rock" if tier is not None else "all of it"

        await interaction.response.edit_message(
            embed=confirm_card(quantity, exp, what),
            view=Confirm(
                self,
                [r["code"] for r in picked],
                [r["quantity"] for r in picked],
                quantity,
                exp,
            ),
        )

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "That is not your furnace.", ephemeral=True
            )
            return False
        return True

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True


class Smelt(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @app_commands.command(
        description="Melt ore down for Blacksmith EXP, by the cartload."
    )
    async def smelt(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        state = await fetch_furnace(player["player_id"])

        if not state["ore"]:
            raise GameError(
                "You are holding no ore at all. **/mine** turns some up."
            )

        view = FurnaceView(player["player_id"], interaction.user, state)
        await interaction.response.send_message(
            embed=render(state),
            view=view if view.children else discord.utils.MISSING,
        )


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Smelt(bot))
