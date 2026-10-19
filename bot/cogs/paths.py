"""The Path system: /paths, /path, /tiers."""

import discord
from discord import app_commands
from discord.ext import commands

from bot import database as db
from bot.formatting import (
    COLOUR_DEFAULT,
    COLOUR_INFO,
    embed,
    interaction_label,
    percent,
    thousands,
)
from bot.pathpicker import PathPicker, fetch_paths
from bot.players import fetch_player


class Paths(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @app_commands.command(description="Every Path, by category.")
    @app_commands.describe(category="Narrow to one category.")
    @app_commands.choices(
        category=[
            app_commands.Choice(name="Combat", value="combat"),
            app_commands.Choice(name="Special", value="special"),
            app_commands.Choice(name="Exotic", value="exotic"),
        ]
    )
    async def paths(
        self,
        interaction: discord.Interaction,
        category: app_commands.Choice[str] | None = None,
    ) -> None:
        rows = await db.fetch_all(
            """
            SELECT code, name, category, uses_matchups, description, emoji
            FROM paths
            WHERE %s::text IS NULL OR category = %s
            ORDER BY sort_order
            """,
            (category.value if category else None, category.value if category else None),
        )

        card = embed(
            "The Paths",
            "The chart is directed: `fire -> wood` being an advantage says "
            "nothing about `wood -> fire`. Read **/path** for one Path's own rows.",
            colour=COLOUR_DEFAULT,
        )

        for group in ("combat", "special", "exotic"):
            members = [r for r in rows if r["category"] == group]
            if not members:
                continue
            card.add_field(
                name=f"{group.title()} ({len(members)})",
                value=" ".join(
                    f"{r['emoji']} {r['name'].replace(' Path', '')}" for r in members
                ),
                inline=False,
            )

        exotic = [r for r in rows if not r["uses_matchups"]]
        if exotic:
            card.set_footer(
                text="Exotic Paths sit outside the matchup chart entirely — "
                "their value comes from unique mechanics instead."
            )
        await interaction.response.send_message(embed=card)

    # -----------------------------------------------------------------------

    @app_commands.command(
        description="Read a Path: what it beats, what resists it, and your attainment."
    )
    async def path(self, interaction: discord.Interaction) -> None:
        """Pick from buttons, then keep browsing.

        The picker stays attached to the message after a pick, so comparing
        Fire against Water is two presses rather than two commands.
        """
        paths = await fetch_paths()
        player = await fetch_player(interaction.user.id)
        view = PathDetailPicker(
            interaction.user, paths, player["player_id"] if player else None
        )
        await interaction.response.send_message(embed=view.prompt(), view=view)

    # -----------------------------------------------------------------------

    @app_commands.command(description="The attainment ladder, Uninitiated to Supreme Grandmaster.")
    async def tiers(self, interaction: discord.Interaction) -> None:
        rows = await db.fetch_all(
            """
            SELECT tier, name, damage_bonus, resistance_bonus, insight_required
            FROM attainment_tiers
            ORDER BY tier
            """
        )
        lines = [
            f"`{row['tier']:>2}` **{row['name']}** — "
            f"{percent(row['damage_bonus'])} damage, "
            f"{percent(row['resistance_bonus'])} resistance  ·  "
            f"{thousands(row['insight_required'])} insight"
            for row in rows
        ]
        card = embed(
            "Path attainment",
            "\n".join(lines),
            colour=COLOUR_INFO,
        )
        card.set_footer(
            text="Tier 0 is the absence of a row, not a stored zero. "
            "Insight requirements above Ordinary are placeholder."
        )
        await interaction.response.send_message(embed=card)


# ---------------------------------------------------------------------------
# One Path in detail
# ---------------------------------------------------------------------------


async def render_path_detail(row: dict, player_id: int | None) -> discord.Embed:
    """Both directions of the chart, plus this player's standing in it.

    Read from the attacker's side each time. Neutral is an absent row, so
    anything not listed here is neutral - that is the whole reason the chart
    is 108 rows rather than 784.
    """
    attacking = await db.fetch_all(
        """
        SELECT d.name, m.interaction, i.damage_modifier
        FROM path_matchups m
        JOIN paths d ON d.code = m.defender_path
        JOIN matchup_interactions i ON i.code = m.interaction
        WHERE m.attacker_path = %s
        ORDER BY i.damage_modifier DESC, d.sort_order
        """,
        (row["code"],),
    )
    defending = await db.fetch_all(
        """
        SELECT a.name, m.interaction, i.damage_modifier
        FROM path_matchups m
        JOIN paths a ON a.code = m.attacker_path
        JOIN matchup_interactions i ON i.code = m.interaction
        WHERE m.defender_path = %s
        ORDER BY i.damage_modifier DESC, a.sort_order
        """,
        (row["code"],),
    )

    card = embed(
        f"{row['emoji']} {row['name']}", row["description"], colour=COLOUR_DEFAULT
    )

    if not row["uses_matchups"]:
        card.add_field(
            name="Outside the chart",
            value=(
                "An exotic Path. It takes no part in the matchup chart in "
                "either direction — its value is in mechanics of its own."
            ),
            inline=False,
        )
    else:
        card.add_field(
            name="Attacking with it",
            value=_matchup_lines(attacking, "Neutral into everything so far."),
            inline=False,
        )
        card.add_field(
            name="Defending against it",
            value=_matchup_lines(defending, "Nothing has an edge on it."),
            inline=False,
        )

    if player_id is not None:
        mine = await db.fetch_one(
            """
            SELECT a.insight, a.dao_marks, a.seconds_trained,
                   t.name AS tier_name, t.tier, t.damage_bonus,
                   next.name AS next_name, next.insight_required
            FROM player_path_attainment a
            JOIN attainment_tiers t ON t.tier = a.tier
            LEFT JOIN attainment_tiers next ON next.tier = a.tier + 1
            WHERE a.player_id = %s AND a.path_code = %s
            """,
            (player_id, row["code"]),
        )
        if mine is None:
            card.add_field(
                name="Your attainment",
                value="Uninitiated. **/focus** on this Path to begin.",
                inline=False,
            )
        else:
            toward = ""
            if mine["next_name"]:
                remaining = mine["insight_required"] - mine["insight"]
                toward = f"\n{thousands(remaining)} insight to {mine['next_name']}"
            card.add_field(
                name="Your attainment",
                value=(
                    f"**{mine['tier_name']}** (tier {mine['tier']}) — "
                    f"{percent(mine['damage_bonus'])} damage\n"
                    f"{thousands(mine['insight'])} insight  ·  "
                    f"{mine['dao_marks']} Dao Marks{toward}"
                ),
                inline=False,
            )
    return card


class PathDetailPicker(PathPicker):
    prompt_title = "Read a Path"
    prompt_body = (
        "Press one to see what it beats, what resists it, and where you stand "
        "in it. The buttons stay, so you can compare without running the "
        "command again."
    )

    def __init__(
        self, user: discord.abc.User, paths: list[dict], player_id: int | None
    ) -> None:
        self.player_id = player_id
        super().__init__(user, paths)

    async def on_pick(self, path: dict) -> discord.Embed:
        return await render_path_detail(path, self.player_id)


def _matchup_lines(rows: list[dict], empty: str) -> str:
    if not rows:
        return empty
    grouped: dict[str, list[str]] = {}
    for row in rows:
        grouped.setdefault(row["interaction"], []).append(
            row["name"].replace(" Path", "")
        )
    return "\n".join(
        f"{interaction_label(code)} — {', '.join(names)}"
        for code, names in grouped.items()
    )


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Paths(bot))
