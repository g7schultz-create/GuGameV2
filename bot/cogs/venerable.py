"""The realm above the realms: /dao, /venerable, /ascend, /paydebt.

Eighteen realms are a ladder of cultivation. The nineteenth is not. A Venerable
does not advance by holding more qi - they advance by UNDERSTANDING the thing
they already are, and the thing they already are is read off what they have
actually done: the Path they walked, the body they forged, the craft they
levelled, the worm they never took off.

    /dao        the Dao read off your own record, and the aspects it is made of
    /venerable  understanding accrued since the stamp, and the rung it reaches
    /ascend     the crossing itself, once the Sovereign Calamity is survived
    /paydebt    settle what a failed sky left owed

A DAO IS DERIVED UNTIL IT IS STAMPED, AND FIXED AFTER. Before ascension it is
recomputed on every read, so training a different Path changes what it would
say. Ascension freezes it and takes a baseline, and from then on understanding
is movement away from that baseline. The freeze is the whole mechanic: without
it a cultivator could re-weight their own Dao and drag the ladder along behind
them.

AND THE BAR FILLS FROM THE RUNG HELD, not from zero, so each of the nine rungs
starts it over. One bar creeping to full across all nine would tell a Venerable
Rank 2 cultivator that they are a tenth of the way through the realm, which is
true and useless.
"""

import logging

import discord
import psycopg
from discord import app_commands
from discord.ext import commands

from bot import database as db
from bot.formatting import (
    COLOUR_GOOD,
    COLOUR_INFO,
    embed,
    thousands,
)
from bot.players import GameError, require_player, settle_passive

log = logging.getLogger("gu.venerable")

DOT = "\N{BULLET}"
SCROLL = "\N{SCROLL}"

# What each axis of a Dao is, in the player's words rather than the column's.
KINDS = {
    "path": "Path walked",
    "body": "Body forged",
    "craft": "Craft levelled",
    "root": "Root born with",
    "destiny": "Destiny taken",
    "gu": "Worm kept",
}


def refuse(exc: psycopg.errors.CheckViolation) -> GameError:
    """The schema's own refusal, which is already written for a player.

    Every gate in this realm raises `check_violation` with the sentence it
    wants shown, so a cog that reworded them would be a second copy of the
    rule to keep in step.
    """
    return GameError(str(exc).splitlines()[0].capitalize())


async def dao_card(player_id: int, who: str) -> discord.Embed:
    """The Dao and its aspects, stamped or not.

    One function because /dao and /ascend both have to show it and they must
    not disagree about what it says.
    """
    row = await db.fetch_one(
        """
        SELECT d.dao_name AS stamped, d.stamped_at,
               dao_name_of(%(p)s) AS live
        FROM (SELECT 1) _
        LEFT JOIN player_dao d ON d.player_id = %(p)s
        """,
        {"p": player_id},
    )
    name = row["stamped"] or row["live"]
    if name is None:
        raise GameError(
            "You have walked no Path, forged no body and kept no worm, so "
            "there is nothing for a Dao to be read off yet. Everything you do "
            "from here is what it will say \N{EM DASH} **/paths** to begin."
        )

    # LEFT JOIN on purpose: `dao_deed_rates` has a row only for the kinds
    # that record a deed, so an aspect matching nothing is an aspect that
    # can never earn a point. The absence is the answer.
    aspects = await db.fetch_all(
        """
        SELECT a.source_kind, a.label, a.weight, a.feeds,
               r.unit_name,
               (r.source_kind IS NOT NULL) AS accrues,
               -- What a point costs THIS cultivator, which is what the
               -- weight actually means once you have to go and do it.
               CASE WHEN r.source_kind IS NOT NULL AND a.weight > 0
                    THEN ceil(r.units_per_point / a.weight)
               END AS per_point
        FROM dao_aspects(%s) a
        LEFT JOIN dao_deed_rates r ON r.source_kind = a.source_kind
        ORDER BY a.ordinal
        """,
        (player_id,),
    )

    # Split, because the difference between these two groups is the whole
    # thing a reader needs, and it was being carried by one italic line.
    live, dead = [], []
    for a in aspects:
        kind = KINDS.get(a["source_kind"], a["source_kind"])
        if a["accrues"]:
            # WHAT IT COSTS YOU, which is the weight said in work. A Path
            # at 100% wants 20 casts a point; the same Path at 37% wants
            # 54. That is the number somebody is actually deciding on.
            live.append(
                f"**{a['label']}** {DOT} {kind} {DOT} "
                f"{int(round(float(a['weight']) * 100))}%\n"
                f"   **{int(a['per_point'])}** "
                f"{a['unit_name']} per point {DOT} *{a['feeds']}*"
            )
        else:
            dead.append(f"**{a['label']}** {DOT} {kind}")

    if row["stamped"] is not None:
        card = embed(
            name,
            f"The Dao of **{who}**, stamped "
            f"<t:{int(row['stamped_at'].timestamp())}:R> and fixed since.\n\n"
            "**Above the eighteen realms there is no cultivation bar.** "
            "This is the ladder instead: every aspect below that counts "
            "is a meter, filling one is called understanding, and "
            "understanding is the only thing that raises a rung.\n\n"
            "You never claim a rung \N{EM DASH} the moment its demands are met "
            "you already hold it. **/venerable** to see how far.",
            colour=COLOUR_GOOD,
        )
        foot = (
            "Only what you do FROM THE STAMP ONWARD counts \N{EM DASH} the "
            "ascension read every deed you had already done, and measures "
            "you from there."
        )
    else:
        card = embed(
            name,
            f"What **{who}** would be read as, off what they have "
            "already done.\n\n"
            "**A Dao is not chosen.** It is read off your record \N{EM DASH} the "
            "Paths you cast, the body you tempered, the crafts you kept, "
            "the worms you wore \N{EM DASH} and the ascension freezes it. After "
            "that it is the ladder you climb instead of cultivation, so "
            "what it is made of is what the rest of your life will ask you "
            "to do more of.",
            colour=COLOUR_INFO,
        )
        foot = (
            "Still being written \N{EM DASH} it changes as you do, right up until "
            "the ascension freezes it. What you have done so far sets the "
            "starting line, not the score."
        )

    card.add_field(
        name=f"What it counts ({len(live)})",
        value="\n".join(live) or "*nothing yet*",
        inline=False,
    )
    if dead:
        card.add_field(
            name=f"What it does not ({len(dead)})",
            value="\n".join(dead)
            + "\n\n*A root is what you were born with, and a destiny is "
            "what was arranged for you. Neither records a deed, so neither "
            "can ever earn understanding \N{EM DASH} they name your Dao without "
            "advancing it.*",
            inline=False,
        )
    card.set_footer(text=foot)
    return card


class Venerable(commands.Cog):
    """The nineteenth realm and up."""

    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    # -----------------------------------------------------------------------

    @app_commands.command(
        description="The Dao read off everything you have actually done."
    )
    async def dao(self, interaction: discord.Interaction) -> None:
        """Readable from the first Path, long before it can be stamped.

        It is not gated on rank on purpose: a cultivator should be able to see
        what their record is making of them while they can still change it.
        Nothing is written - `dao_aspects` and `dao_name_of` derive on every
        call.
        """
        player = await require_player(interaction.user)
        await interaction.response.defer()
        card = await dao_card(player["player_id"], player["discord_name"])
        await interaction.followup.send(embed=card)

    # -----------------------------------------------------------------------

    @app_commands.command(
        description="Understanding accrued against your stamped Dao, and the rung it reaches."
    )
    async def venerable(self, interaction: discord.Interaction) -> None:
        """The Venerable meter, which is not cultivation.

        Everything here comes from `venerable_progress`, which is also what
        `venerable_rank_of` reads - so the bar and the rung cannot disagree.
        """
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])
        await interaction.response.defer()

        row = await db.fetch_one(
            """
            SELECT d.dao_name, d.stamped_at, player_standing(%(p)s) AS standing
            FROM (SELECT 1) _
            LEFT JOIN player_dao d ON d.player_id = %(p)s
            """,
            {"p": player["player_id"]},
        )

        if row["dao_name"] is None:
            here = await db.fetch_one(
                "SELECT owed, rank, trial_name FROM tribulation_standing(%s)",
                (player["player_id"],),
            )
            waiting = (
                f"The **{here['trial_name']}** stands in the door "
                "\N{EM DASH} **/tribulation**."
                if here is not None and here["owed"] and here["rank"] == 19
                else "The eighteen realms come first \N{EM DASH} **/cultivation**."
            )
            card = embed(
                "Not yet a Venerable",
                "Understanding only accrues against a Dao that has been "
                "**stamped**, and the ascension is what stamps it. Until then "
                "your Dao is still being written \N{EM DASH} **/dao**.\n\n"
                + waiting,
                colour=COLOUR_INFO,
            )
            await interaction.followup.send(embed=card)
            return

        aspects = await db.fetch_all(
            """
            SELECT u.label, u.unit_name, u.gained, u.understanding, u.weight,
                   -- What a point costs THIS cultivator. A weight means
                   -- nothing until it is said in work.
                   ceil(r.units_per_point / NULLIF(u.weight, 0))
                       AS per_point
            FROM dao_understanding(%s) u
            JOIN dao_deed_rates r ON r.source_kind = u.source_kind
            ORDER BY u.understanding DESC, u.ordinal
            """,
            (player["player_id"],),
        )
        step = await db.fetch_one(
            """
            SELECT held_rank, held_tier, held_name,
                   next_rank, next_tier, next_name,
                   understanding, floor_at, required, fraction,
                   aspects_realised, aspects_needed, per_aspect
            FROM venerable_progress(%s)
            """,
            (player["player_id"],),
        )
        total = float(step["understanding"] or 0) if step else 0.0

        card = embed(
            row["dao_name"],
            f"**{player['discord_name']}** {DOT} stamped "
            f"<t:{int(row['stamped_at'].timestamp())}:R>",
            colour=COLOUR_GOOD,
        )

        held = "\N{EM DASH}"
        if step and step["held_tier"] is not None:
            held = f"Venerable Rank {step['held_tier']} {DOT} {step['held_name']}"
        card.add_field(
            name="Standing",
            value=f"{held}\n**{total:,.1f}** understanding",
            inline=False,
        )

        # Fills from the rung held rather than from zero, so each rung starts
        # it over instead of one bar creeping to full across all nine.
        if step and step["next_tier"] is not None:
            frac = float(step["fraction"] or 0)
            filled = int(round(frac * 20))
            meter = "█" * filled + "░" * (20 - filled)
            into = total - float(step["floor_at"] or 0)
            span = float(step["required"]) - float(step["floor_at"] or 0)
            enough = int(step["aspects_realised"] or 0) >= int(step["aspects_needed"])
            card.add_field(
                name=(
                    f"Toward Venerable Rank {step['next_tier']} "
                    f"\N{EM DASH} {step['next_name']}"
                ),
                value=(
                    f"`{meter}` {frac * 100:.0f}%\n\n"
                    # BOTH, and said so. Two lines under one meter read as
                    # a total and a footnote; they are an AND, and a
                    # cultivator who has one of them has nothing.
                    f"{'✅' if into >= span else '⬜'} **Understanding** "
                    f"{into:,.0f} / {span:,.0f}\n"
                    f"{'✅' if enough else '⬜'} **Aspects** "
                    f"{step['aspects_realised']} / {step['aspects_needed']} "
                    f"at {float(step['per_aspect']):,.0f} or more\n\n"
                    f"*Both are needed. The rung is yours the moment they "
                    "are, with nothing to press.*"
                ),
                inline=False,
            )
        else:
            card.add_field(
                name="At the top of the ladder",
                value="Every aspect of this Dao is realised. There is nothing above you.",
                inline=False,
            )

        # WHAT EACH ONE STILL NEEDS, in deeds. The floor is what gates the
        # rung, so an aspect's distance from it is the number somebody is
        # actually working toward - and `per_point` turns that distance
        # into casts, levels or hours, which is what they go and do.
        floor_at = float(step['per_aspect']) if step and step['per_aspect'] else 0.0
        lines = []
        for a in aspects:
            mine = float(a['understanding'])
            short = max(0.0, floor_at - mine)
            if floor_at <= 0:
                tail = f"{float(a['gained']):,.0f} {a['unit_name']} so far"
            elif short <= 0:
                tail = "**realised**"
            else:
                need = int(short * float(a['per_point'] or 0))
                tail = f"**{need:,}** more {a['unit_name']}"
            lines.append(
                f"{'✅' if floor_at > 0 and short <= 0 else '⬜'} "
                f"**{a['label']}** {DOT} {mine:,.1f}"
                + (f" / {floor_at:,.0f}" if floor_at > 0 else "")
                + f" {DOT} {tail}"
            )
        if not lines:
            lines = ["*Nothing \N{EM DASH} no aspect of this Dao records a deed.*"]
        card.add_field(
            name="What each aspect still needs",
            value="\n".join(lines),
            inline=False,
        )

        card.set_footer(
            text=(
                "Understanding is movement since the stamp, weighted by each "
                "aspect. A root and a destiny record no deed and do not appear."
            )
        )
        await interaction.followup.send(embed=card)

    # -----------------------------------------------------------------------

    @app_commands.command(
        description="Cross out of the eighteen realms, once the sky in the door is survived."
    )
    async def ascend(self, interaction: discord.Interaction) -> None:
        """Not /breakthrough, and that is not a naming choice.

        `breakthrough` walks `realms` by realm_id + 1 and asks the next row
        for its `cultivation_required`. There is no row above rank 18 on
        purpose - the Venerable ladder is `venerable_ranks`, because a realm
        whose meter is understanding cannot be gated on cultivation. So the
        crossing is its own function, and `venerable_ascend` refuses on
        everything this screen would otherwise have to check itself.
        """
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])
        await interaction.response.defer()

        try:
            done = await db.fetch_one(
                "SELECT * FROM venerable_ascend(%s)", (player["player_id"],)
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        card = embed(
            f"\N{HIGH VOLTAGE SIGN} {done['dao_name']}",
            f"**{player['discord_name']}** steps off the ladder of realms.\n\n"
            f"*Eighteen realms were a question of how much you could hold. "
            f"This one is a question of what you are.*",
            colour=COLOUR_GOOD,
        )
        card.add_field(
            name=f"Venerable Rank {done['tier']} {DOT} {done['title']}",
            value=(
                f"\N{HOLE} **+{done['aperture_gained']}** aperture "
                f"{DOT} now {thousands(await db.fetch_value('SELECT gu_capacity_of(%s)', (player['player_id'],)))}\n"
                f"\N{SPIRAL NOTE PAD} **{done['aspects']}** aspects fixed in place"
            ),
            inline=False,
        )
        card.add_field(
            name="What advances you now",
            value=(
                "Not cultivation \N{EM DASH} **understanding**. Each aspect of "
                "your Dao accrues it from the deeds that aspect is made of: "
                "casts for a Path, levels for a body or a craft, hours carried "
                "for a worm. **/venerable** is the meter.\n"
                "Your Dao is fixed from this moment. Nothing you train from "
                "here changes what it says \N{EM DASH} only how well you "
                "understand it."
            ),
            inline=False,
        )
        card.set_footer(text="Eight rungs above you. /venerable")
        await interaction.followup.send(embed=card)

    # -----------------------------------------------------------------------

    @app_commands.command(
        description="Pay what a failed tribulation left owed, and start cultivating again."
    )
    async def paydebt(self, interaction: discord.Interaction) -> None:
        """A failed sky stops cultivation until it is paid.

        The halt is one sentence in one place - `cultivation_halt` - read as a
        boolean by `apply_cultivation_xp` and `venerable_ascend` and as a
        sentence here, so the screen cannot say something the guards do not do.
        """
        player = await require_player(interaction.user)
        await interaction.response.defer()

        try:
            done = await db.fetch_one(
                "SELECT * FROM pay_tribulation_debt(%s)", (player["player_id"],)
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        card = embed(
            "\N{SPARKLES} The sky is paid",
            f"**{thousands(done['paid'])}** jade. Your cultivation advances again.",
            colour=COLOUR_GOOD,
        )
        card.set_footer(
            text=f"{thousands(done['jade_left'])} jade left {DOT} /cultivation"
        )
        await interaction.followup.send(embed=card)


    # -----------------------------------------------------------------------

    @app_commands.command(
        description="Read Ancient Venerable Notes into one aspect of your Dao."
    )
    @app_commands.describe(
        aspect="Which aspect of your Dao to study them into.",
        count="How many sets to read. All of them go into the one aspect.",
    )
    async def notes(
        self, interaction: discord.Interaction, aspect: str, count: int = 1
    ) -> None:
        """The notes are the only thing in the game that moves understanding
        without a deed behind it, so the aspect is the decision and the command
        exists to make it rather than to spend an item.
        """
        player = await require_player(interaction.user)
        await interaction.response.defer()

        try:
            ordinal = int(aspect)
        except ValueError:
            raise GameError("Pick the aspect from the list.") from None

        try:
            got = await db.fetch_one(
                "SELECT * FROM study_venerable_notes(%s, %s, %s)",
                (player["player_id"], ordinal, count),
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        held = await db.fetch_value(
            "SELECT COALESCE(quantity, 0) FROM player_materials "
            "WHERE player_id = %s AND material_code = 'ancient_venerable_notes'",
            (player["player_id"],),
        )

        card = embed(
            f"{SCROLL} Read into {got['label']}",
            f"Somebody else's hand, and now your understanding."
            f"\n\n"
            f"**+{float(got['gained']):,.0f}** into **{got['label']}**, "
            f"which now holds **{float(got['understanding_after']):,.1f}**."
            f"\n"
            f"Your Dao stands at **{float(got['total_after']):,.1f}** in all.",
            colour=COLOUR_GOOD,
        )
        if got["rung_after"] > got["rung_before"]:
            card.add_field(
                name="And that was enough",
                value=f"**Venerable Rank {got['rung_before']} "
                f"\N{EM DASH} {got['rung_after']}.**",
                inline=False,
            )
        card.set_footer(
            text=f"{held:,} set(s) left \N{EM DASH} /venerable for what each aspect "
            "still wants."
        )
        await interaction.followup.send(embed=card)

    @notes.autocomplete("aspect")
    async def notes_autocomplete(
        self, interaction: discord.Interaction, current: str
    ) -> list[app_commands.Choice[str]]:
        """Only the aspects that can hold understanding, with what each needs.

        Picking out of six bare labels would be a guess; the number somebody is
        deciding on is how far each one still is from the floor the next rung
        wants.
        """
        player = await db.fetch_one(
            "SELECT player_id FROM players WHERE discord_id = %s",
            (interaction.user.id,),
        )
        if player is None:
            return []
        rows = await db.fetch_all(
            """
            SELECT u.ordinal, u.label, u.understanding,
                   (SELECT per_aspect FROM venerable_progress(%(p)s)) AS floor_at
            FROM dao_understanding(%(p)s) u
            WHERE u.label ILIKE %(q)s
            ORDER BY u.understanding
            LIMIT 25
            """,
            {"p": player["player_id"], "q": f"%{current}%"},
        )
        out = []
        for r in rows:
            mine = float(r["understanding"])
            floor_at = float(r["floor_at"] or 0)
            short = (
                f" \N{EM DASH} {floor_at - mine:,.0f} short"
                if floor_at > mine
                else f" \N{EM DASH} already there"
            )
            out.append(
                app_commands.Choice(
                    name=f"{r['label']} \N{EM DASH} {mine:,.1f}{short}"[:100],
                    value=str(r["ordinal"]),
                )
            )
        return out


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Venerable(bot))
