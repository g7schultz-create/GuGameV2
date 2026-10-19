"""The Broker: /broker.

He buys and he never sells. That is the whole of him, and it is what makes
him a floor rather than a market: the auction house is where you go when your
Gu is worth something to a person, and the Broker is where you go when it is
worth something to nobody.

Every price comes from `broker_offer`, which reads the same tier tables the
forge and the refinery are defined by - so retuning a tier retunes the till and
this file never learns a number.

The bulk buttons deliberately cover only the cheap bands. "Sell every common"
is a thing a player means; "sell everything" is a thing a player regrets, and
a button that empties a crafting stock in one press is a trap however clearly
it is labelled.
"""

import discord
import psycopg
from discord import app_commands
from discord.ext import commands

from bot import database as db
from bot.formatting import (
    COLOUR_DEFAULT,
    COLOUR_GOOD,
    COLOUR_INFO,
    embed,
    thousands,
)
from bot.picking import add_page_buttons, page_count, page_note, page_of
from bot.players import GameError, require_player, settle_passive
from bot.views import AnsweringView

STONE = "\N{GEM STONE}"

# The bands a button may empty. Common and uncommon are what a bag fills with
# and what nobody misses; anything rarer is sold one stack at a time, on
# purpose.
BULK_RARITIES = ("common", "uncommon")

KIND_LABELS = {
    "material": "Resources",
    "equipment": "Gear",
    "manual": "Manuals",
}


async def fetch_counter(player_id: int) -> list[dict]:
    return await db.fetch_all(
        """
        SELECT o.*, m.rarity
        FROM broker_offer(%s) o
        LEFT JOIN materials m ON m.code = o.ref AND o.kind = 'material'
        """,
        (player_id,),
    )


def render_counter(rows: list[dict], page: int, held: int) -> discord.Embed:
    card = embed(
        "\N{MONEY BAG} The Broker",
        "*\"I buy. I do not sell, I do not haggle, and I do not ask where it "
        "came from. What you are carrying is worth something to nobody - so it "
        "is worth this to me.\"*",
        colour=COLOUR_INFO if rows else COLOUR_DEFAULT,
    )
    card.add_field(
        name="Your purse",
        value=f"{STONE} **{thousands(held)}** spirit stones",
        inline=False,
    )

    if not rows:
        card.add_field(
            name="Nothing on the counter",
            value="Everything you carry is either equipped or is money. "
            "**/gather**, **/mine** and **/hunt** fill a bag soon enough.",
            inline=False,
        )
        return card

    for kind, label in KIND_LABELS.items():
        mine = [r for r in rows if r["kind"] == kind]
        if not mine:
            continue
        card.add_field(
            name=f"{label} \N{BULLET} {STONE} {thousands(sum(r['total'] for r in mine))}",
            value="\n".join(
                f"{r['emoji']} **{r['label']}**"
                + (f" \N{MULTIPLICATION SIGN}{thousands(r['quantity'])}"
                   if r["quantity"] > 1 else "")
                + f" \N{BULLET} {STONE} {thousands(r['total'])}"
                for r in mine[:6]
            )
            + (f"\n*\N{HORIZONTAL ELLIPSIS} and {len(mine) - 6} more*"
               if len(mine) > 6 else ""),
            inline=False,
        )

    note = page_note(rows, page, "entries")
    card.set_footer(
        text=(note + " \N{BULLET} " if note else "")
        + "He will not take what you are wearing or reading."
    )
    return card


class CounterSelect(discord.ui.Select):
    def __init__(self, screen: "BrokerView", rows: list[dict]) -> None:
        self.screen = screen
        super().__init__(
            placeholder="Sell particular things\N{HORIZONTAL ELLIPSIS}",
            row=0,
            min_values=1,
            max_values=len(rows),
            options=[
                discord.SelectOption(
                    label=(
                        f"{r['label']}"
                        + (f" \N{MULTIPLICATION SIGN}{r['quantity']}"
                           if r["quantity"] > 1 else "")
                    )[:100],
                    value=f"{r['kind']}:{r['ref']}",
                    emoji=r["emoji"][:1] if r["emoji"] else None,
                    description=f"{r['detail']} \N{BULLET} {r['total']} stones"[:100],
                )
                for r in rows
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        chosen = [v.split(":", 1) for v in self.values]
        await self.screen.confirm(interaction, chosen)


class BandButton(discord.ui.Button):
    """A whole rarity band of resources in one press."""

    def __init__(self, screen: "BrokerView", rarity: str, rows: list[dict]) -> None:
        self.screen = screen
        self.rarity = rarity
        self.rows = rows
        super().__init__(
            label=f"All {rarity} \N{BULLET} {sum(r['total'] for r in rows)} stones"[:80],
            row=1,
            style=discord.ButtonStyle.secondary,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        await self.screen.confirm(
            interaction, [["material", r["ref"]] for r in self.rows]
        )


class BrokerView(AnsweringView):
    def __init__(
        self, player_id: int, user: discord.abc.User, rows: list[dict], held: int
    ) -> None:
        super().__init__(timeout=300)
        self.player_id = player_id
        self.user = user
        self.rows = rows
        self.held = held
        self.page = 0
        self.build()

    def page_count(self) -> int:
        return page_count(self.rows)

    def card(self) -> discord.Embed:
        return render_counter(self.rows, self.page, self.held)

    def build(self) -> None:
        self.clear_items()
        shown = page_of(self.rows, self.page)
        if shown:
            self.add_item(CounterSelect(self, shown))
        for rarity in BULK_RARITIES:
            band = [
                r for r in self.rows
                if r["kind"] == "material" and r["rarity"] == rarity
            ]
            if band:
                self.add_item(BandButton(self, rarity, band))
        add_page_buttons(self, row=2)

    async def confirm(
        self, interaction: discord.Interaction, chosen: list[list[str]]
    ) -> None:
        picked = [
            r for r in self.rows
            if any(k == r["kind"] and ref == r["ref"] for k, ref in chosen)
        ]
        paid = sum(r["total"] for r in picked)

        card = embed(
            f"\N{MONEY BAG} Sell {len(picked)} thing(s)?",
            f"The Broker offers {STONE} **{thousands(paid)}** spirit stones. "
            "What he takes does not come back.",
            colour=COLOUR_DEFAULT,
        )
        card.add_field(
            name="Across the counter",
            value="\n".join(
                f"{r['emoji']} **{r['label']}**"
                + (f" \N{MULTIPLICATION SIGN}{thousands(r['quantity'])}"
                   if r["quantity"] > 1 else "")
                + f" \N{BULLET} {STONE} {thousands(r['total'])}"
                for r in picked[:12]
            )
            + (f"\n*\N{HORIZONTAL ELLIPSIS} and {len(picked) - 12} more*"
               if len(picked) > 12 else ""),
            inline=False,
        )
        await interaction.response.send_message(
            embed=card,
            view=SaleConfirm(self.player_id, self.user, picked),
            ephemeral=True,
        )

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "Wait your turn.", ephemeral=True
            )
            return False
        return True

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True


class SaleConfirm(AnsweringView):
    def __init__(
        self, player_id: int, user: discord.abc.User, picked: list[dict]
    ) -> None:
        super().__init__(timeout=180)
        self.player_id = player_id
        self.user = user
        self.picked = picked

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        return interaction.user.id == self.user.id

    @discord.ui.button(label="Sell", style=discord.ButtonStyle.success)
    async def go(self, interaction: discord.Interaction, button) -> None:
        paid = 0
        sold = 0
        # One call per kind: `sell_to_broker` takes a homogeneous counter,
        # because a material is sold by the stack and a sabre is sold by the
        # one, and pretending otherwise would put a quantity on a sword.
        for kind in KIND_LABELS:
            mine = [r for r in self.picked if r["kind"] == kind]
            if not mine:
                continue
            try:
                done = await db.fetch_one(
                    "SELECT * FROM sell_to_broker(%s, %s, %s, %s)",
                    (
                        self.player_id,
                        kind,
                        [r["ref"] for r in mine],
                        [r["quantity"] for r in mine],
                    ),
                )
            except psycopg.errors.CheckViolation as exc:
                raise GameError(str(exc).splitlines()[0].capitalize()) from exc
            paid += done["stones_paid"]
            sold += done["sold"]

        held = await db.fetch_value(
            "SELECT COALESCE((SELECT quantity FROM player_materials "
            "WHERE player_id = %s AND material_code = 'spirit_stone'), 0)",
            (self.player_id,),
        )

        card = embed(
            f"{STONE} +{thousands(paid)} spirit stones",
            f"The Broker takes **{sold}** thing(s) and counts out the stones "
            "without looking up.",
            colour=COLOUR_GOOD,
        )
        card.add_field(
            name="Your purse",
            value=f"{STONE} **{thousands(held)}**",
            inline=False,
        )
        card.set_footer(
            text="Spirit stones raise a dwelling — /dwelling — and buy what "
            "stands in it."
        )

        for item in self.children:
            item.disabled = True
        await interaction.response.edit_message(embed=card, view=self)
        self.stop()

    @discord.ui.button(label="Keep them", style=discord.ButtonStyle.secondary)
    async def keep(self, interaction: discord.Interaction, button) -> None:
        for item in self.children:
            item.disabled = True
        await interaction.response.edit_message(
            embed=embed("Kept", "The counter is cleared.", colour=COLOUR_INFO),
            view=self,
        )
        self.stop()


class Broker(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @app_commands.command(
        description="Sell resources, gear and manuals for spirit stones."
    )
    async def broker(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])

        rows = await fetch_counter(player["player_id"])
        held = await db.fetch_value(
            "SELECT COALESCE((SELECT quantity FROM player_materials "
            "WHERE player_id = %s AND material_code = 'spirit_stone'), 0)",
            (player["player_id"],),
        )

        view = BrokerView(player["player_id"], interaction.user, rows, held)
        await interaction.response.send_message(
            embed=view.card(),
            view=view if view.children else discord.utils.MISSING,
        )


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Broker(bot))
