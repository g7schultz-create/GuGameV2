"""The farm: /farm look, /farm place, /farm butcher, /farm take.

There were 1405 unhatched eggs in the live world when this was written and one
thing to do with them: `hatch_egg`, which makes a pet, of which exactly one may
walk at your heel. The other 1404 sat on a shelf.

A pen is the second use. An egg goes in the ground, immortal essence goes in
with it, and when its hours have passed it is either butchered for beast
materials or taken out as a beast - and a thing that was RAISED comes out a rung
above one that was cracked.

A GROUP, not four commands. Discord allows a hundred top-level slash commands
and the bot is at the ceiling; `/gu` gave up a slot by becoming a group of its
own, and this spends it. Four subcommands for one slot.

NOTHING TICKS. A pen is ready when `ready_at` has passed and the command that
reads it is what notices - the same shape the garden uses.
"""

import discord
import psycopg
from discord import app_commands
from discord.ext import commands

from bot import database as db
from bot.formatting import COLOUR_GOOD, COLOUR_INFO, embed, thousands
from bot.players import GameError, require_player

PEN = "\N{PAW PRINTS}"
EGG = "\N{EGG}"
SPARKLE = "\N{SPARKLES}"
DOT = "\N{BULLET}"
CLOCK = "\N{HOURGLASS WITH FLOWING SAND}"
DONE = "\N{WHITE HEAVY CHECK MARK}"
KNIFE = "\N{HOCHO}"   # the knife emoji; KITCHEN KNIFE is not its name
BARE = "\N{LARGE BROWN SQUARE}"


def refuse(exc: psycopg.errors.CheckViolation) -> GameError:
    return GameError(str(exc).splitlines()[0].capitalize() + ".")


async def farm_card(player_id: int, who: str, said: str | None = None):
    pens = await db.fetch_value("SELECT farm_pens(%s)", (player_id,))
    rows = await db.fetch_all(
        """
        SELECT f.pen_no, f.tier, f.rarity, f.ready_at, f.essence_paid,
               f.ready_at <= now() AS grown,
               cs.name AS species_name,
               q.word, q.emoji,
               material_name(f.essence_code) AS essence_name
        FROM player_farm f
        JOIN creature_species cs ON cs.species_id = f.species_id
        LEFT JOIN egg_qualities q ON q.rarity = f.rarity
        WHERE f.player_id = %s
        ORDER BY f.pen_no
        """,
        (player_id,),
    )

    card = embed(
        f"{PEN} The farm at {who}'s dwelling",
        said or f"**{len(rows)} of {pens}** pens are full.",
        colour=COLOUR_GOOD if said else COLOUR_INFO,
    )

    if pens <= 0:
        card.description = (
            "You have nowhere to keep a beast. A dwelling comes first "
            "\N{EM DASH} **/dwelling**."
        )
        return card

    held = {r["pen_no"]: r for r in rows}
    lines = []
    for n in range(1, int(pens) + 1):
        r = held.get(n)
        if r is None:
            lines.append(f"`{n}` {BARE} *an empty pen*")
        elif r["grown"]:
            lines.append(
                f"`{n}` {DONE} {r['emoji'] or EGG} **{r['word'] or ''} "
                f"{r['species_name']}** {DOT} tier {r['tier']} {DOT} **grown**"
            )
        else:
            lines.append(
                f"`{n}` {CLOCK} {r['emoji'] or EGG} **{r['word'] or ''} "
                f"{r['species_name']}** {DOT} tier {r['tier']} {DOT} "
                f"<t:{int(r['ready_at'].timestamp())}:R>"
            )
    card.add_field(name="Pens", value="\n".join(lines), inline=False)
    card.set_footer(
        text="**/farm place** to put an egg in \N{BULLET} **/farm butcher** for "
        "the materials \N{BULLET} **/farm take** to keep it \N{EM DASH} raised, it "
        "walks out a Juvenile."
    )
    return card


class Farm(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    farm = app_commands.Group(
        name="farm", description="The pens at your dwelling, and the eggs in them."
    )

    # -----------------------------------------------------------------------

    @farm.command(name="look", description="What is in the pens.")
    async def farm_look(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        await interaction.response.defer()
        await interaction.followup.send(
            embed=await farm_card(player["player_id"], player["discord_name"])
        )

    # -----------------------------------------------------------------------

    @farm.command(name="place", description="Put an egg in a pen to raise it.")
    @app_commands.describe(
        egg="Which egg to raise. Deeper eggs take longer and eat more essence.",
        essence="The immortal essence to raise it on. A deeper one goes further.",
    )
    async def farm_place(
        self, interaction: discord.Interaction, egg: str, essence: str
    ) -> None:
        player = await require_player(interaction.user)
        await interaction.response.defer()
        try:
            got = await db.fetch_one(
                "SELECT * FROM farm_place(%s, %s, %s)",
                (player["player_id"], int(egg), essence),
            )
        except (ValueError, TypeError):
            raise GameError("Pick the egg from the list.") from None
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        said = (
            f"{got['beast_name']} goes into pen `{got['pen_no']}`, grown "
            f"<t:{int(got['ready_at'].timestamp())}:R>.\n\n"
            f"{SPARKLE} **{thousands(got['essence_spent'])}** "
            f"{DOT} {got['essence_name']}\n"
            f"{got['pens_free']} pen(s) still empty."
        )
        await interaction.followup.send(
            embed=await farm_card(player["player_id"], player["discord_name"], said)
        )

    @farm_place.autocomplete("egg")
    async def egg_autocomplete(
        self, interaction: discord.Interaction, current: str
    ) -> list[app_commands.Choice[str]]:
        """Deepest first, with the hours and the essence each one will want.

        An egg shelf of 245 is not something to scroll; what decides the choice
        is the bill, so the bill is on the line.
        """
        player = await db.fetch_one(
            "SELECT player_id FROM players WHERE discord_id = %s",
            (interaction.user.id,),
        )
        if player is None:
            return []
        rows = await db.fetch_all(
            """
            SELECT e.egg_id, e.tier, cs.name, q.word,
                   farm_essence_needed(e.tier) AS wants,
                   EXTRACT(epoch FROM farm_ready_in(e.tier)) / 3600 AS hours
            FROM player_beast_eggs e
            JOIN creature_species cs ON cs.species_id = e.species_id
            LEFT JOIN egg_qualities q ON q.rarity = e.rarity
            WHERE e.owner_id = %s AND e.hatched_at IS NULL
              AND cs.name ILIKE %s
            ORDER BY e.tier DESC, cs.name
            LIMIT 25
            """,
            (player["player_id"], f"%{current}%"),
        )
        return [
            app_commands.Choice(
                name=(
                    f"{r['word'] or ''} {r['name']} \N{BULLET} tier {r['tier']} "
                    f"\N{BULLET} {int(r['hours'])}h \N{BULLET} "
                    f"{thousands(int(r['wants']))} essence"
                ).strip()[:100],
                value=str(r["egg_id"]),
            )
            for r in rows
        ]

    @farm_place.autocomplete("essence")
    async def essence_autocomplete(
        self, interaction: discord.Interaction, current: str
    ) -> list[app_commands.Choice[str]]:
        player = await db.fetch_one(
            "SELECT player_id FROM players WHERE discord_id = %s",
            (interaction.user.id,),
        )
        if player is None:
            return []
        # THE BILL, IF THE EGG IS ALREADY CHOSEN. Discord hands an autocomplete
        # the options filled in so far, so the tier - and therefore the price -
        # is usually known by the time this list is built. `farm_place` refuses
        # an essence worth more per unit than the whole pen (0584), and a
        # refusal the player could not see coming is still a bad screen.
        chosen = getattr(interaction.namespace, "egg", None)
        bill = None
        if chosen:
            try:
                bill = await db.fetch_value(
                    """
                    SELECT farm_essence_needed(e.tier)
                    FROM player_beast_eggs e
                    WHERE e.egg_id = %s AND e.owner_id = %s
                    """,
                    (int(chosen), player["player_id"]),
                )
            except (ValueError, TypeError):
                bill = None

        rows = await db.fetch_all(
            """
            SELECT m.code, m.name, pm.quantity, ie.unit_value,
                   CASE WHEN %(bill)s::numeric IS NULL THEN NULL
                        ELSE GREATEST(1, ceil(%(bill)s::numeric / ie.unit_value))
                   END AS spends
            FROM player_materials pm
            JOIN materials m ON m.code = pm.material_code
            JOIN immortal_essences ie ON ie.material_code = m.code
            WHERE pm.player_id = %(who)s AND pm.quantity > 0
              AND m.name ILIKE %(like)s
              -- Nothing the pen would refuse, and nothing there is too little
              -- of to cover it.
              AND (%(bill)s::numeric IS NULL OR ie.unit_value <= %(bill)s::numeric)
              AND (%(bill)s::numeric IS NULL
                   OR pm.quantity >= GREATEST(1, ceil(%(bill)s::numeric / ie.unit_value)))
            ORDER BY ie.unit_value DESC
            LIMIT 25
            """,
            {
                "who": player["player_id"],
                "like": f"%{current}%",
                "bill": bill,
            },
        )

        out = []
        for r in rows:
            if r["spends"] is None:
                tail = f"worth {thousands(r['unit_value'])} each \N{EM DASH} pick the egg first"
            else:
                tail = f"spends {thousands(int(r['spends']))} of them"
            out.append(
                app_commands.Choice(
                    name=(
                        f"{r['name']} \N{BULLET} {thousands(r['quantity'])} held "
                        f"\N{BULLET} {tail}"
                    )[:100],
                    value=r["code"],
                )
            )
        return out

    # -----------------------------------------------------------------------

    @farm.command(
        name="butcher", description="Butcher a grown beast for its materials."
    )
    @app_commands.describe(pen="Which pen to butcher.")
    async def farm_butcher(self, interaction: discord.Interaction, pen: int) -> None:
        player = await require_player(interaction.user)
        await interaction.response.defer()
        try:
            rows = await db.fetch_all(
                "SELECT * FROM farm_butcher(%s, %s::smallint)",
                (player["player_id"], pen),
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        if not rows:
            raise GameError("That one carried nothing worth taking.")

        said = f"{KNIFE} Pen `{pen}`, and what came off it:\n\n" + "\n".join(
            f"{r['emoji'] or ''} **{r['material_name']}** "
            f"\N{MULTIPLICATION X}{thousands(r['quantity'])}"
            for r in rows
        )
        await interaction.followup.send(
            embed=await farm_card(player["player_id"], player["discord_name"], said)
        )

    # -----------------------------------------------------------------------

    @farm.command(name="take", description="Take a grown beast out of its pen alive.")
    @app_commands.describe(pen="Which pen to empty.")
    async def farm_take(self, interaction: discord.Interaction, pen: int) -> None:
        player = await require_player(interaction.user)
        await interaction.response.defer()
        try:
            got = await db.fetch_one(
                "SELECT * FROM farm_hatch(%s, %s::smallint)",
                (player["player_id"], pen),
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        said = (
            f"**{got['beast_name']}** walks out of pen `{pen}` "
            f"\N{EM DASH} a **{got['stage']}**, because it was raised rather "
            # /pet for BOTH, because feeding is a button on that screen and
            # never was a command of its own. A card that names /feed is the
            # same broken promise the tutorial check exists to catch.
            f"than cracked.\n\n**/pet** to see it, and to feed it the rest of "
            f"the way up."
        )
        await interaction.followup.send(
            embed=await farm_card(player["player_id"], player["discord_name"], said)
        )


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Farm(bot))
