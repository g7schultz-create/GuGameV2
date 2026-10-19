"""The auction house: /auction and /sell.

Fixed prices, Spirit Jade only. There is no bidding and no clock, which is why
there is no scheduler: a listing sits until somebody buys it or the seller
takes it back.

**The house owns what is listed.** Posting something transfers it to a player
row with discord_id 0, so this file never has to check whether an item is
"reserved" — it simply is not yours any more, and every other screen in the
bot already knows that. `/gear` cannot show it, `take_pill` refuses it, and a
worn piece comes off on the way out because a trigger says so.

Nothing here computes a price. What a thing is worth is entirely what somebody
will pay for it, which is the point of building this at all.
"""

import discord
import psycopg
from discord import app_commands
from discord.ext import commands

from bot import database as db
from bot.character import RARITY_MARK
from bot.formatting import (
    COLOUR_BAD,
    COLOUR_GOOD,
    COLOUR_INFO,
    embed,
    error_embed,
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

JADE = "\N{GREEN HEART}"
TIMES = "\N{MULTIPLICATION SIGN}"

# What a seller can put up, and where each kind comes from. The label and
# description are what the picker shows; the query is what it lists.
STOCK = {
    "material": {
        "label": "Materials",
        "emoji": "\N{PICK}",
        "sql": """
            SELECT pm.material_code AS ref, m.name, m.emoji, m.rarity,
                   pm.quantity, m.category
            FROM player_materials pm
            JOIN materials m ON m.code = pm.material_code
            WHERE pm.player_id = %s AND pm.quantity > 0
              -- Not `category <> 'currency'`. That hid the Dungeon Key, which
              -- is in the purse because it is not shelf stock - a display fact
              -- that was standing in for a rule nobody wrote. The rule is that
              -- you cannot list what the house pays in, and 0228 named it.
              AND pm.material_code <> auction_currency()
            ORDER BY m.rarity DESC, m.name
        """,
        "function": "auction_list_material",
    },
    "equipment": {
        "label": "Equipment",
        "emoji": "\N{HAMMER AND PICK}",
        # What it grants, not only what it is. Two Tier 5 gauntlets of the same
        # name do different things, and pricing one without seeing its bonuses
        # is guesswork - the buyer has had them on the board all along, and
        # only the seller was working blind.
        "sql": """
            SELECT pe.equipment_id::text AS ref, pe.name, s.emoji,
                   pe.rarity, 1 AS quantity,
                   'tier ' || pe.tier || ' ' || s.name AS category,
                   (SELECT string_agg(ef.emoji || ' ' || ef.name || ' '
                                      || CASE WHEN ef.is_base
                            THEN '+' || round(ee.magnitude)::text
                            ELSE round(100 * ee.magnitude) || '%%' END,
                                      ' \N{BULLET} ' ORDER BY ef.sort_order)
                    FROM equipment_effects ee
                    JOIN gu_effects ef ON ef.code = ee.effect_code
                    WHERE ee.equipment_id = pe.equipment_id) AS grants
            FROM player_equipment pe
            JOIN equipment_slots s ON s.code = pe.slot
            WHERE pe.owner_id = %s
            ORDER BY pe.tier DESC, pe.name
        """,
        "function": "auction_list_equipment",
    },
    "gu": {
        "label": "Gu",
        "emoji": "\N{BUG}",
        "sql": """
            SELECT g.gu_id::text AS ref, t.name, t.emoji, t.rarity,
                   1 AS quantity, repeat('*', g.stars) || ' rank ' || t.rank AS category
            FROM player_gu g
            JOIN gu_types t ON t.gu_type_id = g.gu_type_id
            WHERE g.owner_id = %s
            ORDER BY g.stars DESC, t.name
        """,
        "function": "auction_list_gu",
    },
    "pill": {
        "label": "Pills",
        "emoji": "\N{PILL}",
        "sql": """
            SELECT p.pill_id::text AS ref, p.name, k.emoji, 'common' AS rarity,
                   p.quantity, 'tier ' || p.tier || ' ' || k.name AS category
            FROM player_pills p
            JOIN pill_kinds k ON k.code = p.kind
            WHERE p.owner_id = %s
            ORDER BY p.tier DESC, p.name
        """,
        "function": "auction_list_pill",
    },
    "page": {
        "label": "Manual pages",
        "emoji": "\N{SCROLL}",
        "sql": """
            SELECT mp.page_id::text AS ref,
                   'Tier ' || mp.tier || ' ' || pa.name AS name,
                   pa.emoji, 'common' AS rarity, 1 AS quantity,
                   ty.name || ', power ' || mp.power AS category
            FROM manual_pages mp
            JOIN paths pa ON pa.code = mp.path_code
            JOIN page_types ty ON ty.code = mp.page_type
            WHERE mp.owner_id = %s AND mp.consumed_at IS NULL
            ORDER BY mp.tier DESC, mp.power DESC
        """,
        "function": "auction_list_page",
    },
    "manual": {
        "label": "Manuals",
        "emoji": "\N{CLOSED BOOK}",
        # Not what is equipped: letting go of a manual cascades the slot away
        # anyway, so a worn one comes off on the way out and the seller finds
        # out afterwards. The list leaves them out so the choice is never a
        # surprise. An advanced technique manual is named as such, because
        # what it teaches is the whole reason anybody would buy it.
        "sql": """
            SELECT m.manual_id::text AS ref, m.name,
                   CASE WHEN m.archetype = 'technique'
                        THEN '\N{SCROLL}' ELSE '\N{CLOSED BOOK}' END AS emoji,
                   m.quality AS rarity, 1 AS quantity,
                   'tier ' || m.tier || ' ' || m.archetype
                   || COALESCE(' \N{BULLET} ' || t.name, '') AS category
            FROM player_manuals pm
            JOIN manuals m ON m.manual_id = pm.manual_id
            LEFT JOIN manual_techniques mt ON mt.manual_id = m.manual_id
            LEFT JOIN techniques t ON t.technique_id = mt.technique_id
            WHERE pm.player_id = %s
              AND NOT EXISTS (SELECT 1 FROM player_manual_slots sl
                              WHERE sl.player_id = pm.player_id
                                AND sl.manual_id = pm.manual_id)
            ORDER BY m.tier DESC, m.name
        """,
        "function": "auction_list_manual",
    },
}


# Embed fields cap at 1024 and eight listings share one. A Gu with five
# effects and a halberd with five more would blow it on their own, so each
# listing gets a slice of the budget rather than the field being trimmed at the
# end - a board that 400s shows nothing at all.
STAT_ROOM = 96


def clip(said: str, room: int = STAT_ROOM) -> str:
    if said is None:
        return ""
    said = said.strip()
    if len(said) <= room:
        return said
    # Cut at a separator so half an effect name never appears.
    cut = said[:room].rsplit(" \N{MIDDLE DOT} ", 1)[0]
    return (cut if cut else said[:room]) + "\N{HORIZONTAL ELLIPSIS}"


def listing_line(row: dict) -> str:
    """What it is, what it does, what it costs, who is selling it.

    The stats come from `auction_board` rather than being assembled here: a
    listing holds one of six different things and the view is the one place
    that knows which. This screen only decides how much of it fits.
    """
    told = [
        f"{RARITY_MARK.get(row['rarity'], '')} {row['emoji']} **{row['label']}**"
    ]
    if row.get("detail"):
        told.append(f"*{clip(row['detail'])}*")
    if row.get("grants"):
        told.append(clip(row["grants"]))
    told.append(f"{JADE} **{thousands(row['price'])}** \N{BULLET} *{row['seller_name']}*")
    return "\n".join(told)


async def fetch_board(limit: int = 20) -> list[dict]:
    return await db.fetch_all(
        "SELECT * FROM auction_board WHERE status = 'open' "
        "ORDER BY listed_at DESC LIMIT %s",
        (limit,),
    )


async def fetch_mine(player_id: int) -> list[dict]:
    return await db.fetch_all(
        "SELECT * FROM auction_board WHERE status = 'open' AND seller_id = %s "
        "ORDER BY listed_at DESC",
        (player_id,),
    )


async def render_board(
    player_id: int, rows: list[dict], mine: list[dict], *, page: int = 0
) -> discord.Embed:
    purse = await db.fetch_value("SELECT jade_held(%s)", (player_id,))
    fee = await db.fetch_value("SELECT game_config_value('auction_listing_fee')")

    card = embed(
        "\N{BANK} The auction house",
        "Everything here is priced in Spirit Jade, and nothing here is priced "
        "by the game. What a thing is worth is what somebody will pay for it.",
        colour=COLOUR_INFO,
    )
    card.add_field(
        name="Your purse",
        value=f"{JADE} **{thousands(purse)}** Spirit Jade",
        inline=False,
    )
    if rows:
        # The same page the select is offering, so what is read and what can
        # be bought are the same eight listings.
        shown = page_of(
            by_type_and_strength(
                [r for r in rows if r["seller_id"] != player_id],
                kind=lambda r: r["kind"],
                strength=lambda r: -r["price"],
                name=lambda r: r["label"],
            ),
            page,
        )
        told = "\n\n".join(listing_line(r) for r in shown[:8])
        # A listing was one line and is now up to four. Drop the tail rather
        # than the field: Discord refuses the whole embed over 1024.
        while len(told) > 1024 and shown:
            shown = shown[:-1]
            told = "\n\n".join(listing_line(r) for r in shown)
        card.add_field(
            name=f"On the board ({len(rows)})",
            value=told or "*Only your own listings are up.*",
            inline=False,
        )
    else:
        card.add_field(
            name="On the board",
            value="*Nothing is up. **/sell** puts the first thing on it.*",
            inline=False,
        )
    if mine:
        card.add_field(
            name=f"Yours ({len(mine)})",
            value="\n".join(
                f"{r['emoji']} {r['label']} \N{BULLET} {JADE} {thousands(r['price'])}"
                + (f"\n*{clip(r['detail'], 64)}*" if r.get("detail") else "")
                for r in mine[:8]
            )[:1024],
            inline=False,
        )
    note = page_note(
        [r for r in rows if r["seller_id"] != player_id], page, "listings"
    )
    card.set_footer(
        text=(note + " \N{BULLET} " if note else "")
        + f"Listing costs {int(fee)} Jade and is not refunded. "
        "A sale moves money between players — none is created."
    )
    return card


class BuySelect(discord.ui.Select):
    def __init__(self, screen: "BoardView", rows: list[dict]) -> None:
        self.screen = screen
        super().__init__(
            placeholder="Buy…",
            options=[
                discord.SelectOption(
                    label=f"{r['label']}"[:100],
                    value=str(r["listing_id"]),
                    description=(
                        f"{r['price']} Jade \N{BULLET} "
                        + (f"{r['detail']} \N{BULLET} " if r.get("detail") else "")
                        + r["seller_name"]
                    )[:100],
                    emoji=r["emoji"][:1] if r["emoji"] else None,
                )
                for r in rows
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        listing = next(
            r for r in self.screen.rows if str(r["listing_id"]) == self.values[0]
        )
        try:
            done = await db.fetch_one(
                "SELECT * FROM auction_buy(%s, %s)",
                (self.screen.player_id, int(self.values[0])),
            )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0].capitalize()) from exc

        card = embed(
            f"{listing['emoji']} {listing['label']}",
            f"Bought for {JADE} **{thousands(done['price'])}** Spirit Jade.",
            colour=COLOUR_GOOD,
        )
        card.add_field(name="Left in your purse", value=f"{JADE} {thousands(done['jade_left'])}")
        card.set_footer(text="It is yours. Nothing was minted; the money changed hands.")
        await self.screen.refresh(interaction, card)


class CancelSelect(discord.ui.Select):
    def __init__(self, screen: "BoardView", rows: list[dict]) -> None:
        self.screen = screen
        super().__init__(
            placeholder="Take one back…",
            options=[
                discord.SelectOption(
                    label=f"{r['label']}"[:100],
                    value=str(r["listing_id"]),
                    description=f"listed at {r['price']} Jade"[:100],
                    emoji=r["emoji"][:1] if r["emoji"] else None,
                )
                for r in rows
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        try:
            await db.execute(
                "SELECT auction_cancel(%s, %s)",
                (self.screen.player_id, int(self.values[0])),
            )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0].capitalize()) from exc

        card = embed(
            "Taken back",
            "It is in your hands again. The listing fee is not returned — it is "
            "what the board costs.",
            colour=COLOUR_INFO,
        )
        await self.screen.refresh(interaction, card)


class BoardView(AnsweringView):
    def __init__(self, player_id: int, user: discord.abc.User,
                 rows: list[dict], mine: list[dict]) -> None:
        super().__init__(timeout=300)
        self.player_id = player_id
        self.user = user
        self.rows = rows
        self.mine = mine
        self.page = 0
        self.build()

    def theirs(self) -> list[dict]:
        # Your own listings are not offered for sale to you: `auction_buy`
        # refuses it anyway, and a select that only ever errors is a trap.
        return by_type_and_strength(
            [r for r in self.rows if r["seller_id"] != self.player_id],
            kind=lambda r: r["kind"],
            # Cheapest first is the useful order on a board you are buying
            # from, so the price sorts ascending rather than descending.
            strength=lambda r: -r["price"],
            name=lambda r: r["label"],
        )

    def page_count(self) -> int:
        return page_count(self.theirs())

    async def card(self) -> discord.Embed:
        return await render_board(
            self.player_id, self.rows, self.mine, page=self.page
        )

    def build(self) -> None:
        self.clear_items()
        theirs = self.theirs()
        if theirs:
            self.add_item(BuySelect(self, page_of(theirs, self.page)))
        if self.mine:
            self.add_item(CancelSelect(self, self.mine[:25]))
        add_page_buttons(self, row=2)

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "Open your own **/auction**.", ephemeral=True
            )
            return False
        return True

    async def refresh(self, interaction: discord.Interaction, card: discord.Embed) -> None:
        self.rows = await fetch_board()
        self.mine = await fetch_mine(self.player_id)
        self.build()
        await interaction.response.edit_message(embed=card, view=self)

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True


# ---------------------------------------------------------------------------
# Selling
# ---------------------------------------------------------------------------


class PriceModal(discord.ui.Modal):
    price = discord.ui.TextInput(label="Price in Spirit Jade", max_length=12)
    amount = discord.ui.TextInput(label="How many", max_length=12, required=False)

    def __init__(self, screen: "SellView", kind: str, row: dict) -> None:
        super().__init__(title=f"Sell {row['name']}"[:45])
        self.screen = screen
        self.kind = kind
        self.row = row
        if kind == "material":
            self.amount.placeholder = f"You hold {row['quantity']}"
        else:
            self.remove_item(self.amount)

    async def on_submit(self, interaction: discord.Interaction) -> None:
        try:
            price = int(str(self.price).strip())
        except ValueError as exc:
            raise GameError("A price is a number of Spirit Jade.") from exc
        if price <= 0:
            raise GameError("Nothing is sold for nothing.")

        function = STOCK[self.kind]["function"]
        try:
            if self.kind == "material":
                try:
                    quantity = int(str(self.amount).strip() or "0")
                except ValueError as exc:
                    raise GameError("That is not a number.") from exc
                if quantity <= 0:
                    raise GameError("Say how many you are selling.")
                await db.execute(
                    f"SELECT {function}(%s, %s, %s, %s)",
                    (self.screen.player_id, self.row["ref"], quantity, price),
                )
            else:
                await db.execute(
                    f"SELECT {function}(%s, %s, %s)",
                    (self.screen.player_id, int(self.row["ref"]), price),
                )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0].capitalize()) from exc

        card = embed(
            f"{self.row['emoji']} {self.row['name']}",
            f"Up for {JADE} **{thousands(price)}** Spirit Jade.",
            colour=COLOUR_GOOD,
        )
        # In full here, because the select's description is capped at a hundred
        # characters and a piece with four bonuses does not fit in one.
        if self.row.get("grants"):
            card.add_field(
                name="What it grants",
                value=self.row["grants"],
                inline=False,
            )
        card.set_footer(
            text="The house is holding it until somebody buys it or you take "
            "it back. **/auction** to see the board."
        )
        await interaction.response.send_message(embed=card)

    async def on_error(self, interaction: discord.Interaction, error: Exception) -> None:
        if not await answer_error(interaction, error):
            await super().on_error(interaction, error)


class StockSelect(discord.ui.Select):
    def __init__(self, screen: "SellView", kind: str, rows: list[dict]) -> None:
        self.screen = screen
        self.kind = kind
        self.rows = {r["ref"]: r for r in rows}
        super().__init__(
            placeholder="Which one?",
            options=[
                discord.SelectOption(
                    label=(
                        f"{r['name']}"
                        + (f" {TIMES}{r['quantity']}" if r["quantity"] > 1 else "")
                    )[:100],
                    value=r["ref"],
                    # What it grants leads where a row has it; the category is
                    # the fallback, and everything but gear only has that.
                    description=(
                        r.get("grants") or str(r["category"])
                    )[:100],
                    emoji=r["emoji"][:1] if r["emoji"] else None,
                )
                for r in rows
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        await interaction.response.send_modal(
            PriceModal(self.screen, self.kind, self.rows[self.values[0]])
        )


class StockPicker(PagedPicker):
    """The shared paged menu, with this cog's way of answering a refusal."""

    async def on_error(self, interaction, error: Exception, item) -> None:
        if not await answer_error(interaction, error):
            await super().on_error(interaction, error, item)


class KindButton(discord.ui.Button):
    def __init__(self, screen: "SellView", kind: str) -> None:
        self.screen = screen
        self.kind = kind
        super().__init__(
            label=STOCK[kind]["label"],
            emoji=STOCK[kind]["emoji"],
            style=discord.ButtonStyle.secondary,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        rows = await db.fetch_all(
            STOCK[self.kind]["sql"], (self.screen.player_id,)
        )
        if not rows:
            raise GameError(f"You have no {STOCK[self.kind]['label'].lower()} to sell.")

        view = StockPicker(
            lambda page: StockSelect(self.screen, self.kind, page), rows
        )
        await interaction.response.send_message(
            f"{len(rows)} to choose from.", view=view, ephemeral=True
        )


class SellView(AnsweringView):
    def __init__(self, player_id: int, user: discord.abc.User) -> None:
        super().__init__(timeout=300)
        self.player_id = player_id
        self.user = user
        for kind in STOCK:
            self.add_item(KindButton(self, kind))

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "Sell your own things.", ephemeral=True
            )
            return False
        return True

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True


class Auction(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @app_commands.command(description="The auction house. Everything priced in Spirit Jade.")
    async def auction(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])

        rows = await fetch_board()
        mine = await fetch_mine(player["player_id"])
        view = BoardView(player["player_id"], interaction.user, rows, mine)
        await interaction.response.send_message(
            embed=await render_board(player["player_id"], rows, mine), view=view
        )

    @app_commands.command(description="Put something on the auction house for Spirit Jade.")
    async def sell(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])

        purse = await db.fetch_value("SELECT jade_held(%s)", (player["player_id"],))
        fee = await db.fetch_value("SELECT game_config_value('auction_listing_fee')")
        open_now = await db.fetch_value(
            "SELECT count(*) FROM auction_listings WHERE seller_id = %s AND status = 'open'",
            (player["player_id"],),
        )
        most = await db.fetch_value("SELECT game_config_value('auction_max_open')")

        if purse < fee:
            raise GameError(
                f"A listing costs {int(fee)} Spirit Jade and you have "
                f"{thousands(purse)}. Jade comes from breaking through a realm, "
                "killing something you have never killed, and off rogues."
            )

        card = embed(
            "\N{LABEL} Sell something",
            "The house holds whatever you list until somebody buys it or you "
            "take it back. **A worn piece comes off** and **an equipped Gu "
            "leaves the aperture** on the way out — it stops being yours the "
            "moment it goes up.",
            colour=COLOUR_INFO if purse >= fee else COLOUR_BAD,
        )
        card.add_field(
            name="Costs",
            value=f"{JADE} **{int(fee)}** to list, not refunded. "
            f"You hold {JADE} {thousands(purse)}.",
            inline=False,
        )
        card.add_field(
            name="Listings",
            value=f"**{open_now}** of {int(most)} up.",
            inline=False,
        )
        card.set_footer(text="Manuals cannot be sold yet. Pages can.")
        await interaction.response.send_message(
            embed=card, view=SellView(player["player_id"], interaction.user)
        )


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Auction(bot))
