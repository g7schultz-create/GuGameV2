"""The index: /find.

A recipe says "12 Tide Stone" and the game had never once said where a Tide
Stone is. Everything needed to answer that has been in `region_materials`,
`region_veins` and `creature_drops` since those tables were written; it was
just only readable by whoever wrote the migration.

Two directions, because they are the two questions people actually have:

    /find <material>   I have a recipe. Where is this?
    /find              I have an afternoon. What is around here?

No arithmetic lives here. `material_sources` and `region_finds` turn the
weights into shares, so a screen never has to know that a weight is relative
to its region's total - which is exactly the sort of thing two screens would
end up doing differently.
"""

import discord
from discord import app_commands
from discord.ext import commands

from bot import database as db
from bot.formatting import COLOUR_INFO, embed, thousands
from bot.players import GameError, fetch_player, require_player
from bot.views import AnsweringView

# How each way of getting a thing is drawn. The verb matters: you gather a
# herb, you strike a vein, and you take a fang off something.
WAYS = {
    "gather": ("\N{HERB}", "Gathered", "/gather"),
    "mine": ("\N{PICK}", "Mined", "/mine"),
    "hunt": ("\N{CROSSED SWORDS}", "Taken from beasts", "/hunt"),
}

# A gazetteer entry, in the order somebody reads one: what is here, what lives
# here, what it drops, and where you can go next.
SECTIONS = (
    ("gather", "\N{HERB}", "Grows here", "/gather"),
    ("mine", "\N{PICK}", "Under the ground", "/mine"),
    ("beast", "\N{PAW PRINTS}", "Lives here", "/hunt"),
    ("gu", "\N{BUG}", "Gu found here", "/hunt"),
    ("road", "\N{COMPASS}", "Roads out", "/travel"),
)

# Discord allows 1024 characters in a field. A region with thirty-three herbs
# in it needs a cut somewhere, and it is better for the cut to be visible than
# for Discord to refuse the whole message.
FIELD_LIMIT = 1000


def _chips(rows: list[dict], with_share: bool) -> str:
    """As many as will fit, and an honest count of what did not.

    Named rather than coded - this game has a name and an emoji for
    everything, and `dark_crystal` is what the table calls it rather than what
    anybody calls it.
    """
    out: list[str] = []
    used = 0
    for i, row in enumerate(rows):
        chip = f"{row['emoji']} {row['name']}"
        if with_share and row["share"] is not None:
            chip += f" `{row['share']}%`"
        elif row["note"]:
            chip += f" `{row['note']}`"
        if used + len(chip) + 3 > FIELD_LIMIT and out:
            return " \N{BULLET} ".join(out) + f"\n*… and {len(rows) - i} more*"
        out.append(chip)
        used += len(chip) + 3
    return " \N{BULLET} ".join(out) or "*Nothing.*"


async def fetch_sources(code: str) -> list[dict]:
    return await db.fetch_all("SELECT * FROM material_sources(%s)", (code,))


async def fetch_material(code: str) -> dict | None:
    return await db.fetch_one(
        """
        SELECT m.code, material_name(m.code) AS name, m.emoji, m.rarity,
               m.category, p.name AS path_name, p.emoji AS path_emoji,
               (SELECT count(*) FROM ores o WHERE o.material_code = m.code) > 0 AS is_ore,
               (SELECT count(*) FROM beast_parts b WHERE b.material_code = m.code) > 0
                   AS is_part
        FROM materials m
        LEFT JOIN paths p ON p.code = m.path_code
        WHERE m.code = %s
        """,
        (code,),
    )


# Ten sources a page. Each one draws two lines - a place and what it yields -
# so ten is what fits a field with room for the footer, and one material in the
# game has forty-nine of them.
SOURCES_PER_PAGE = 10


async def render_material(code: str, held: int, page: int = 0) -> discord.Embed:
    what = await fetch_material(code)
    if what is None:
        raise GameError(f"There is no material called `{code}`.")

    rows = await fetch_sources(code)

    card = embed(
        f"{what['emoji']} {what['name']}",
        f"{what['rarity'].title()} {what['category']}"
        + (f" \N{BULLET} {what['path_emoji']} {what['path_name']}"
           if what["path_name"] else "")
        + (" \N{BULLET} forgeable ore" if what["is_ore"] else "")
        + (" \N{BULLET} beast material" if what["is_part"] else ""),
        colour=COLOUR_INFO,
    )
    card.add_field(
        name="You are carrying",
        value=f"{what['emoji']} **{thousands(held)}**",
        inline=False,
    )

    if not rows:
        card.add_field(
            name="Nowhere",
            value="Nothing in the world drops this. It is either currency or "
            "something the game hands you directly.",
            inline=False,
        )
        return card

    # Paged over the WHOLE list rather than cut at eight per way. A material
    # with forty-nine sources used to show eight of them and say "and 41 more",
    # which is the screen admitting it knows the answer and will not say it.
    pages = max(1, -(-len(rows) // SOURCES_PER_PAGE))
    page = max(0, min(page, pages - 1))
    shown = rows[page * SOURCES_PER_PAGE : (page + 1) * SOURCES_PER_PAGE]

    for kind, (emoji, label, command) in WAYS.items():
        mine = [r for r in shown if r["kind"] == kind]
        if not mine:
            continue
        card.add_field(
            name=f"{emoji} {label} \N{BULLET} {command}",
            value="\n".join(
                f"**{r['region_name']}**"
                + (f" \N{BULLET} {r['source_name']}" if r["source_name"] else "")
                + f" \N{BULLET} {r['share']}%\n     *{r['detail']}*"
                for r in mine
            ),
            inline=False,
        )

    # One footer, not two. The page marker joins the standing note rather
    # than being set and then immediately overwritten by it, which is what
    # swallowed it the first time.
    note = (
        "A gathering share is of that region's whole table; a beast's "
        "chance is its own. **/travel** moves you."
    )
    if pages > 1:
        note = (
            f"Page {page + 1} of {pages} \N{BULLET} {len(rows)} places in all"
            " \N{BULLET} " + note
        )
    card.set_footer(text=note)
    return card


async def render_region(code: str, standing_in: str | None) -> discord.Embed:
    """One region, entire. No truncation to a top ten - a gazetteer that shows
    the first ten of thirty-three is a table of contents."""
    region = await db.fetch_one(
        "SELECT code, name, emoji, description, danger_level "
        "FROM regions WHERE code = %s",
        (code,),
    )
    rows = await db.fetch_all("SELECT * FROM region_index(%s)", (code,))

    danger = region["danger_level"]
    card = embed(
        f"{region['emoji']} {region['name']}"
        + ("  \N{ROUND PUSHPIN}" if code == standing_in else ""),
        f"*{region['description']}*",
        colour=COLOUR_INFO,
    )
    card.add_field(
        name="Danger",
        value=("\N{LARGE RED CIRCLE}" * danger)
        + ("\N{MEDIUM WHITE CIRCLE}" * (10 - danger))
        + f"  **{danger}**/10",
        inline=False,
    )

    for kind, emoji, label, command in SECTIONS:
        mine = [r for r in rows if r["kind"] == kind]
        if not mine:
            continue
        heading = f"{emoji} {label} ({len(mine)})"
        if kind != "road":
            heading += f" \N{BULLET} {command}"
        card.add_field(
            name=heading,
            value=_chips(mine, with_share=kind in ("gather", "mine")),
            inline=False,
        )

    card.set_footer(
        text="A share is of that list; a beast's is how often it is the one "
        "you meet. **/find** a material by name for every region it comes from."
    )
    return card


class RegionButton(discord.ui.Button):
    def __init__(self, screen: "IndexView", region: dict) -> None:
        self.screen = screen
        self.region = region
        super().__init__(
            label=region["name"][:80],
            emoji=region["emoji"][:1] if region["emoji"] else None,
            row=(region["sort_order"] // 100) % 4,
            style=(
                discord.ButtonStyle.success
                if region["code"] == screen.showing
                else discord.ButtonStyle.secondary
            ),
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        self.screen.showing = self.region["code"]
        self.screen.build()
        await interaction.response.edit_message(
            embed=await self.screen.card(), view=self.screen
        )


class IndexView(AnsweringView):
    """Public and unowned, like the tutorial. Nothing here is spent, and two
    people planning a trip together should be able to read one screen.

    It does not page. A whole region fits in one embed, and a gazetteer you
    have to turn is a worse gazetteer.
    """

    def __init__(self, regions: list[dict], showing: str, standing_in: str) -> None:
        super().__init__(timeout=600)
        self.regions = regions
        self.showing = showing
        self.standing_in = standing_in
        self.build()

    async def card(self) -> discord.Embed:
        return await render_region(self.showing, self.standing_in)

    def build(self) -> None:
        self.clear_items()
        for region in self.regions:
            self.add_item(RegionButton(self, region))


class SourcesView(AnsweringView):
    """Page buttons for a material with more sources than one screen holds.

    Attached only when there is a second page - a lone disabled arrow under a
    card is a screen apologising for something nobody asked about.
    """

    def __init__(self, code: str, held: int, user: discord.abc.User, pages: int) -> None:
        super().__init__(timeout=300)
        self.code = code
        self.held = held
        self.user = user
        self.pages = pages
        self.page = 0

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "Run **/find** yourself and it is yours to turn.", ephemeral=True
            )
            return False
        return True

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True

    async def turn(self, interaction: discord.Interaction, step: int) -> None:
        self.page = (self.page + step) % self.pages
        await interaction.response.edit_message(
            embed=await render_material(self.code, self.held, self.page), view=self
        )

    @discord.ui.button(emoji="\N{BLACK LEFT-POINTING TRIANGLE}",
                       style=discord.ButtonStyle.secondary)
    async def back(self, interaction: discord.Interaction, button) -> None:
        await self.turn(interaction, -1)

    @discord.ui.button(emoji="\N{BLACK RIGHT-POINTING TRIANGLE}",
                       style=discord.ButtonStyle.secondary)
    async def forward(self, interaction: discord.Interaction, button) -> None:
        await self.turn(interaction, 1)


class Index(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @app_commands.command(
        description="Where a material comes from, or what a region yields."
    )
    @app_commands.describe(material="Leave it out to browse region by region.")
    async def find(
        self, interaction: discord.Interaction, material: str | None = None
    ) -> None:
        if material is not None:
            player = await fetch_player(interaction.user.id)
            held = 0
            if player:
                held = await db.fetch_value(
                    "SELECT COALESCE((SELECT quantity FROM player_materials "
                    "WHERE player_id = %s AND material_code = %s), 0)",
                    (player["player_id"], material),
                )
            pages = max(1, -(-len(await fetch_sources(material))
                              // SOURCES_PER_PAGE))
            view = (
                SourcesView(material, held, interaction.user, pages)
                if pages > 1 else discord.utils.MISSING
            )
            await interaction.response.send_message(
                embed=await render_material(material, held), view=view
            )
            return

        regions = await db.fetch_all(
            "SELECT code, name, emoji, sort_order FROM regions ORDER BY sort_order"
        )
        # Where they are standing, so the first screen is the useful one.
        player = await require_player(interaction.user)
        here = await db.fetch_value(
            "SELECT region_code FROM player_location WHERE player_id = %s",
            (player["player_id"],),
        )
        view = IndexView(regions, here or regions[0]["code"], here)
        await interaction.response.send_message(embed=await view.card(), view=view)

    @find.autocomplete("material")
    async def material_autocomplete(
        self, interaction: discord.Interaction, current: str
    ) -> list[app_commands.Choice[str]]:
        rows = await db.fetch_all(
            """
            SELECT m.code, material_name(m.code) AS name, m.rarity
            FROM materials m
            WHERE material_name(m.code) ILIKE %s AND m.category <> 'currency'
            ORDER BY material_name(m.code)
            LIMIT 25
            """,
            (f"%{current}%",),
        )
        return [
            app_commands.Choice(
                name=f"{r['name']} \N{BULLET} {r['rarity']}"[:100], value=r["code"]
            )
            for r in rows
        ]


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Index(bot))
