"""Status: /ping and /profile.

Registration lives in `character.py` - it is a screen with a lifecycle, not a
status read.
"""

import time

import discord
import psycopg
from discord import app_commands
from discord.ext import commands

from bot import database as db
from bot.cogs.boss import announce_spawn, fetch_state as fetch_beast
from bot.cogs.tournament import settle_and_announce as settle_ring
from bot.character import (
    fetch_character,
    fetch_foundation,
    fetch_path_bonuses,
    fetch_trait_effects,
    render_character,
)
from bot.formatting import (
    COLOUR_GOOD,
    COLOUR_INFO,
    embed,
    fit_field,
    humanise_duration,
    percent,
    thousands,
)
from bot.players import (
    GameError,
    fetch_player,
    require_player,
    settle_passive,
)
from bot.views import AnsweringView


VOLCANO = "\N{VOLCANO}"
TROPHY = "\N{TROPHY}"


async def beast_line(player_id: int) -> str:
    """What the world beast is doing, and what is left of your part in it.

    `fetch_beast` is the boss screen's own reader - it opens one if the world
    has rested, which makes /cooldowns another place the clock turns. That is
    the point rather than a side effect: this bot has no scheduler, and a
    screen that reports a timer without advancing it reports the past.
    """
    state = await fetch_beast(player_id)
    if state is None or state["status"] != "open":
        # "Nothing standing" is the half of the answer nobody asked for. The
        # other half is exact: the world rests `boss_rest_hours` after the
        # last beast ended, and 0165 makes that moment sayable.
        due = await db.fetch_value(
            "SELECT EXTRACT(EPOCH FROM (boss_next_spawn_at() - now()))"
        )
        return (
            f"{VOLCANO} **World boss**: nothing standing \N{BULLET} "
            + (f"next in {humanise_duration(float(due))}"
               if due is not None and float(due) > 0 else "one is due now")
            + " \N{BULLET} **/boss**"
        )

    left = float(state["current_hp"]) / float(state["max_hp"]) * 100
    mine = (
        f"{state['strikes_left']} strike(s) yours"
        if state["strikes_left"]
        else "you have spent your strikes"
    )
    return (
        f"{VOLCANO} **World boss**: {state['name']} \N{BULLET} {left:.0f}% left "
        f"\N{BULLET} {humanise_duration(float(state['seconds_left']))} "
        f"\N{BULLET} {mine}"
    )


async def ring_line(player_id: int, meet: dict | None) -> str:
    """The ring, and whether you are standing in it.

    Whether YOU signed up is the half a timer screen exists to answer - a
    tournament closing in two hours means something different depending on it.

    Takes the meet rather than fetching it: this screen is where a closed ring
    usually gets resolved, and the resolving has to happen somewhere that can
    announce the result. That is the caller.
    """
    if meet is None or meet["status"] != "signup":
        # Deliberately not a countdown. `open_tournament` has no rest period
        # and no schedule - a ring exists the moment somebody asks for one -
        # so any time printed here would be invented. What a reader wants to
        # know is that the wait is nobody's but theirs.
        return (
            f"{TROPHY} **Tournament**: no ring open \N{BULLET} "
            "anyone can start one \N{BULLET} **/tournament**"
        )

    least = await db.fetch_value(
        "SELECT game_config_value('tournament_min_entrants')"
    )
    entered = await db.fetch_value(
        "SELECT EXISTS (SELECT 1 FROM tournament_entrants WHERE tournament_id = %s "
        "AND player_id = %s)",
        (meet["tournament_id"], player_id),
    )
    short = int(least) - int(meet["entrants"])
    return (
        f"{TROPHY} **Tournament**: sign-ups close in "
        f"{humanise_duration(float(meet['seconds_left']))} \N{BULLET} "
        f"{meet['entrants']} entered"
        + (f", {short} more needed" if short > 0 else "")
        + (" \N{BULLET} \N{WHITE HEAVY CHECK MARK} you are in"
           if entered else " \N{BULLET} **/tournament** to enter")
    )


class PurseRiverButton(discord.ui.Button):
    """A root that can walk the purse back, offered on the refusal.

    The same shape `/enlighten` uses: the moment somebody is told the purse is
    shut is the moment they want to know their root disagrees.
    """

    def __init__(self, name: str, left: int) -> None:
        super().__init__(
            label=f"{name} ({left} left today)"[:80],
            emoji="\N{LARGE BLUE DIAMOND}",
            style=discord.ButtonStyle.primary,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        try:
            spent = await db.fetch_one(
                "SELECT * FROM root_special_use(%s, 'daily')",
                (player["player_id"],),
            )
            # Taking the purse is what the charge was for, so it happens in
            # the same press rather than leaving somebody to run /daily again.
            got = await db.fetch_one(
                "SELECT * FROM claim_daily(%s)", (player["player_id"],)
            )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0].capitalize()) from exc

        card = embed(
            f"\N{GREEN HEART} +{thousands(got['jade'])} Spirit Jade",
            f"Walked back and taken again. **{got['streak']}** day(s) in a run.",
            colour=COLOUR_GOOD,
        )
        card.set_footer(
            text=f"{spent['special_name']} \N{BULLET} "
                 f"{spent['charges_left']} left today"
        )
        await interaction.response.edit_message(embed=card, view=None)


async def purse_river_offer(player_id: int):
    """What a root can do about a shut purse, if anything. None for almost
    everybody, which is why it is safe to ask on every refusal."""
    row = await db.fetch_one(
        """
        SELECT r.special_name,
               root_special_charges_left(%(p)s, 'daily') AS left
        FROM player_character pc
        JOIN roots r ON r.code = pc.root_code
        JOIN root_specials rs ON rs.root_code = pc.root_code
        WHERE pc.player_id = %(p)s AND rs.resets_action = 'daily'
        """,
        {"p": player_id},
    )
    if row is None or not row["left"]:
        return None
    view = AnsweringView(timeout=180)
    view.add_item(PurseRiverButton(row["special_name"], int(row["left"])))
    return view


class Core(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @app_commands.command(description="Check the bot is alive and can reach the database.")
    async def ping(self, interaction: discord.Interaction) -> None:
        """Deliberately touches Postgres rather than only reporting gateway
        latency. A bot that answers /ping while the database is unreachable has
        told you nothing worth knowing.
        """
        started = time.perf_counter()
        latest = await db.fetch_one(
            "SELECT version, name FROM schema_migrations ORDER BY version DESC LIMIT 1"
        )
        db_ms = (time.perf_counter() - started) * 1000

        card = embed("Pong", colour=COLOUR_INFO)
        card.add_field(name="Gateway", value=f"{self.bot.latency * 1000:.0f} ms")
        card.add_field(name="Database", value=f"{db_ms:.0f} ms")
        card.add_field(
            name="Schema",
            value=f"migration {latest['version']}\n{latest['name']}",
        )
        await interaction.response.send_message(embed=card, ephemeral=True)

    # -----------------------------------------------------------------------

    @app_commands.command(description="What you can do now, and what you are waiting on.")
    async def cooldowns(self, interaction: discord.Interaction) -> None:
        """The list is derived from the config keys rather than written here.

        Nothing records which actions have a cooldown — it is implicit in
        whichever command calls `claim_cooldown` — so a hand-written list would
        be one somebody has to remember to add to, and the first thing to ship
        without one would simply be invisible.

        The sections and emoji come from `cooldown_display`, which is styling
        and nothing else: an action with no row there still shows up, under
        "Other". So this file writes down neither the actions nor their order.
        """
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])

        # Before anything is drawn: a ring whose list has closed resolves on
        # this screen as often as on /tournament, and it pays out when it does.
        ring = await settle_ring(self.bot)

        rows = await db.fetch_all(
            "SELECT * FROM cooldown_status(%s) ORDER BY sort_order, label",
            (player["player_id"],),
        )
        boosts = await db.fetch_all(
            """
            SELECT b.magnitude, b.hours_left, k.name, k.emoji
            FROM player_boosts b
            JOIN pill_kinds k ON k.code = b.kind
            WHERE b.player_id = %s
            ORDER BY b.hours_left DESC
            """,
            (player["player_id"],),
        )

        ready = [r for r in rows if r["ready"]]
        card = embed(
            f"\N{ALARM CLOCK} {interaction.user.display_name}'s timers",
            f"**{len(ready)}** of {len(rows)} ready.",
            colour=COLOUR_GOOD if ready else COLOUR_INFO,
        )

        # Grouped in the order the sections first appear, which is the order
        # `sort_order` already puts them in — so the section list is not a
        # second thing to keep in step.
        sections: dict[str, list[str]] = {}
        for row in rows:
            if row["ready"]:
                state = "\N{WHITE HEAVY CHECK MARK} Ready"
                if row["tries_left"]:
                    state += (
                        f" \N{BULLET} {row['tries_left']} "
                        f"tr{'y' if row['tries_left'] == 1 else 'ies'} left"
                    )
            else:
                left = (row["ready_at"] - discord.utils.utcnow()).total_seconds()
                state = f"\N{HOURGLASS WITH FLOWING SAND} {humanise_duration(left)}"
            sections.setdefault(row["section"], []).append(
                f"{row['emoji']} **{row['label']}**: {state}"
            )

        for name, lines in sections.items():
            card.add_field(name=name, value="\n".join(lines), inline=False)

        # Neither of these is a player cooldown, so neither can be derived
        # the way the rows above are: they are world clocks, one per server
        # rather than one per cultivator, and they live in `boss_encounters`
        # and `tournaments` rather than in `player_cooldowns`. Written out
        # here because there is nothing to derive them from - but the facts
        # are read from the screens that own them, not recomputed.
        card.add_field(
            name="The world",
            value=f"{await beast_line(player['player_id'])}\n"
            f"{await ring_line(player['player_id'], ring)}",
            inline=False,
        )
        await announce_spawn(self.bot)

        # The one row here that is not a clock. A boost's hours are spent by
        # settled time and not by the calendar, so "left" means hours of
        # cultivation rather than hours of Tuesday — which is exactly why it
        # gets its own field instead of a countdown beside the timers.
        card.add_field(
            name="Active boosts",
            value="\n".join(
                f"{b['emoji']} **{b['name']}** {percent(b['magnitude'])} "
                f"\N{BULLET} {float(b['hours_left']):.1f}h of cultivation left"
                for b in boosts
            )
            or "*None. A rate pill from **/alchemy** leaves one here.*",
            inline=False,
        )
        card.set_footer(
            text="A set of tries counts as ready — one claim buys five, and the "
            "clock starts on the first."
        )
        await interaction.response.send_message(embed=card)

    # -----------------------------------------------------------------------

    @app_commands.command(description="Take the daily purse of Spirit Jade.")
    async def daily(self, interaction: discord.Interaction) -> None:
        """The one faucet whose rate is a number rather than a playstyle.

        `claim_daily` reports rather than raises when it is not due, the way
        `claim_cooldown` does — "not yet, come back at" is an answer and not
        an error.
        """
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])

        got = await db.fetch_one(
            "SELECT * FROM claim_daily(%s)", (player["player_id"],)
        )

        if not got["claimed"]:
            card = embed(
                "\N{GREEN HEART} Not yet",
                "The next purse is ready "
                f"{discord.utils.format_dt(got['next_at'], style='R')}.",
                colour=COLOUR_INFO,
            )
            card.add_field(
                name="Run",
                value=f"**{got['streak']}** day(s) \N{BULLET} best {got['longest']}",
            )
            card.add_field(
                name="Held",
                value=f"\N{GREEN HEART} {thousands(got['held'])}"
                + (f"\n\N{OLD KEY} {thousands(got['keys_held'])}"
                   if got["keys_held"] else ""),
            )
            # A root that can walk the day back turns "not yet" into a
            # choice. Everybody else still just gets the answer.
            offer = await purse_river_offer(player["player_id"])
            await interaction.response.send_message(
                embed=card, view=offer if offer else discord.utils.MISSING
            )
            return

        ahead = await db.fetch_value(
            "SELECT daily_jade_for_streak(%s)", (got["streak"] + 1,)
        )
        card = embed(
            f"\N{GREEN HEART} +{thousands(got['jade'])} Spirit Jade"
            + (f"  \N{BULLET}  \N{OLD KEY} +{got['keys']}" if got["keys"] else ""),
            "A run continues if you come back within two days — and the claim "
            "is every 22 hours, so the time never creeps later on you.",
            colour=COLOUR_GOOD,
        )
        card.add_field(
            name="Run",
            value=f"**{got['streak']}** day(s)"
            + ("" if got["kept"] else " \N{BULLET} *started again*")
            + f"\nbest {got['longest']}",
        )
        card.add_field(
            name="Held",
            value=f"\N{GREEN HEART} **{thousands(got['held'])}**"
            + (f"\n\N{OLD KEY} **{thousands(got['keys_held'])}**"
               if got["keys_held"] else ""),
        )
        card.set_footer(
            text=f"Tomorrow pays {int(ahead)}. Jade buys rerolls and protection "
            "on a risky craft; keys open dungeons and can be traded."
        )
        await interaction.response.send_message(embed=card)

    # -----------------------------------------------------------------------

    @app_commands.command(
        description="Every stat you carry, what it is capped at, and where it came from."
    )
    @app_commands.describe(user="Whose sheet to read. Defaults to your own.")
    async def stats(
        self,
        interaction: discord.Interaction,
        user: discord.User | None = None,
    ) -> None:
        """What /profile does not say.

        `player_stat` adds seven sources together and clamps the sum, and
        until now a cultivator could read what their worms gave on **/gu** and
        what their gear gave on **/gear** and nowhere read what they actually
        HAVE — which is the number every fight is settled by.

        Abilities are separated from the rest because since 0353 the world
        hands them out at a fifth of the rate, so which ones you have is the
        shape of your build rather than a detail of it.
        """
        target = user or interaction.user

        if user is None:
            player = await require_player(interaction.user)
        else:
            player = await fetch_player(target.id)
            if player is None:
                await interaction.response.send_message(
                    f"{target.display_name} has not begun cultivating.",
                    ephemeral=True,
                )
                return

        player_id = player["player_id"]
        await settle_passive(player_id)

        standing = await db.fetch_one(
            """
            -- The realm NAME is still true for a Venerable - they hold
            -- a Yellow Apricot body and always will. The CAPACITY is
            -- not: 0520 continued the curve onto the Venerable ladder,
            -- so this printed "32 / 57" against a real ceiling of 60
            -- and could show a cultivator over their own total.
            SELECT r.name AS realm,
                   gu_capacity_of(%s) AS gu_capacity,
                   gu_used_by(%s) AS used,
                   (SELECT count(*) FROM player_gu_equipped e
                    WHERE e.player_id = %s) AS worn
            FROM player_cultivation pc
            JOIN realms r ON r.realm_id = pc.realm_id
            WHERE pc.player_id = %s
            """,
            (player_id, player_id, player_id, player_id),
        )
        sheet = await db.fetch_all(
            "SELECT * FROM player_stat_sheet(%s) WHERE total > 0", (player_id,)
        )

        card = embed(
            f"\N{CLIPBOARD} {target.display_name}'s stats",
            f"**{standing['realm']}** \N{BULLET} aperture "
            f"**{standing['used']}/{standing['gu_capacity']}** across "
            f"{standing['worn']} Gu."
            if standing else "No cultivation yet.",
            colour=COLOUR_INFO,
        )

        def line(row: dict) -> str:
            # Where the most of it came from, which is the question a player
            # asks next: "can I get more of this, and from where."
            sources = {
                "worms": row["from_gu"], "gear": row["from_gear"],
                "body": row["from_body"], "root": row["from_root"],
                "home": row["from_home"], "manual": row["from_manual"],
                "fate": row["from_destiny"],
            }
            lead = max(sources, key=lambda k: sources[k])
            # A base stat is points on a body, not a percentage of one. Three
            # points of Body printed as "+300%" is not a rounding problem, it
            # is a different quantity — and what a player wants to know is what
            # the points are worth once their realm has multiplied them.
            if row["is_base"]:
                said = (
                    f"{row['emoji']} **{row['name']}** "
                    f"{int(row['total'])} / {int(row['cap'])}"
                    f" \N{BULLET} +{thousands(row['worth'])} after your realm"
                )
            else:
                said = (
                    f"{row['emoji']} **{row['name']}** "
                    f"{percent(row['total'], signed=False)}"
                )
                if not row["capped"]:
                    said += f" / {percent(row['cap'], signed=False)}"
            if row["capped"]:
                # The one thing worth interrupting for: another worm of this
                # kind is worth nothing at all.
                said += " \N{BULLET} **at the ceiling**"
            if sources[lead] > 0:
                said += f" \N{BULLET} *{lead}*"
            return said

        # Body first, because it is the one thing a cultivator can always
        # still add to when the rest of the sheet is sitting on its ceilings.
        for title, pick in (
            ("\N{ANATOMICAL HEART} Body", lambda r: r["is_base"]),
            ("\N{CROSSED SWORDS} Abilities",
             lambda r: r["is_ability"] and not r["is_base"]),
            ("\N{CHART WITH UPWARDS TREND} Stats",
             lambda r: not r["is_ability"] and not r["is_base"]),
        ):
            rows = [r for r in sheet if pick(r)]
            if not rows:
                continue
            card.add_field(
                name=title,
                value=fit_field([line(r) for r in rows], noun="more"),
                inline=False,
            )

        wasted = [r["name"] for r in sheet if r["capped"]]
        card.set_footer(
            text=(
                f"At the ceiling: {', '.join(wasted)} — another of those buys "
                "nothing. " if wasted else ""
            )
            + "Abilities are handed out at a fifth the rate of ordinary stats."
        )
        await interaction.response.send_message(embed=card)

    # -----------------------------------------------------------------------

    @app_commands.command(description="Your character sheet and cultivation progress.")
    @app_commands.describe(user="Whose profile to read. Defaults to your own.")
    async def profile(
        self,
        interaction: discord.Interaction,
        user: discord.User | None = None,
    ) -> None:
        target = user or interaction.user

        if user is None:
            player = await require_player(interaction.user)
        else:
            player = await fetch_player(target.id)
            if player is None:
                await interaction.response.send_message(
                    f"{target.display_name} has not begun cultivating.",
                    ephemeral=True,
                )
                return

        player_id = player["player_id"]

        # Settle first, then read. Doing it the other way round shows a bar
        # that is one command out of date, which on an idle game is the whole
        # thing being wrong.
        settled = await settle_passive(player_id)

        char = await fetch_character(player_id)
        if char is None or char["confirmed_at"] is None:
            await interaction.response.send_message(
                embed=embed(
                    "Still choosing",
                    f"{'You have' if user is None else target.display_name + ' has'} "
                    "not confirmed a character yet. **/register** picks up where it left off.",
                ),
                ephemeral=True,
            )
            return

        bonuses = await fetch_path_bonuses(player_id)
        foundation = await fetch_foundation(player_id)
        effects = await fetch_trait_effects(player_id)
        card = render_character(
            char,
            bonuses,
            foundation,
            effects,
            display_name=target.display_name,
            avatar_url=target.display_avatar.url,
        )

        # What the last stretch of idle time was worth, so the number moving
        # has a visible cause. Cultivation is no longer the thing that decides
        # whether there is anything to say: at a bottleneck it is the one
        # pillar that gains nothing while the body carries on.
        if settled and any(
            settled[key]
            for key in (
                "cultivation_gained",
                "cultivation_stored",
                "physique_gained",
                "insight_gained",
                "hp_restored",
            )
        ):
            gains = []
            if settled["cultivation_gained"]:
                gains.append(f"+{thousands(settled['cultivation_gained'])} cultivation")
            if settled["cultivation_stored"]:
                gains.append(
                    f"+{thousands(settled['cultivation_stored'])} held in reserve"
                )
            if settled["physique_gained"]:
                gains.append(f"+{thousands(settled['physique_gained'])} physique XP")
            if settled["insight_gained"]:
                gains.append(
                    f"+{thousands(settled['insight_gained'])} {settled['focus_path']} insight"
                )
            if settled["hp_restored"]:
                gains.append(f"+{thousands(settled['hp_restored'])} HP recovered")
            line = f"{humanise_duration(float(settled['hours']) * 3600)} away: " + ", ".join(gains)
            if settled["capped"]:
                line += "\n*Capped — idle time is only paid up to the configured limit.*"
            # The bottleneck no longer eats what it stops. It says so here
            # in the two cases that differ: held, or held all it can hold.
            if not settled["cultivation_gained"]:
                if settled["cultivation_stored"]:
                    line += (
                        "\n*Cultivation stops at the next realm's door - "
                        "but it is held, not lost. **/breakthrough** pours "
                        "it in.*"
                    )
                else:
                    line += (
                        "\n*The door is shut and the reserve is full. "
                        "Anything past this is genuinely lost - "
                        "**/breakthrough**.*"
                    )
            card.add_field(name="Since you last looked", value=line, inline=False)

        breakthroughs = []
        # A realm is no longer something idle time hands you - it is taken with
        # /breakthrough, so the most this can do is say that the door is open.
        if await db.fetch_value(
            "SELECT ready_to_break_through(%s)", (player["player_id"],)
        ):
            waiting = await db.fetch_value(
                """
                SELECT next.name FROM player_cultivation pc
                JOIN realms next ON next.realm_id = pc.realm_id + 1
                WHERE pc.player_id = %s
                """,
                (player["player_id"],),
            )
            breakthroughs.append(
                f"\N{HIGH VOLTAGE SIGN} **{waiting}** is within reach. "
                "**/breakthrough** to take it."
            )
        if settled and settled["level_after"] > settled["level_before"]:
            breakthroughs.append(f"Body level **{settled['level_after']}**.")
        if settled and settled["tier_after"] > settled["tier_before"]:
            tier = await db.fetch_value(
                "SELECT name FROM attainment_tiers WHERE tier = %s",
                (settled["tier_after"],),
            )
            breakthroughs.append(
                f"{settled['focus_path'].title()} attainment is now **{tier}**."
            )
        if breakthroughs:
            card.add_field(
                name="\N{HIGH VOLTAGE SIGN} Breakthrough",
                value="\n".join(breakthroughs),
                inline=False,
            )

        await interaction.response.send_message(embed=card)


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Core(bot))
