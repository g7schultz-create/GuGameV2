"""The garden and the merchant: /garden, /plant, /harvest, /market.

A dwelling had ten facilities and every one of them was a passive fraction -
you raised it and then it sat there being worth a percentage. The garden is the
first thing in a dwelling a cultivator DOES: put a herb in the ground, wait,
take back more than went in.

And the merchant is the first place a spirit stone can be spent on something
that is not a door. `sell_to_broker` took things off cultivators and
`auction_buy` bought from other players; nothing sold them anything, which is
how the deepest purses reached a quadrillion.

NOTHING TICKS, here as nowhere else in this game. A plot is ready when its hour
has passed and `garden_harvest` is what notices; the merchant's cart is keyed
on the hour itself, so whoever looks first builds it and everybody after reads
the same one - a shelf nobody can reroll by asking twice.
"""

import discord
import psycopg
from discord import app_commands
from discord.ext import commands

from bot import database as db
from bot.formatting import COLOUR_GOOD, COLOUR_INFO, embed, thousands
from bot.players import GameError, require_player

SEEDLING = "\N{SEEDLING}"
HERB = "\N{HERB}"
CART = "\N{SHOPPING TROLLEY}"
STONE = "\N{LARGE BLUE DIAMOND}"
DOT = "\N{BULLET}"
CLOCK = "\N{HOURGLASS WITH FLOWING SAND}"
DONE = "\N{WHITE HEAVY CHECK MARK}"

KINDS = {
    "material": HERB,
    "essence": "\N{SPARKLES}",
    "gu": "\N{BUG}",
    "egg": "\N{EGG}",
    # 0580. Graded by rarity rather than tiered, and sold by the merchant
    # since nothing with a NULL tier could reach his material lane.
    "beast": "\N{PAW PRINTS}",
}


def refuse(exc: psycopg.errors.CheckViolation) -> GameError:
    return GameError(str(exc).splitlines()[0].capitalize() + ".")


async def garden_card(player_id: int, who: str, said: str | None = None):
    plots = await db.fetch_value("SELECT garden_plots(%s)", (player_id,))
    rows = await db.fetch_all(
        """
        SELECT g.plot_no, g.material_code, material_name(g.material_code) AS name,
               g.planted, g.ready_at, g.ready_at <= now() AS ready,
               m.emoji
        FROM player_garden g
        JOIN materials m ON m.code = g.material_code
        WHERE g.player_id = %s
        ORDER BY g.plot_no
        """,
        (player_id,),
    )

    card = embed(
        f"{SEEDLING} The garden at {who}'s dwelling",
        said or f"**{len(rows)} of {plots}** plots are planted.",
        colour=COLOUR_GOOD if said else COLOUR_INFO,
    )

    if plots <= 0:
        card.description = (
            "You have no ground to plant in. A dwelling comes first "
            "\N{EM DASH} **/dwelling**."
        )
        return card

    held = {r["plot_no"]: r for r in rows}
    lines = []
    for n in range(1, int(plots) + 1):
        r = held.get(n)
        if r is None:
            lines.append(f"`{n}` \N{LARGE BROWN SQUARE} *bare ground*")
        elif r["ready"]:
            lines.append(
                f"`{n}` {DONE} {r['emoji'] or HERB} **{r['name']}** "
                f"{DOT} {thousands(r['planted'])} planted {DOT} **ready**"
            )
        else:
            lines.append(
                f"`{n}` {CLOCK} {r['emoji'] or HERB} **{r['name']}** "
                f"{DOT} {thousands(r['planted'])} planted {DOT} "
                f"<t:{int(r['ready_at'].timestamp())}:R>"
            )
    card.add_field(name="Plots", value="\n".join(lines), inline=False)
    card.set_footer(
        # /garden plant and /garden harvest since the fold: the garden
        # became a Group to fit under Discord's hundred-command ceiling,
        # and this footer went on naming the commands it used to have.
        text="**/garden plant** to put something in \N{BULLET} "
        "**/garden harvest** to take it out \N{BULLET} deeper herbs take "
        "longer and pay the same multiple."
    )
    return card


class Garden(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    # A GROUP, not three commands. Discord allows a hundred top-level
    # slash commands and this bot sits at ninety-eight; `garden`, `plant`
    # and `harvest` as three of their own would have been a hundred and
    # one and the cog refused to load at all. A group costs one slot
    # however many subcommands it carries.
    garden = app_commands.Group(
        name="garden", description="The ground at your dwelling."
    )

    # -----------------------------------------------------------------------

    @garden.command(name="look", description="What is in the ground.")
    async def garden_look(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        await interaction.response.defer()
        await interaction.followup.send(
            embed=await garden_card(player["player_id"], player["discord_name"])
        )

    # -----------------------------------------------------------------------

    @garden.command(name="plant", description="Put a herb in the ground.")
    @app_commands.describe(
        herb="What to plant. Deeper herbs take longer.",
        amount="How many to put in this plot.",
    )
    async def plant(
        self, interaction: discord.Interaction, herb: str, amount: int = 1
    ) -> None:
        player = await require_player(interaction.user)
        await interaction.response.defer()
        try:
            got = await db.fetch_one(
                "SELECT * FROM garden_plant(%s, %s, %s)",
                (player["player_id"], herb, amount),
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        said = (
            f"{thousands(got['planted'])} \N{MULTIPLICATION X} "
            f"**{got['material_name']}** into plot `{got['plot_no']}`, up "
            f"<t:{int(got['ready_at'].timestamp())}:R>.\n\n"
            f"{got['plots_free']} plot(s) still bare."
        )
        await interaction.followup.send(
            embed=await garden_card(player["player_id"], player["discord_name"], said)
        )

    @plant.autocomplete("herb")  # noqa: F821 - the group command above
    async def herb_autocomplete(
        self, interaction: discord.Interaction, current: str
    ) -> list[app_commands.Choice[str]]:
        player = await db.fetch_one(
            "SELECT player_id FROM players WHERE discord_id = %s",
            (interaction.user.id,),
        )
        if player is None:
            return []
        rows = await db.fetch_all(
            """
            SELECT m.code, m.name, m.tier, pm.quantity,
                   garden_ready_at(m.code) AS grows_in
            FROM player_materials pm
            JOIN materials m ON m.code = pm.material_code
            WHERE pm.player_id = %s AND pm.quantity > 0 AND m.name ILIKE %s
              -- Only things that grow. Spirit Stone has no tier and is not a
              -- seed; `garden_plant` refuses it anyway.
              AND m.tier IS NOT NULL
            ORDER BY m.tier DESC, m.name
            LIMIT 25
            """,
            (player["player_id"], f"%{current}%"),
        )
        return [
            app_commands.Choice(
                name=(
                    f"{r['name']} \N{BULLET} {thousands(r['quantity'])} held "
                    f"\N{BULLET} {r['grows_in']}"
                )[:100],
                value=r["code"],
            )
            for r in rows
        ]

    # -----------------------------------------------------------------------

    @garden.command(name="harvest", description="Take in what has finished growing.")
    async def garden_harvest_cmd(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        await interaction.response.defer()
        rows = await db.fetch_all(
            "SELECT * FROM garden_harvest(%s)", (player["player_id"],)
        )
        if not rows:
            raise GameError(
                "Nothing is ready yet. **/garden** to see what is still coming."
            )

        said = "\n".join(
            f"{HERB} **{r['material_name']}** {DOT} "
            f"{thousands(r['planted'])} \N{RIGHTWARDS ARROW} "
            f"**{thousands(r['picked'])}**"
            for r in rows
        )
        await interaction.followup.send(
            embed=await garden_card(
                player["player_id"], player["discord_name"],
                f"Taken in:\n{said}",
            )
        )

    # -----------------------------------------------------------------------

    @app_commands.command(
        description="What the travelling merchant has out this hour."
    )
    @app_commands.describe(buy="The number of a slot to buy.")
    async def market(
        self, interaction: discord.Interaction, buy: int | None = None
    ) -> None:
        player = await require_player(interaction.user)
        await interaction.response.defer()

        bought = None
        if buy is not None:
            try:
                bought = await db.fetch_one(
                    "SELECT * FROM market_buy(%s, %s::smallint)",
                    (player["player_id"], buy),
                )
            except psycopg.errors.CheckViolation as exc:
                raise refuse(exc) from exc

        rows = await db.fetch_all(
            "SELECT * FROM market_today(%s)", (player["player_id"],)
        )
        turns = rows[0]["turns_at"] if rows else None

        card = embed(
            f"{CART} The travelling merchant",
            (
                f"Bought **{bought['label']}** "
                f"\N{MULTIPLICATION X}{thousands(bought['quantity'])} for "
                f"{thousands(bought['paid'])} {STONE}.\n"
                f"{thousands(bought['stones_left'])} {STONE} left.\n\n"
                if bought
                else "He is gone within the hour, and what he has next is "
                "anybody's guess.\n\n"
            )
            + (
                f"The cart turns over <t:{int(turns.timestamp())}:R>."
                if turns
                else ""
            ),
            colour=COLOUR_GOOD if bought else COLOUR_INFO,
        )

        if not rows:
            card.description = "The road is empty. Come back within the hour."
            await interaction.followup.send(embed=card)
            return

        lines = []
        for r in rows:
            mark = "\N{CROSS MARK}" if r["taken"] else f"`{r['slot_no']}`"
            qty = (
                f" \N{MULTIPLICATION X}{thousands(r['quantity'])}"
                if r["quantity"] > 1
                else ""
            )
            lines.append(
                f"{mark} {KINDS.get(r['kind'], '')} **{r['label']}**{qty}\n"
                f"\N{IDEOGRAPHIC SPACE}{thousands(r['price'])} {STONE}"
                + ("  *(yours already)*" if r["taken"] else "")
            )
        card.add_field(name="On the cart", value="\n".join(lines), inline=False)
        card.set_footer(
            text="**/market buy:<number>** \N{BULLET} one of each per cultivator "
            "per hour \N{BULLET} he does not haggle."
        )
        await interaction.followup.send(embed=card)


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Garden(bot))
