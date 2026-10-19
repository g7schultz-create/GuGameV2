"""Trading: /trade.

One message, two players. Both sides press the same buttons; which pile a
press lands on is decided by who pressed it, not by which button.

The screen is deliberately thin. Ownership, the confirmation reset and the
swap itself are all in SQL, because a trade is the one place in this game
where a bug hands one player another player's property - and a rule enforced
in a command handler is a rule that holds only for the paths that go through
that handler. An equipped Gu leaving the aperture when it changes hands is the
same argument: that rule lives on `player_gu`, not in the swap.
"""

from typing import Callable

import discord
import psycopg
from discord import app_commands
from discord.ext import commands

from bot import database as db
from bot.formatting import COLOUR_DEFAULT, COLOUR_GOOD, COLOUR_INFO, embed, thousands
from bot.picking import (
    PagedPicker,
    add_page_buttons,
    page_count,
    page_of,
)
from bot.views import AnsweringModal, AnsweringView
from bot.players import GameError, fetch_player, require_player

KIND_ICONS = {
    "manual": "\N{GRADUATION CAP}",
    "page": "\N{PAGE FACING UP}",
    "material": "\N{HERB}",
    "gu": "\N{BUG}",
}

STARS = "\N{BLACK STAR}"


async def fetch_trade(trade_id: int) -> dict | None:
    return await db.fetch_one(
        """
        SELECT t.*, a.discord_name AS proposer_name, b.discord_name AS partner_name
        FROM trades t
        JOIN players a ON a.player_id = t.proposer_id
        JOIN players b ON b.player_id = t.partner_id
        WHERE t.trade_id = %s
        """,
        (trade_id,),
    )


async def fetch_contents(trade_id: int) -> list[dict]:
    return await db.fetch_all(
        "SELECT side, kind, quantity, label FROM trade_contents "
        "WHERE trade_id = %s ORDER BY side, kind, label",
        (trade_id,),
    )


def label_of(row: dict) -> str:
    """One line of a pile.

    `trade_contents` writes a Gu's grade as a count rather than as stars, so
    the view stays ASCII. Every other Gu screen draws them, and a build that
    reads five stars in /gu must not read `5*` here.
    """
    if row["kind"] == "gu":
        count, _, name = row["label"].partition("* ")
        return f"{name} {STARS * int(count)}"
    if row["kind"] == "material":
        return f"{row['label']} \N{MULTIPLICATION SIGN}{thousands(row['quantity'])}"
    return row["label"]


def pile(contents: list[dict], side: int) -> str:
    lines = [
        f"{KIND_ICONS.get(row['kind'], '')} {label_of(row)}"
        for row in contents
        if row["side"] == side
    ]
    return "\n".join(lines) or "*nothing yet*"


async def render_trade(trade: dict, contents: list[dict]) -> discord.Embed:
    done = trade["status"] == "complete"
    card = embed(
        f"\N{HANDSHAKE} {trade['proposer_name']} \N{LEFT RIGHT ARROW} {trade['partner_name']}",
        "The swap is done." if done else
        "Offer what you like. **Changing your pile clears both confirmations** — "
        "nobody can agree to one deal and hand over another.",
        colour=COLOUR_GOOD if done else COLOUR_DEFAULT,
    )

    for side, name, confirmed in (
        (0, trade["proposer_name"], trade["proposer_confirmed_at"]),
        (1, trade["partner_name"], trade["partner_confirmed_at"]),
    ):
        mark = "\N{WHITE HEAVY CHECK MARK}" if confirmed else "\N{WHITE MEDIUM SQUARE}"
        card.add_field(
            name=f"{mark} {name} offers",
            value=pile(contents, side),
            inline=True,
        )

    if done:
        card.set_footer(text="Everything above changed hands.")
    else:
        card.set_footer(
            text="Trades left open for 30 minutes are dropped. /trade again to restart one."
        )
    return card


# ---------------------------------------------------------------------------
# Pickers. Each opens ephemerally, so a player only ever sees their own things.
# ---------------------------------------------------------------------------


class ManualPicker(discord.ui.Select):
    def __init__(self, screen: "TradeView", player_id: int, rows: list[dict]) -> None:
        self.screen = screen
        self.player_id = player_id
        super().__init__(
            placeholder="Which manual?",
            options=[
                discord.SelectOption(
                    label=f"T{r['tier']} {r['name']}"[:100],
                    value=str(r["manual_id"]),
                    description=(f"{r['archetype']} · {r['paths'] or 'untyped'}")[:100],
                )
                for r in rows
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        await db.execute(
            "SELECT trade_add_manual(%s, %s, %s)",
            (self.screen.trade_id, self.player_id, int(self.values[0])),
        )
        await self.screen.refresh(interaction, "On the table.")


class PagePicker(discord.ui.Select):
    def __init__(self, screen: "TradeView", player_id: int, rows: list[dict]) -> None:
        self.screen = screen
        self.player_id = player_id
        super().__init__(
            placeholder="Which pages?",
            min_values=1,
            max_values=min(len(rows), 25),
            options=[
                discord.SelectOption(
                    label=f"T{r['tier']} {r['path_name']} {r['type_name']}"[:100],
                    value=str(r["page_id"]),
                    description=f"power {r['power']}, quality {r['quality']}%"[:100],
                )
                for r in rows
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        for value in self.values:
            await db.execute(
                "SELECT trade_add_page(%s, %s, %s)",
                (self.screen.trade_id, self.player_id, int(value)),
            )
        await self.screen.refresh(interaction, f"{len(self.values)} page(s) on the table.")


class QuantityModal(AnsweringModal, title="How many?"):
    amount = discord.ui.TextInput(label="Quantity", max_length=12, required=True)

    def __init__(self, screen: "TradeView", player_id: int, code: str, held: int) -> None:
        super().__init__()
        self.screen = screen
        self.player_id = player_id
        self.code = code
        self.amount.placeholder = f"You hold {held}. 0 takes it off the table."

    async def on_submit(self, interaction: discord.Interaction) -> None:
        try:
            wanted = int(str(self.amount).strip())
        except ValueError as exc:
            raise GameError("That is not a number.") from exc

        try:
            await db.execute(
                "SELECT trade_set_material(%s, %s, %s, %s)",
                (self.screen.trade_id, self.player_id, self.code, wanted),
            )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0].capitalize()) from exc

        await self.screen.refresh(interaction, "On the table.")


class MaterialPicker(discord.ui.Select):
    def __init__(self, screen: "TradeView", player_id: int, rows: list[dict]) -> None:
        self.screen = screen
        self.player_id = player_id
        self.held = {r["code"]: r["quantity"] for r in rows}
        super().__init__(
            placeholder="Which material?",
            options=[
                discord.SelectOption(
                    label=f"{r['name']} \N{MULTIPLICATION SIGN}{thousands(r['quantity'])}"[:100],
                    value=r["code"],
                    description=f"{r['category']} · {r['rarity']}"[:100],
                )
                for r in rows
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        code = self.values[0]
        await interaction.response.send_modal(
            QuantityModal(self.screen, self.player_id, code, self.held[code])
        )


class GuPicker(discord.ui.Select):
    def __init__(self, screen: "TradeView", player_id: int, rows: list[dict]) -> None:
        self.screen = screen
        self.player_id = player_id
        super().__init__(
            placeholder="Which Gu?",
            options=[
                discord.SelectOption(
                    label=f"{r['name']} {STARS * r['stars']}"[:100],
                    value=str(r["gu_id"]),
                    description=(
                        f"size {r['size']} \N{BULLET} {r['path_name']} "
                        f"\N{BULLET} harmony {r['harmony']}"
                        + (" \N{BULLET} in your aperture" if r["equipped"] else "")
                    )[:100],
                    emoji=r["emoji"][:1] if r["emoji"] else None,
                )
                for r in rows
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        await db.execute(
            "SELECT trade_add_gu(%s, %s, %s)",
            (self.screen.trade_id, self.player_id, int(self.values[0])),
        )
        await self.screen.refresh(interaction, "On the table.")


class EquipmentPicker(discord.ui.Select):
    """A forged piece, with what it actually grants.

    The stats are the whole reason to want somebody else's piece - two Tier 5
    gauntlets with the same name do different things - so they lead the
    description rather than the slot, which the emoji already says.
    """

    def __init__(self, screen: "TradeView", player_id: int, rows: list[dict]) -> None:
        self.screen = screen
        self.player_id = player_id
        super().__init__(
            placeholder="Which piece?",
            options=[
                discord.SelectOption(
                    label=f"T{r['tier']} {r['name']}"[:100],
                    value=str(r["equipment_id"]),
                    description=(
                        (r["grants"] or "no bonuses")
                        + (" \N{BULLET} worn" if r["worn"] else "")
                    )[:100],
                    emoji=r["emoji"][:1] if r["emoji"] else None,
                )
                for r in rows
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        await db.execute(
            "SELECT trade_add_equipment(%s, %s, %s)",
            (self.screen.trade_id, self.player_id, int(self.values[0])),
        )
        await self.screen.refresh(interaction, "On the table.")


class PillPicker(discord.ui.Select):
    """Which pill goes across.

    Whole stacks, because that is what the auction moves and what
    `trade_add_pill` accepts - so the count is on the label rather than
    something to choose. What distinguishes two pills of the same name is
    potency and harmony, so those lead the description.
    """

    def __init__(self, screen: "TradeView", player_id: int, rows: list[dict]) -> None:
        self.screen = screen
        self.player_id = player_id
        super().__init__(
            placeholder="Which pill?",
            options=[
                discord.SelectOption(
                    label=(f"T{r['tier']} {r['name']}"
                           + (f" x{r['quantity']}" if r["quantity"] > 1 else ""))[:100],
                    value=str(r["pill_id"]),
                    description=(
                        f"{r['kind_name']} \N{BULLET} {int(r['magnitude'])}"
                        f" \N{BULLET} {int(r['harmony'])}% harmony"
                    )[:100],
                    emoji=r["emoji"][:1] if r["emoji"] else None,
                )
                for r in rows
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        await db.execute(
            "SELECT trade_add_pill(%s, %s, %s)",
            (self.screen.trade_id, self.player_id, int(self.values[0])),
        )
        await self.screen.refresh(interaction, "On the table.")


class EggPicker(discord.ui.Select):
    """Which egg goes across.

    Deepest first, because a shelf of three hundred is mostly tier 3 and
    the one worth naming is at the top. What a trading partner wants to
    know is the tier, the shell and what is inside - the beast is the
    whole reason to want somebody else's egg.
    """

    def __init__(self, screen: "TradeView", player_id: int, rows: list[dict]) -> None:
        self.screen = screen
        self.player_id = player_id
        super().__init__(
            placeholder="Which egg?",
            options=[
                discord.SelectOption(
                    label=f"T{r['tier']} {r['name']}"[:100],
                    value=str(r["egg_id"]),
                    description=(
                        f"{r['rarity']} \N{BULLET} {r['beast']}"
                        + (f" \N{BULLET} {r['found_in_name']}"
                           if r["found_in_name"] else "")
                    )[:100],
                    emoji=r["emoji"][:1] if r["emoji"] else None,
                )
                for r in rows
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        await db.execute(
            "SELECT trade_add_egg(%s, %s, %s)",
            (self.screen.trade_id, self.player_id, int(self.values[0])),
        )
        await self.screen.refresh(interaction, "On the table.")


class ServantPicker(discord.ui.Select):
    def __init__(self, screen: "TradeView", player_id: int,
                 rows: list[dict]) -> None:
        self.screen = screen
        self.player_id = player_id
        super().__init__(
            placeholder="Which servant?",
            options=[
                discord.SelectOption(
                    label=f"{r['name']} {'*' * int(r['stars'])}"[:100],
                    value=str(r["player_servant_id"]),
                    description=(
                        f"T{r['tier']} {r['rarity']} \N{BULLET} {r['bonus_name']}"
                        f" \N{BULLET} {r['realm_name']}"
                    )[:100],
                )
                for r in rows
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        try:
            await db.execute(
                "SELECT trade_add_servant(%s, %s, %s)",
                (self.screen.trade_id, self.player_id, int(self.values[0])),
            )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0].capitalize()) from exc
        await self.screen.refresh(interaction, "On the table.")


class PickerView(PagedPicker):
    """The shared paged menu of your own things."""


# ---------------------------------------------------------------------------
# The shared screen
# ---------------------------------------------------------------------------


class TradeView(AnsweringView):
    def __init__(self, trade_id: int, proposer_id: int, partner_id: int,
                 users: dict[int, int]) -> None:
        super().__init__(timeout=1800)
        self.trade_id = trade_id
        self.sides = {users[proposer_id]: proposer_id, users[partner_id]: partner_id}
        self.message: discord.Message | None = None

    def player_of(self, interaction: discord.Interaction) -> int:
        return self.sides[interaction.user.id]

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id not in self.sides:
            await interaction.response.send_message(
                "This is not your trade.", ephemeral=True
            )
            return False
        return True

    async def refresh(self, interaction: discord.Interaction, said: str) -> None:
        """Answer the presser privately, then redraw the shared card."""
        trade = await fetch_trade(self.trade_id)
        contents = await fetch_contents(self.trade_id)
        card = await render_trade(trade, contents)

        if interaction.response.is_done():
            await interaction.followup.send(said, ephemeral=True)
        else:
            await interaction.response.send_message(said, ephemeral=True)

        if self.message is not None:
            await self.message.edit(embed=card, view=self)

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True

    # -- offering ----------------------------------------------------------

    @discord.ui.button(label="Manual", emoji="\N{GRADUATION CAP}", row=0)
    async def offer_manual(self, interaction: discord.Interaction, button) -> None:
        player_id = self.player_of(interaction)
        rows = await db.fetch_all(
            """
            SELECT m.manual_id, m.name, m.tier, m.archetype,
                   string_agg(DISTINCT p.name, ' / ') AS paths
            FROM player_manuals pm
            JOIN manuals m ON m.manual_id = pm.manual_id
            LEFT JOIN manual_paths mp ON mp.manual_id = m.manual_id
            LEFT JOIN paths p ON p.code = mp.path_code
            WHERE pm.player_id = %s
              AND m.manual_id NOT IN (
                  SELECT manual_id FROM trade_offer_manuals WHERE trade_id = %s
              )
            GROUP BY m.manual_id
            ORDER BY m.tier DESC, m.name
            """,
            (player_id, self.trade_id),
        )
        if not rows:
            raise GameError("You have no manuals left to offer.")
        await interaction.response.send_message(
            view=PickerView(
                lambda page: ManualPicker(self, player_id, page),
                rows,
                noun="manuals",
            ),
            ephemeral=True,
        )

    @discord.ui.button(label="Pages", emoji="\N{PAGE FACING UP}", row=0)
    async def offer_pages(self, interaction: discord.Interaction, button) -> None:
        player_id = self.player_of(interaction)
        rows = await db.fetch_all(
            """
            SELECT p.page_id, p.tier, p.power, p.quality,
                   pa.name AS path_name, ty.name AS type_name
            FROM manual_pages p
            JOIN paths pa ON pa.code = p.path_code
            JOIN page_types ty ON ty.code = p.page_type
            WHERE p.owner_id = %s AND p.consumed_at IS NULL
              AND p.page_id NOT IN (
                  SELECT page_id FROM trade_offer_pages WHERE trade_id = %s
              )
            ORDER BY p.tier DESC, p.power DESC
            """,
            (player_id, self.trade_id),
        )
        if not rows:
            raise GameError("You are holding no pages.")
        await interaction.response.send_message(
            view=PickerView(
                lambda page: PagePicker(self, player_id, page),
                rows,
                noun="pages",
            ),
            ephemeral=True,
        )

    @discord.ui.button(label="Materials", emoji="\N{HERB}", row=0)
    async def offer_materials(self, interaction: discord.Interaction, button) -> None:
        player_id = self.player_of(interaction)
        rows = await db.fetch_all(
            """
            SELECT m.code, m.name, m.category, m.rarity, pm.quantity
            FROM player_materials pm
            JOIN materials m ON m.code = pm.material_code
            WHERE pm.player_id = %s AND pm.quantity > 0
            ORDER BY m.category, m.name
            """,
            (player_id,),
        )
        if not rows:
            raise GameError("You are carrying nothing to trade.")
        await interaction.response.send_message(
            view=PickerView(
                lambda page: MaterialPicker(self, player_id, page),
                rows,
                noun="materials",
            ),
            ephemeral=True,
        )

    @discord.ui.button(label="Gu", emoji="\N{BUG}", row=0)
    async def offer_gu(self, interaction: discord.Interaction, button) -> None:
        player_id = self.player_of(interaction)
        rows = await db.fetch_all(
            """
            SELECT g.gu_id, g.stars, g.harmony,
                   t.name, t.size, t.emoji, p.name AS path_name,
                   e.gu_id IS NOT NULL AS equipped
            FROM player_gu g
            JOIN gu_types t ON t.gu_type_id = g.gu_type_id
            JOIN paths p ON p.code = t.path_code
            LEFT JOIN player_gu_equipped e ON e.gu_id = g.gu_id
            WHERE g.owner_id = %s
              AND g.gu_id NOT IN (
                  SELECT gu_id FROM trade_offer_gu WHERE trade_id = %s
              )
            ORDER BY e.gu_id IS NOT NULL, t.rank DESC, g.stars DESC, t.name
            """,
            (player_id, self.trade_id),
        )
        if not rows:
            raise GameError(
                "You hold no Gu. **/refinegu** makes one out of what you gather."
            )
        # Spares first: an equipped Gu is somebody's build, and it should take
        # scrolling past the jar to hand one over.
        await interaction.response.send_message(
            view=PickerView(
                lambda page: GuPicker(self, player_id, page),
                rows,
                noun="Gu",
            ),
            ephemeral=True,
        )

    @discord.ui.button(label="Gear", emoji="\N{HAMMER AND PICK}", row=0)
    async def offer_equipment(self, interaction: discord.Interaction, button) -> None:
        player_id = self.player_of(interaction)
        rows = await db.fetch_all(
            """
            SELECT pe.equipment_id, pe.name, pe.tier, pe.rarity, pe.harmony,
                   s.name AS slot_name, s.emoji, p.name AS path_name,
                   w.equipment_id IS NOT NULL AS worn,
                   (SELECT string_agg(ef.emoji || ' ' || ef.name || ' '
                                      || CASE WHEN ef.is_base
                            THEN '+' || round(ee.magnitude)::text
                            ELSE round(100 * ee.magnitude) || '%%' END,
                                      ' ' ORDER BY ef.sort_order)
                    FROM equipment_effects ee
                    JOIN gu_effects ef ON ef.code = ee.effect_code
                    WHERE ee.equipment_id = pe.equipment_id) AS grants
            FROM player_equipment pe
            JOIN equipment_slots s ON s.code = pe.slot
            LEFT JOIN paths p ON p.code = pe.path_code
            LEFT JOIN player_equipped w ON w.equipment_id = pe.equipment_id
            WHERE pe.owner_id = %s
              AND pe.equipment_id NOT IN (
                  SELECT equipment_id FROM trade_offer_equipment
                  WHERE trade_id = %s
              )
            ORDER BY w.equipment_id IS NOT NULL, pe.tier DESC, pe.name
            """,
            (player_id, self.trade_id),
        )
        if not rows:
            raise GameError(
                "You have forged nothing. **/forge** turns ore into a piece."
            )
        # Spares first, the same as the Gu jar: a worn piece is somebody's
        # build and should take scrolling past to hand over.
        await interaction.response.send_message(
            view=PickerView(
                lambda page: EquipmentPicker(self, player_id, page),
                rows,
                noun="pieces",
            ),
            ephemeral=True,
        )

    # Row 0 is full: Discord allows five buttons a row and Manual, Pages,
    # Materials, Gu and Gear already fill it. Pills open row 1, and the
    # settling buttons move down to row 2 behind them.
    @discord.ui.button(label="Pills", emoji="\N{PILL}", row=1)
    async def offer_pills(self, interaction: discord.Interaction, button) -> None:
        player_id = self.player_of(interaction)
        rows = await db.fetch_all(
            """
            SELECT pp.pill_id, pp.name, pp.tier, pp.quantity, pp.magnitude,
                   pp.harmony, k.name AS kind_name, k.emoji
            FROM player_pills pp
            JOIN pill_kinds k ON k.code = pp.kind
            WHERE pp.owner_id = %s
              AND pp.pill_id NOT IN (
                  SELECT pill_id FROM trade_offer_pills WHERE trade_id = %s
              )
            ORDER BY pp.tier DESC, pp.name
            """,
            (player_id, self.trade_id),
        )
        if not rows:
            raise GameError(
                "You are carrying no pills. **/alchemy** is where they are brewed."
            )
        await interaction.response.send_message(
            view=PickerView(
                lambda page: PillPicker(self, player_id, page),
                rows,
                noun="pills",
            ),
            ephemeral=True,
        )

    @discord.ui.button(label="Eggs", emoji="\N{EGG}", row=1)
    async def offer_eggs(self, interaction: discord.Interaction, button) -> None:
        player_id = self.player_of(interaction)
        rows = await db.fetch_all(
            """
            SELECT s.egg_id, s.name, s.tier, s.rarity, s.beast, s.emoji,
                   s.found_in_name
            FROM player_egg_shelf s
            WHERE s.owner_id = %s
              AND s.egg_id NOT IN (
                  SELECT egg_id FROM trade_offer_eggs WHERE trade_id = %s
              )
            ORDER BY s.tier DESC, s.rarity_order DESC, s.name
            """,
            (player_id, self.trade_id),
        )
        if not rows:
            raise GameError(
                "You are holding no eggs. Beasts leave them where beasts "
                "are thickest."
            )
        await interaction.response.send_message(
            view=PickerView(
                lambda page: EggPicker(self, player_id, page),
                rows,
                noun="eggs",
            ),
            ephemeral=True,
        )

    @discord.ui.button(label="Servants", emoji="\N{BUSTS IN SILHOUETTE}", row=1)
    async def offer_servants(self, interaction: discord.Interaction, button) -> None:
        player_id = self.player_of(interaction)
        rows = await db.fetch_all(
            """
            SELECT ps.player_servant_id, s.name, t.rarity, ps.stars,
                   -- The copy's tier since 0478, not the kind's: an
                   -- ascended servant is worth what it is now.
                   servant_tier_of(ps.player_servant_id) AS tier,
                   b.name AS bonus_name, r.name AS realm_name
            FROM player_servants ps
            JOIN servants s        ON s.servant_code = ps.servant_code
            JOIN servant_tiers t   ON t.tier = servant_tier_of(ps.player_servant_id)
            JOIN servant_bonuses b ON b.kind = s.bonus_kind
            JOIN realms r          ON r.realm_id = ps.realm_id
            WHERE ps.player_id = %s
              -- The two `trade_add_servant` would refuse anyway. Offering
              -- them here only to be told no is a worse screen than not
              -- offering them.
              AND NOT ps.farming
              AND NOT EXISTS (SELECT 1 FROM player_servant_attending a
                              WHERE a.player_servant_id = ps.player_servant_id)
              AND ps.player_servant_id NOT IN (
                  SELECT player_servant_id FROM trade_offer_servants
                  WHERE trade_id = %s
              )
            ORDER BY s.tier DESC, ps.stars DESC, s.name
            """,
            (player_id, self.trade_id),
        )
        if not rows:
            raise GameError(
                "No servant of yours is free to give. One who attends you or "
                "is out working has to be sent away or called home first."
            )
        await interaction.response.send_message(
            view=PickerView(
                lambda page: ServantPicker(self, player_id, page),
                rows,
                noun="servants",
            ),
            ephemeral=True,
        )

    # -- settling ----------------------------------------------------------

    @discord.ui.button(label="Confirm", emoji="\N{WHITE HEAVY CHECK MARK}",
                       style=discord.ButtonStyle.success, row=2)
    async def confirm(self, interaction: discord.Interaction, button) -> None:
        player_id = self.player_of(interaction)
        try:
            done = await db.fetch_value(
                "SELECT trade_confirm(%s, %s)", (self.trade_id, player_id)
            )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0].capitalize()) from exc

        if not done:
            await self.refresh(interaction, "Confirmed. Waiting on the other side.")
            return

        trade = await fetch_trade(self.trade_id)
        contents = await fetch_contents(self.trade_id)
        for item in self.children:
            item.disabled = True
        await interaction.response.edit_message(
            embed=await render_trade(trade, contents), view=self
        )
        self.stop()

    @discord.ui.button(label="Take back my offer", row=2)
    async def withdraw(self, interaction: discord.Interaction, button) -> None:
        await db.execute(
            "SELECT trade_withdraw(%s, %s)", (self.trade_id, self.player_of(interaction))
        )
        await self.refresh(interaction, "Your side of the table is clear.")

    @discord.ui.button(label="Cancel", style=discord.ButtonStyle.danger, row=2)
    async def cancel(self, interaction: discord.Interaction, button) -> None:
        await db.execute(
            "SELECT trade_cancel(%s, %s)", (self.trade_id, self.player_of(interaction))
        )
        for item in self.children:
            item.disabled = True
        await interaction.response.edit_message(
            embed=embed(
                "Trade cancelled",
                "Nothing changed hands.",
                colour=COLOUR_INFO,
            ),
            view=self,
        )
        self.stop()


class Trade(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @app_commands.command(description="Swap manuals, pages, materials and Gu with another cultivator.")
    @app_commands.describe(partner="Who you are trading with.")
    async def trade(self, interaction: discord.Interaction, partner: discord.User) -> None:
        me = await require_player(interaction.user)

        if partner.bot:
            raise GameError("Bots have nothing you want.")

        them = await fetch_player(partner.id)
        if them is None:
            raise GameError(f"**{partner.display_name}** has not begun cultivating yet.")

        # A table the two of you already have open. The view dies with a
        # restart or its own timeout while the trade itself lives in the
        # database, and refusing then locked both of them out for the whole
        # expiry - half an hour of waiting for a screen that no longer exists.
        # Everything the screen shows is stored, so it can simply be handed
        # back with the offers still on it.
        resumed = await db.fetch_value(
            """
            SELECT t.trade_id FROM trades t
            WHERE t.status = 'open'
              AND ((t.proposer_id = %s AND t.partner_id = %s)
                OR (t.proposer_id = %s AND t.partner_id = %s))
            ORDER BY t.trade_id DESC LIMIT 1
            """,
            (me["player_id"], them["player_id"],
             them["player_id"], me["player_id"]),
        )

        if resumed is None:
            try:
                resumed = await db.fetch_value(
                    "SELECT trade_open(%s, %s)", (me["player_id"], them["player_id"])
                )
            except psycopg.errors.CheckViolation as exc:
                raise GameError(str(exc).splitlines()[0].capitalize()) from exc
            opening = f"{partner.mention} — {interaction.user.display_name} wants to trade."
        else:
            opening = (
                f"{partner.mention} — {interaction.user.display_name} is back at "
                "the table. Nothing was lost."
            )

        trade = await fetch_trade(resumed)
        # Whoever proposed it originally, which on a resumed table may be the
        # other one of them. The map covers both either way.
        view = TradeView(
            resumed,
            trade["proposer_id"],
            trade["partner_id"],
            {me["player_id"]: interaction.user.id, them["player_id"]: partner.id},
        )
        await interaction.response.send_message(
            content=opening,
            embed=await render_trade(trade, await fetch_contents(resumed)),
            view=view,
        )
        view.message = await interaction.original_response()


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Trade(bot))
