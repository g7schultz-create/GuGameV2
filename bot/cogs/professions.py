"""Crafts: /professions.

Five crafts across two tables — manual refinement predates the professions
table and 0038 left it there rather than rewrite a working `refine()`. The
`skills` view closes that seam, so this screen does not have to know about it,
and mining and blacksmithing arrived here in 0063 and 0065 as two INSERTs and
no change to this file beyond an icon.

A craft nobody has begun is listed too, at level one with nothing spent. A
screen that hides what you have not started cannot tell you what there is to
start.
"""

import discord
from discord import app_commands
from discord.ext import commands

from bot import database as db
from bot.formatting import COLOUR_INFO, bar, embed, percent, thousands
from bot.players import require_player, settle_passive

ICONS = {
    "refinement": "\N{SCROLL}",
    "gu_refining": "\N{BUG}",
    "alchemy": "\N{ALEMBIC}",
    "mining": "\N{PICK}",
    "blacksmithing": "\N{HAMMER}",
    "foraging": "\N{HERB}",
    "exploring": "\N{COMPASS}",
}


async def fetch_skills(player_id: int) -> list[dict]:
    return await db.fetch_all(
        """
        SELECT s.code, s.name, s.description,
               round(s.exp_per_level)::bigint AS exp_per_level,
               COALESCE(ps.level, 1) AS level,
               COALESCE(ps.exp, 0) AS exp,
               COALESCE(ps.into_level, 0) AS into_level,
               COALESCE(ps.to_next, round(s.exp_per_level))::bigint AS to_next,
               COALESCE(ps.successes, 0) AS successes,
               COALESCE(ps.failures, 0) AS failures,
               skill_buys(s.code, COALESCE(ps.level, 1)::smallint) AS buys,
               skill_next_step(s.code, COALESCE(ps.level, 1)::smallint) AS next_at
        FROM skills s
        LEFT JOIN player_skills ps
               ON ps.skill = s.code AND ps.player_id = %s
        ORDER BY s.sort_order, s.name
        """,
        (player_id,),
    )


def render_skills(rows: list[dict], display_name: str) -> discord.Embed:
    started = [r for r in rows if r["exp"]]

    card = embed(
        f"\N{HAMMER AND PICK} {display_name}'s crafts",
        f"{len(started)} of {len(rows)} begun. Every one of them levels on the "
        "attempt, not on the success — a spoiled cauldron still teaches the "
        "shape of the mistake.",
        colour=COLOUR_INFO,
    )

    for row in rows:
        span = row["exp_per_level"]
        into = row["into_level"]
        attempts = row["successes"] + row["failures"]

        lines = [
            f"{bar(into, span, width=16)}  "
            f"{percent(into / span if span else 0, signed=False)}",
            f"**{thousands(row['to_next'])}** EXP to level {row['level'] + 1} "
            f"\N{BULLET} {thousands(row['exp'])} earned in all",
        ]
        if row["buys"]:
            lines.append(f"Currently: {row['buys']}")
            # A long climb that does not say how long reads as an empty one.
            # Two cultivators sat a hundred levels past their last rung
            # because nothing ever told them they had finished.
            if row["next_at"]:
                lines.append(
                    f"Next at level **{row['next_at']}** "
                    f"({row['next_at'] - row['level']} to go)"
                )
            else:
                lines.append("*This craft is as far along as it goes.*")
        if attempts:
            lines.append(
                f"{row['successes']} made, {row['failures']} spoiled "
                f"\N{BULLET} {percent(row['successes'] / attempts, signed=False)} hold together"
            )
        else:
            lines.append(f"*{row['description']}*")

        card.add_field(
            name=f"{ICONS.get(row['code'], '')} {row['name']} \N{BULLET} level {row['level']}",
            value="\n".join(lines),
            inline=False,
        )

    card.set_footer(
        text="/refine, /refinegu, /alchemy, /mine and /forge. Levels come from "
        "doing the work; there is nothing to spend and nothing to choose."
    )
    return card


class Professions(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @app_commands.command(
        description="Your crafts, their levels, and how far the next one is."
    )
    async def professions(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])

        rows = await fetch_skills(player["player_id"])
        await interaction.response.send_message(
            embed=render_skills(rows, interaction.user.display_name)
        )


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Professions(bot))
