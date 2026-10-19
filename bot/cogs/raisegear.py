"""Raising a piece of equipment: /raisegear.

A piece's LEVEL was fixed the moment it was made. `forge` set it from the
realm of whoever swung the hammer, `fuse_equipment` raised RANK and refused
two pieces whose levels differed, and nothing else ever wrote it - so a
dropped piece, which mints at the column default of 1, was capped at a rank
ceiling of 2 for ever while a forged tier 8 reached 5.

The Vault's tier 10 landed in exactly that hole. 0567 and 0568 gave a piece a
meter and two ways to fill it; this is the counter it is filled at.

ONE COMMAND, not three. A piece is picked by autocomplete and then either fed
materials or fed another piece - which is two optional arguments rather than a
view with its own state to keep in step with the shelf. Naming only the piece
asks it how it is getting on.

Nothing here decides what anything is worth. `feed_equipment` and
`feed_equipment_gear` price the food and spend it; this reports what they did.
"""

import discord
import psycopg
from discord import app_commands
from discord.ext import commands

from bot import database as db
from bot.formatting import COLOUR_GOOD, COLOUR_INFO, embed, thousands
from bot.players import GameError, require_player

ANVIL = "\N{HAMMER AND WRENCH}"
UP = "\N{UPWARDS BLACK ARROW}"
DOT = "\N{BULLET}"


def refuse(exc: psycopg.errors.CheckViolation) -> GameError:
    return GameError(str(exc).splitlines()[0].capitalize() + ".")


async def piece_card(player_id: int, equipment_id: int, said: str | None = None):
    """What a piece is, and what the next rung of it costs."""
    row = await db.fetch_one(
        """
        SELECT e.equipment_id, e.name, e.slot, e.tier, e.rarity, e.level,
               e.rank, e.exp, e.quality,
               equipment_exp_needed(e.level, e.tier) AS toward,
               l.max_rank,
               EXISTS (SELECT 1 FROM player_equipped w
                       WHERE w.equipment_id = e.equipment_id) AS worn
        FROM player_equipment e
        LEFT JOIN equipment_level_scales l ON l.level = e.level
        WHERE e.equipment_id = %s AND e.owner_id = %s
        """,
        (equipment_id, player_id),
    )
    if row is None:
        raise GameError("You are not holding that piece.")

    card = embed(
        f"{ANVIL} {row['name']}",
        f"`T{row['tier']}` {row['rarity']} {DOT} {row['slot']} "
        f"{DOT} {row['quality']}" + (f"\n\n{said}" if said else ""),
        colour=COLOUR_GOOD if said else COLOUR_INFO,
    )

    if row["toward"] is None:
        card.add_field(
            name=f"Level {row['level']} \N{EM DASH} the top of its ladder",
            value=f"Rank {row['rank']} of {row['max_rank']} "
            "\N{BULLET} nothing more can be poured in.",
            inline=False,
        )
    else:
        # A bar for the step, not for the whole climb: each level is dearer
        # than the one before it, so one meter creeping across eighteen of
        # them would read as no progress at all for most of a piece's life.
        frac = min(1.0, float(row["exp"]) / float(row["toward"]))
        filled = int(round(frac * 20))
        card.add_field(
            name=f"Level {row['level']} {UP} {row['level'] + 1}",
            value=f"`{'█' * filled}{'░' * (20 - filled)}` {frac * 100:.0f}%\n"
            f"{thousands(row['exp'])} / {thousands(row['toward'])} work\n"
            f"Rank {row['rank']} of {row['max_rank']} at this level",
            inline=False,
        )

    if row["worn"]:
        card.set_footer(text="Worn \N{EM DASH} take it off before working on it.")
    else:
        card.set_footer(
            text="Feed it materials, or feed it another piece "
            "\N{EM DASH} deeper is worth more than more."
        )
    return card


class RaiseGear(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @app_commands.command(
        description="Pour materials or another piece into your gear to raise its level."
    )
    @app_commands.describe(
        piece="The piece being raised.",
        material="A material to pour in. Deeper materials are worth far more.",
        amount="How much of it.",
        sacrifice="A piece of equipment to destroy for the work in it.",
    )
    async def raisegear(
        self,
        interaction: discord.Interaction,
        piece: str,
        material: str | None = None,
        amount: int | None = None,
        sacrifice: str | None = None,
    ) -> None:
        player = await require_player(interaction.user)
        await interaction.response.defer()

        try:
            keeper = int(piece)
        except ValueError:
            raise GameError("Pick the piece from the list.") from None

        if material is not None and sacrifice is not None:
            raise GameError(
                "One thing at a time \N{EM DASH} materials or a piece, not both."
            )

        said = None

        if material is not None:
            if amount is None or amount <= 0:
                raise GameError("Say how much of it to pour in.")
            try:
                got = await db.fetch_one(
                    "SELECT * FROM feed_equipment(%s, %s, %s, %s)",
                    (player["player_id"], keeper, material, amount),
                )
            except psycopg.errors.CheckViolation as exc:
                raise refuse(exc) from exc
            said = self._tell(got, f"{thousands(amount)} poured in")

        elif sacrifice is not None:
            try:
                fodder = int(sacrifice)
            except ValueError:
                raise GameError("Pick the piece from the list.") from None
            try:
                got = await db.fetch_one(
                    "SELECT * FROM feed_equipment_gear(%s, %s, %s)",
                    (player["player_id"], keeper, fodder),
                )
            except psycopg.errors.CheckViolation as exc:
                raise refuse(exc) from exc
            said = self._tell(got, f"**{got['eaten']}** goes into the fire")

        await interaction.followup.send(
            embed=await piece_card(player["player_id"], keeper, said)
        )

    @staticmethod
    def _tell(got, opening: str) -> str:
        gained = f"{opening} \N{EM DASH} {thousands(got['exp_gained'])} work."
        if got["level_after"] > got["level_before"]:
            return (
                f"{gained}\n\n{UP} **Level {got['level_before']} "
                f"\N{RIGHTWARDS ARROW} {got['level_after']}.**"
            )
        return gained

    # -----------------------------------------------------------------------

    @raisegear.autocomplete("piece")
    async def piece_autocomplete(
        self, interaction: discord.Interaction, current: str
    ) -> list[app_commands.Choice[str]]:
        player = await db.fetch_one(
            "SELECT player_id FROM players WHERE discord_id = %s", (interaction.user.id,)
        )
        if player is None:
            return []
        rows = await db.fetch_all(
            """
            SELECT e.equipment_id, e.name, e.tier, e.level
            FROM player_equipment e
            WHERE e.owner_id = %s AND e.name ILIKE %s
              -- Worn gear is snapshotted into fights, so the anvil refuses it
              -- anyway. Leaving it out of the list beats refusing it after.
              AND NOT EXISTS (SELECT 1 FROM player_equipped w
                              WHERE w.equipment_id = e.equipment_id)
            ORDER BY e.tier DESC, e.level DESC, e.name
            LIMIT 25
            """,
            (player["player_id"], f"%{current}%"),
        )
        return [
            app_commands.Choice(
                name=f"{r['name']} (T{r['tier']} \N{BULLET} level {r['level']})"[:100],
                value=str(r["equipment_id"]),
            )
            for r in rows
        ]

    @raisegear.autocomplete("sacrifice")
    async def sacrifice_autocomplete(
        self, interaction: discord.Interaction, current: str
    ) -> list[app_commands.Choice[str]]:
        return await self.piece_autocomplete(interaction, current)

    @raisegear.autocomplete("material")
    async def material_autocomplete(
        self, interaction: discord.Interaction, current: str
    ) -> list[app_commands.Choice[str]]:
        player = await db.fetch_one(
            "SELECT player_id FROM players WHERE discord_id = %s", (interaction.user.id,)
        )
        if player is None:
            return []
        rows = await db.fetch_all(
            """
            SELECT m.code, m.name, m.tier, pm.quantity,
                   equipment_food_value(m.code, 1) AS each
            FROM player_materials pm
            JOIN materials m ON m.code = pm.material_code
            WHERE pm.player_id = %s AND pm.quantity > 0 AND m.name ILIKE %s
              -- The same rule `equipment_food_value` applies: a tier, or a
              -- beast part. Spirit Stone has neither and is held in the
              -- quadrillions, so it is not food.
              AND (m.tier IS NOT NULL OR m.category = 'beast')
            ORDER BY equipment_food_value(m.code, 1) DESC, m.name
            LIMIT 25
            """,
            (player["player_id"], f"%{current}%"),
        )
        return [
            app_commands.Choice(
                name=(
                    f"{r['name']} \N{BULLET} {thousands(r['quantity'])} held "
                    f"\N{BULLET} {thousands(r['each'])} work each"
                )[:100],
                value=r["code"],
            )
            for r in rows
        ]


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(RaiseGear(bot))
