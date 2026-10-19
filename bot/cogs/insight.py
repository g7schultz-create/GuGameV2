"""Path attainment: /insight.

The counterpart to /professions. A craft levels from doing the work and is
worth an unlock; a Path accumulates insight and is worth a number in the damage
pipeline — so this screen is about what each Path is currently paying you,
not just how far along it is.

Nothing here is computed in this file. `player_path_standing` returns every
Path from one cultivator's side, and the resistance column it carries is the
same function `compute_creature_damage` consults when something hits you. A
screen that added up the bonuses itself would be a second implementation of
the pipeline, and the first thing to diverge from it.

GROUPED BY TIER, ONE LINE EACH. This screen used to spend a full-width field
on every Path: a bar, a total, the damage bonus, the learn rate and the hours,
five lines apiece. Twelve of those is fifty-odd lines of scroll, and it could
still only fit twelve of clearwest's twenty-five begun Paths.

Almost all of it was the same sentence repeated. `damage_bonus` and
`resistance` are functions of the TIER, not the Path - every Quasi-Master Path
pays +6%, so "+6% damage with X techniques" appeared five times in a row with
only the name changing. Said once in the group heading it costs one line
instead of five, and the same goes for which tier comes next.

What is left on a Path's own line is what actually differs between Paths: how
far along it is, how much is left, and the few tags that are not also true of
its neighbours. All twenty-five now fit, in three fields instead of thirteen.
"""

import discord
from discord import app_commands
from discord.ext import commands

from bot import database as db
from bot.formatting import COLOUR_INFO, bar, embed, percent, thousands
from bot.players import require_player, settle_passive

# Discord's ceiling on one field. Lines are chunked under it rather than
# truncated - a tier holding nineteen Paths is exactly the case the old screen
# could not show.
FIELD = 1024

# A learn rate is a multiplier around 1, and most of a cultivator's Paths sit
# at the same one. Only the ones standing out from their own neighbours earn a
# tag; a rate repeated on every line is decoration.
NOTABLE = 0.05


def rung(tier: int) -> str:
    """A glyph that grows with the tier, so the groups read as a ladder."""
    if tier >= 8:
        return "\N{BLACK FOUR POINTED STAR}"
    if tier >= 6:
        return "\N{BLACK STAR}"
    if tier >= 4:
        return "\N{BLACK DIAMOND}"
    if tier == 3:
        return "\N{LOZENGE}"
    if tier == 2:
        return "\N{WHITE DIAMOND}"
    return "\N{WHITE SMALL SQUARE}"


async def fetch_standing(player_id: int) -> list[dict]:
    return await db.fetch_all(
        "SELECT * FROM player_path_standing(%s)", (player_id,)
    )


def pays(row: dict) -> str:
    """What a tier pays, said once for the whole group.

    Only non-zero entries. A "+0% resistance" beside a real bonus reads as one
    that has stopped working rather than one not yet earned, and /tiers is
    where the whole ladder is.
    """
    parts = []
    if row["damage_bonus"]:
        parts.append(f"{percent(row['damage_bonus'])} damage")
    if row["resistance"]:
        parts.append(f"{percent(row['resistance'])} resistance")
    return " \N{BULLET} ".join(parts) if parts else "pays nothing yet"


def path_line(row: dict, common_rate: float) -> str:
    """One Path, one line: how far, how much is left, what is unusual."""
    name = row["path_name"].replace(" Path", "")
    head = f"{row['emoji']} **{name}**"

    if row["next_tier_at"] is None:
        body = f"{thousands(row['insight'])} \N{EM DASH} the ladder ends here"
    else:
        span = row["next_tier_at"] - row["tier_floor"]
        into = row["insight"] - row["tier_floor"]
        body = (
            f"{bar(into, span, width=10)} "
            f"{percent(into / span if span else 1, signed=False)} "
            f"\N{BULLET} {thousands(row['next_tier_at'] - row['insight'])} to go"
        )

    tags = []
    if row["focused"]:
        tags.append("\N{DIRECT HIT}")
    rate = float(row["learn_rate"] or 1)
    if abs(rate - common_rate) >= NOTABLE:
        # An arrow rather than a book: the Wisdom Path's own emoji IS a book,
        # so "Wisdom 120%" came out as two of them in a row.
        arrow = "\N{UPWARDS ARROW}" if rate > common_rate else "\N{DOWNWARDS ARROW}"
        tags.append(f"{arrow}{percent(rate, signed=False)}")
    if row["dao_marks"]:
        tags.append(f"\N{SPARKLES}{row['dao_marks']}")
    # Rounded, so a Path with six minutes against it does not advertise "0h".
    hours = float(row["hours_trained"] or 0)
    if round(hours) >= 1:
        tags.append(f"{hours:,.0f}h")

    return f"{head} {body}" + (f" {' '.join(tags)}" if tags else "")


def chunks(lines: list[str]) -> list[str]:
    """Field-sized blocks. Nineteen Expert Paths do not fit in one."""
    out: list[str] = []
    for line in lines:
        if out and len(out[-1]) + len(line) + 1 <= FIELD:
            out[-1] += "\n" + line
        else:
            out.append(line)
    return out


def render_standing(rows: list[dict], display_name: str) -> discord.Embed:
    begun = [r for r in rows if r["insight"]]
    untouched = [r for r in rows if not r["insight"]]

    card = embed(
        f"\N{LOTUS} {display_name}'s insight",
        f"**{len(begun)}** of {len(rows)} Paths begun. Insight comes from "
        "**/focus**, from **/meditate**, and from fighting things that use it.",
        colour=COLOUR_INFO,
    )

    # The rate most of this cultivator's Paths share, so a tag marks the ones
    # that differ from IT rather than every Path that differs from 1.0.
    rates = [float(r["learn_rate"] or 1) for r in begun]
    common = max(set(rates), key=rates.count) if rates else 1.0

    tiers: dict[int, list[dict]] = {}
    for row in begun:
        tiers.setdefault(row["tier"], []).append(row)

    for tier in sorted(tiers, reverse=True):
        group = sorted(tiers[tier], key=lambda r: -r["insight"])
        first = group[0]
        heading = f"{rung(tier)} {first['tier_name']} \N{BULLET} {pays(first)}"
        if first["next_tier_name"]:
            heading += f" \N{RIGHTWARDS ARROW} {first['next_tier_name']}"

        blocks = chunks([path_line(r, common) for r in group])
        for index, block in enumerate(blocks):
            card.add_field(
                name=heading if index == 0
                else f"{rung(tier)} \N{HORIZONTAL ELLIPSIS}",
                value=block,
                inline=False,
            )

    # Where the untouched Paths are worth starting. Race, Root and Physique
    # already decided this; nothing else in the bot says it out loud.
    favoured = [r for r in untouched if float(r["learn_rate"] or 1) > 1.0]
    if favoured:
        # Grouped by rate, and the rate said once. Eight Paths each labelled
        # "110%" is a ranking that does not rank anything.
        best = max(float(r["learn_rate"]) for r in favoured)
        peers = [r for r in favoured if float(r["learn_rate"]) == best]
        shown = peers[:10]
        card.add_field(
            name=f"\N{SEEDLING} Untouched, and quickest to start \N{BULLET} "
            f"{percent(best, signed=False)} insight",
            value=", ".join(
                f"{r['emoji']} **{r['path_name'].replace(' Path', '')}**"
                for r in shown
            )
            + (f" \N{HORIZONTAL ELLIPSIS} and {len(peers) - len(shown)} more"
               if len(peers) > len(shown) else "")
            + "\n*Your Race, Root and Physique picked these. **/focus** aims "
            "at one.*",
            inline=False,
        )
    elif untouched:
        card.add_field(
            name="\N{SEEDLING} The rest",
            value=f"**{len(untouched)}** Paths untouched, all at the same rate "
            "\N{EM DASH} nothing you were born with favours one over another. "
            "**/paths** lists them.",
            inline=False,
        )

    card.set_footer(
        text="\N{DIRECT HIT} focused  \N{UPWARDS ARROW}\N{DOWNWARDS ARROW} learn "
        "rate against your usual  \N{SPARKLES} Dao marks  \N{BULLET}  /tiers is "
        "the ladder, /path reads one."
    )
    return card


class Insight(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @app_commands.command(
        description="Your Path attainment and what each tier is paying you."
    )
    async def insight(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])

        rows = await fetch_standing(player["player_id"])
        await interaction.response.send_message(
            embed=render_standing(rows, interaction.user.display_name)
        )


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Insight(bot))
