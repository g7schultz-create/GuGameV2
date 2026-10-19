"""The world beast: /boss and /strike.

The first thing in this game that more than one cultivator stands in front of.
Everything else is one player alone in a region; this is a single pool of HP
that the whole server chips at, and a share of the spoils that is settled by
what each of them actually did to it.

No scheduler runs it. `boss_open_if_due()` retires an expired beast and opens
the next one, and it is called by the screens that would show one - a beast
nobody is looking at does not need to have arrived yet. That is the whole of
the cron this bot does not have.

The strike itself lives in `strike_boss`, which runs the same damage pipeline a
hunt runs. Nothing about combat is decided here.
"""

import logging

import discord
import psycopg
from discord import app_commands
from discord.ext import commands, tasks

from bot import config, database as db
from bot.formatting import (
    COLOUR_BAD,
    COLOUR_DEFAULT,
    COLOUR_GOOD,
    COLOUR_INFO,
    bar,
    embed,
    fit_field,
    humanise_duration,
    percent,
    thousands,
)
from bot.players import GameError, require_player, settle_passive
from bot.views import AnsweringView

# Short, because the real throttle is `boss_resize_minutes` in SQL. This
# only decides how soon after that window a beast is actually re-measured.
RESIZE_TICK_MINUTES = 2

log = logging.getLogger("gu.boss")

STONE = "\N{LARGE BLUE DIAMOND}"
JADE = "\N{GREEN HEART}"

# How many names the card carries. Beyond this the list stops being a
# leaderboard and starts being a phone book.
BOARD = 8

# The wait a spent burst buys, in seconds. Mirrors `boss_strike_cooldown_minutes`
# because a view's timeout has to be chosen before any query runs, and a test
# holds the two together. The screen must outlast the stand-off: at 300 seconds
# against a 420 second wait it died first, so the countdown a player was
# watching could never reach zero.
STAND_OFF_SECONDS = 7 * 60


def spoils_text(row: dict) -> str:
    """Everything one cultivator was paid, written down once.

    The channel post, the /boss card and the killing blow all have to say
    this, and three copies of it would drift apart the first time a new kind
    of spoil is added - which is how a screen ends up quietly omitting the
    thing a player most wanted to see.
    """
    got = [f"{thousands(row['stones'])} {STONE}", f"{thousands(row['jade'])} {JADE}"]
    got += [
        f"{item.get('emoji', '')} {item['name']} "
        f"\N{MULTIPLICATION SIGN}{item['quantity']}"
        for item in (row["spoils"] or [])
    ]
    if row["manual"]:
        got.append(f"\N{SCROLL} **{row['manual']}**")
    return "  \N{BULLET}  ".join(got)


def haul_line(row: dict, *, place: int | None = None, mine: bool = False) -> str:
    """One cultivator's take, for any list of them.

    A share not yet claimed says so rather than showing zeroes: "waiting" is
    information the channel wants, because it is a nudge to whoever has one
    sitting there.
    """
    who = (
        (f"`{place}` " if place is not None else "")
        + f"**{row['discord_name']}** \N{BULLET} {thousands(row['damage'])} damage "
        f"\N{BULLET} {percent(row['share'], signed=False)}"
        + ("  \N{LEFTWARDS BLACK ARROW} *you*" if mine else "")
    )
    if not row["claimed"]:
        return f"{who}\n\N{IDEOGRAPHIC SPACE}*share not taken yet*"
    return f"{who}\n\N{IDEOGRAPHIC SPACE}" + spoils_text(row)


async def my_haul(encounter_id: int, player_id: int) -> dict | None:
    """What one cultivator was paid, out of the function the channel reads."""
    return await db.fetch_one(
        "SELECT * FROM boss_haul(%s) WHERE player_id = %s",
        (encounter_id, player_id),
    )


async def announcement(encounter_id: int) -> discord.Embed:
    """The post the whole server reads: who fought it and what they got."""
    state = await db.fetch_one(
        """
        SELECT e.encounter_id, cs.name, cs.rank AS beast_rank, cs.kind,
               r.name AS region_name, e.max_hp, e.status,
               slayer.discord_name AS slayer
        FROM boss_encounters e
        JOIN creature_species cs ON cs.species_id = e.species_id
        JOIN regions r ON r.code = e.region_code
        LEFT JOIN players slayer ON slayer.player_id = e.slayer_id
        WHERE e.encounter_id = %s
        """,
        (encounter_id,),
    )
    haul = await db.fetch_all("SELECT * FROM boss_haul(%s)", (encounter_id,))
    waiting = sum(1 for row in haul if not row["claimed"])

    card = embed(
        f"\N{COLLISION SYMBOL} {state['name']} has fallen",
        f"Rank {state['beast_rank']} {state['kind']} \N{BULLET} "
        f"{state['region_name']} \N{BULLET} {thousands(state['max_hp'])} HP\n"
        + (f"The last blow was **{state['slayer']}**'s."
           if state["slayer"] else "It was brought down."),
        colour=COLOUR_GOOD,
    )
    card.add_field(
        name=f"{len(haul)} cultivator(s) brought it down",
        # Each haul is a name, a share and everything they were paid, so this
        # is the longest list on any card in the game.
        value=fit_field(
            [haul_line(row, place=i + 1)
             for i, row in enumerate(haul[:BOARD])]
            + ([f"*\N{HORIZONTAL ELLIPSIS} and {len(haul) - BOARD} more*"]
               if len(haul) > BOARD else []),
            sep="\n\n",
        ),
        inline=False,
    )
    card.set_footer(
        text=(f"{waiting} share(s) still unclaimed \N{EM DASH} /boss to take yours"
              if waiting else "Every share taken.")
    )
    return card


async def announce_spawn(bot: commands.Bot) -> None:
    """Post that a beast has arrived, once.

    `spawn_announced_at` lives on the row rather than in this process, so a
    restart neither posts it twice nor forgets to post it at all - and the
    UPDATE only touches a row where it is still NULL, so two commands racing
    to look cannot both announce.
    """
    channel_id = config.boss_channel_id()
    if channel_id is None:
        return

    encounter_id = await db.fetch_value("SELECT boss_awaiting_announcement()")
    if encounter_id is None:
        return

    state = await db.fetch_one(
        """
        SELECT cs.name, cs.rank AS beast_rank, cs.kind, r.name AS region_name,
               e.max_hp, e.closes_at,
               EXTRACT(EPOCH FROM (e.closes_at - now())) AS seconds_left
        FROM boss_encounters e
        JOIN creature_species cs ON cs.species_id = e.species_id
        JOIN regions r ON r.code = e.region_code
        WHERE e.encounter_id = %s
        """,
        (encounter_id,),
    )
    if state is None:
        return

    strikes = await db.fetch_value(
        "SELECT game_config_value('boss_strikes_each')"
    )
    card = embed(
        f"\N{VOLCANO} {state['name']} has come",
        f"Rank {state['beast_rank']} {state['kind']} \N{BULLET} "
        f"**{state['region_name']}** \N{BULLET} "
        f"{thousands(state['max_hp'])} HP\n\n"
        "It will not go down to one cultivator. **/boss** to see it, "
        "**/strike** to start.",
        colour=COLOUR_BAD,
    )
    card.set_footer(
        text=f"{int(strikes)} strikes each \N{BULLET} "
        f"{humanise_duration(float(state['seconds_left']))} before it leaves "
        "\N{BULLET} spoils are split by damage and paid out automatically."
    )

    # Announcing is best-effort and must never take down the command that
    # happened to trigger the spawn - `/cooldowns` calls this, and a beast
    # nobody could be told about is still a beast. Broad on purpose: the
    # narrow Discord errors missed a bot whose HTTP is not connected at all,
    # which is every test that touches a screen while a spawn is due.
    try:
        channel = bot.get_channel(channel_id) or await bot.fetch_channel(channel_id)
        await channel.send(embed=card)
    except Exception:
        log.warning("could not announce the arrival in %s", channel_id,
                    exc_info=True)
        return

    await db.execute("SELECT boss_spawn_announced(%s)", (encounter_id,))


async def announce(bot: commands.Bot, encounter_id: int) -> None:
    """Post the kill, or edit the post that is already there.

    Everything here is best-effort. A channel that has been deleted, a message
    somebody removed, a bot without permission to post - none of those are
    reasons to fail the strike or the claim that triggered this, which is why
    every path swallows and returns rather than raising into the interaction.
    """
    channel_id = config.boss_channel_id()
    if channel_id is None:
        return

    where = await db.fetch_one(
        "SELECT announce_channel_id, announce_message_id FROM boss_encounters "
        "WHERE encounter_id = %s",
        (encounter_id,),
    )
    if where is None:
        return

    card = await announcement(encounter_id)

    try:
        channel = bot.get_channel(channel_id) or await bot.fetch_channel(channel_id)
    except (discord.NotFound, discord.Forbidden, discord.HTTPException):
        log.warning("boss channel %s is unreachable", channel_id)
        return

    if where["announce_message_id"]:
        try:
            posted = await channel.fetch_message(where["announce_message_id"])
            await posted.edit(embed=card)
            return
        except (discord.NotFound, discord.Forbidden, discord.HTTPException):
            # Somebody deleted it. Post a fresh one rather than going silent.
            pass

    try:
        posted = await channel.send(embed=card)
    except (discord.Forbidden, discord.HTTPException):
        log.warning("could not announce the world beast in %s", channel_id)
        return

    await db.execute(
        "SELECT boss_announced(%s, %s, %s)",
        (encounter_id, channel.id, posted.id),
    )


def refuse(exc: psycopg.errors.CheckViolation) -> GameError:
    """A refusal from the database, capitalised without being flattened.

    `str.capitalize` lowercases everything after the first letter, and these
    messages name beasts and Paths.
    """
    said = str(exc).splitlines()[0]
    return GameError(said[:1].upper() + said[1:])


async def fetch_state(player_id: int) -> dict | None:
    # Opening is a side effect of looking, which is what stands in for a
    # scheduler here. It has to happen before the read or the first player of
    # the day sees the empty screen that their own call just filled.
    await db.execute("SELECT boss_open_if_due()")
    return await db.fetch_one("SELECT * FROM boss_state(%s)", (player_id,))


async def render(state: dict, player_id: int) -> discord.Embed:
    alive = state["status"] == "open"
    done = state["max_hp"] - state["current_hp"]

    card = embed(
        f"\N{VOLCANO} {state['name']}",
        f"Rank {state['beast_rank']} {state['kind']} \N{BULLET} {state['region_name']}",
        colour=COLOUR_BAD if alive else COLOUR_GOOD,
    )

    if alive:
        card.add_field(
            name="Standing",
            value=f"{bar(state['current_hp'], state['max_hp'], 20)}\n"
            f"**{thousands(state['current_hp'])}** of "
            f"{thousands(state['max_hp'])} left \N{BULLET} "
            f"{humanise_duration(float(state['seconds_left']))} before it goes",
            inline=False,
        )
    else:
        # The question a player opens this card to ask, once it is over, is
        # when the next one comes - so the field that reports the end of one
        # beast is where the beginning of the next one belongs.
        due = await db.fetch_value(
            "SELECT EXTRACT(EPOCH FROM (boss_next_spawn_at() - now()))"
        )
        card.add_field(
            name="Slain" if state["status"] == "slain" else "Gone",
            value=(
                f"Brought down by **{state['slayer']}**."
                if state["status"] == "slain"
                else "It left before it could be brought down."
            )
            + f"\n{thousands(done)} damage from {state['fighters']} cultivator(s)."
            + (f"\n\nThe next comes in **{humanise_duration(float(due))}**."
               if due is not None and float(due) > 0
               else "\n\n**The next is due now** \N{EM DASH} look again."),
            inline=False,
        )

    if alive:
        board = await db.fetch_all(
            "SELECT * FROM boss_leaderboard(%s)", (state["encounter_id"],)
        )
        if board:
            card.add_field(
                name=f"Who has hit it ({len(board)})",
                value=fit_field([
                    f"`{i + 1}` **{row['discord_name']}** \N{BULLET} "
                    f"{thousands(row['damage'])} over {row['strikes']} strike(s) "
                    f"\N{BULLET} {percent(row['share'], signed=False)}"
                    + ("  \N{LEFTWARDS BLACK ARROW} *you*"
                       if row["player_id"] == player_id else "")
                    for i, row in enumerate(board[:BOARD])
                ] + ([f"*\N{HORIZONTAL ELLIPSIS} and {len(board) - BOARD} more*"]
                     if len(board) > BOARD else [])),
                inline=False,
            )
    else:
        # Once it is down the interesting column is no longer who hit it - it
        # is what that was worth. The card used to end on "your share has been
        # paid" without ever saying what into, which left the one screen a
        # player opens after a kill as the only place the spoils were not.
        haul = await db.fetch_all(
            "SELECT * FROM boss_haul(%s)", (state["encounter_id"],)
        )
        if haul:
            card.add_field(
                name=f"What it paid ({len(haul)})",
                value=fit_field(
                    [haul_line(row, place=i + 1,
                               mine=row["player_id"] == player_id)
                     for i, row in enumerate(haul[:BOARD])]
                    + ([f"*\N{HORIZONTAL ELLIPSIS} and {len(haul) - BOARD} more*"]
                       if len(haul) > BOARD else []),
                    sep="\n\n",
                ),
                inline=False,
            )

    if state["my_strikes"]:
        card.add_field(
            name="Your part",
            value=f"{thousands(state['my_damage'])} damage \N{BULLET} "
            f"{percent(state['my_share'], signed=False)} of what has been done "
            f"\N{BULLET} took {thousands(state['my_taken'])}",
            inline=False,
        )

    if alive:
        # A burst and then a wait, so one beast lasts an evening instead of
        # going to whoever opened Discord first.
        waiting = state.get("ready_in")
        card.set_footer(
            text=f"{state['strikes_left']} strike(s) left \N{BULLET} "
            + (
                f"standing off for "
                f"{humanise_duration(max(0.0, float(state['ready_in'] or 0)))}"
                if waiting
                else "everything you carry counts, and so does the Path you bring."
            )
        )
    elif state["my_strikes"]:
        # 0153 settles everybody the moment it ends, so there is nothing to
        # press and nothing to forget.
        card.set_footer(text="Paid out to everyone who struck it.")
    return card


class BossView(AnsweringView):
    """Strike it, or take what it owes you."""

    def __init__(self, player_id: int, user: discord.abc.User, state: dict) -> None:
        # Outlasts a stand-off deliberately. At 300 seconds against a seven
        # minute wait the screen died before the wait did, so the timer a
        # player was watching could never reach zero.
        super().__init__(timeout=STAND_OFF_SECONDS + 300)
        self.player_id = player_id
        self.user = user
        self.state = state
        self.build()

    def build(self) -> None:
        self.clear_items()
        if self.state["status"] == "open":
            self.add_item(
                StrikeButton(
                    self,
                    self.state["strikes_left"],
                    self.state.get("ready_in"),
                )
            )
            # The stand-off disables the only button on this screen, so
            # without a second one there is nothing left to press: the count
            # freezes at whatever it said when the burst ran out, and the
            # strike button never comes back. Re-running /boss was the only
            # way to watch a wait end.
            self.add_item(LookAgainButton(self))

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "Open your own **/boss** \N{EM DASH} it is the same beast.",
                ephemeral=True,
            )
            return False
        return True

    async def refresh(self, interaction: discord.Interaction, said: discord.Embed) -> None:
        self.state = await fetch_state(self.player_id)
        self.build()
        await interaction.response.edit_message(embed=said, view=self)


class StrikeButton(discord.ui.Button):
    """Greyed out with a reason rather than greyed out.

    A button that simply stops working is a bug from where the player is
    standing, so a stand-off says how long it has left on the button itself.
    """

    def __init__(self, screen: BossView, left: int, ready_in=None) -> None:
        self.screen = screen
        standing = ready_in is not None and float(ready_in) > 0
        super().__init__(
            label=(
                f"Ready in {humanise_duration(float(ready_in))}"
                if standing
                else f"Strike ({left} left)"
            )[:80],
            emoji="\N{HOURGLASS WITH FLOWING SAND}" if standing else "\N{CROSSED SWORDS}",
            style=discord.ButtonStyle.secondary if standing else discord.ButtonStyle.danger,
            disabled=standing or left <= 0,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        await self.screen.refresh(
            interaction,
            await strike(self.screen.player_id, interaction.client),
        )


class LookAgainButton(discord.ui.Button):
    """The way out of a stand-off.

    Never disabled - it is the one control that has to work while the other
    one cannot. It also brings the beast's health up to date, which matters
    on a boss half the server is hitting.
    """

    def __init__(self, screen: BossView) -> None:
        self.screen = screen
        super().__init__(
            label="Look again",
            emoji="\N{ANTICLOCKWISE DOWNWARDS AND UPWARDS OPEN CIRCLE ARROWS}",
            style=discord.ButtonStyle.secondary,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        state = await fetch_state(self.screen.player_id)
        if state is None:
            raise GameError("Nothing is standing right now.")
        self.screen.state = state
        self.screen.build()
        await interaction.response.edit_message(
            embed=await render(state, self.screen.player_id), view=self.screen
        )


# The claim button lived here. 0153 settles every striker the moment a beast
# falls or is retired, so there is nothing left to press - a share that had to
# be claimed was a share somebody would forget, and forgetting is not a game
# mechanic. `claim_boss_reward` is still the function that decides and rolls a
# payout; `settle_boss` is what calls it for the whole field.


async def strike(player_id: int, bot: commands.Bot | None = None) -> discord.Embed:
    try:
        hit = await db.fetch_one("SELECT * FROM strike_boss(%s)", (player_id,))
    except psycopg.errors.CheckViolation as exc:
        raise refuse(exc) from exc

    # The killing blow is always somebody's interaction, which is what lets
    # this bot announce a kill with no scheduler behind it.
    if hit["slain"] and bot is not None:
        await announce(bot, hit["encounter_id"])

    if hit["slain"]:
        card = embed(
            f"\N{COLLISION SYMBOL} {hit['beast_name']} falls",
            f"**{hit['technique']}** for **{thousands(hit['dealt'])}** "
            "\N{EM DASH} and that was the last of it."
            + (f"\n\N{PAW PRINTS} **{hit['pet_name']}** was in on it for "
               f"**{thousands(hit['pet_dealt'])}**."
               if hit["pet_dealt"] else ""),
            colour=COLOUR_GOOD,
        )
        # This card sent the killer to /boss "to take your share" long after
        # 0153 stopped there being anything to take: the whole field is
        # settled by the killing blow, so the share is in their satchel
        # before this is drawn. Saying what it was is the honest version.
        mine = await my_haul(hit["encounter_id"], player_id)
        if mine:
            card.add_field(name="Your share", value=spoils_text(mine), inline=False)
        card.set_footer(
            text="Everyone who struck it was paid \N{EM DASH} **/boss** for "
            "the whole haul."
        )
        return card

    card = embed(
        f"\N{CROSSED SWORDS} {hit['beast_name']}",
        f"**{hit['technique']}** for **{thousands(hit['dealt'])}**"
        + (f"  \N{BULLET}  matchup {percent(hit['matchup'])}"
           if hit["matchup"] else ""),
        colour=COLOUR_INFO,
    )
    # What the beast beside you did. `strike_boss` has carried it since
    # 0286; before that the number was computed and thrown away here.
    if hit["pet_dealt"]:
        card.description += (
            f"\n\N{PAW PRINTS} **{hit['pet_name']}** adds "
            f"**{thousands(hit['pet_dealt'])}**."
        )

    card.add_field(
        name="It answers",
        value=f"{thousands(hit['taken'])} off you \N{BULLET} "
        f"{thousands(hit['my_hp'])}/{thousands(hit['my_max_hp'])} left"
        + ("  \N{BULLET}  **/rest**" if hit["my_hp"] <= 0 else "")
        + (f"\n\N{PAW PRINTS} **{hit['pet_name']}** takes "
           f"{thousands(hit['pet_covered'])} of it"
           if hit["pet_covered"] else "")
        + ("  \N{BULLET}  **it goes down**" if hit["pet_down"] else ""),
        inline=False,
    )
    card.add_field(
        name="It stands",
        value=f"{bar(hit['boss_hp'], hit['boss_max_hp'], 20)}\n"
        f"{thousands(hit['boss_hp'])} of {thousands(hit['boss_max_hp'])}",
        inline=False,
    )
    card.set_footer(
        text=f"{hit['strikes_left']} strike(s) left \N{BULLET} "
        f"{thousands(hit['my_damage'])} damage from you so far"
    )
    return card


class Boss(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot
        self.measure.start()

    def cog_unload(self) -> None:
        self.measure.cancel()

    @tasks.loop(minutes=RESIZE_TICK_MINUTES)
    async def measure(self) -> None:
        """Size what is standing against the room that is actually here.

        The clock rather than a screen, because the whole point is that a
        beast gets easier while nobody strong is around - and nobody strong
        being around is exactly when nobody is opening the screen.

        `resize_world_if_due` throttles itself in SQL, so this being a short
        loop costs a timestamp comparison and the real measure happens every
        `boss_resize_minutes`.
        """
        try:
            for row in await db.fetch_all("SELECT * FROM resize_world_if_due()"):
                log.info(
                    "%s %s now holds %s",
                    row["what"], row["encounter_id"], row["now_holds"],
                )
        except Exception:
            log.warning("could not measure the world", exc_info=True)

    @measure.before_loop
    async def before_measure(self) -> None:
        # Under the test harness `bot` is a stand-in with no gateway, so
        # this raises and discord.py reports it as an unretrieved task
        # exception - three of them, every test, drowning the output that
        # says which assertion actually failed. A loop that cannot wait
        # for a client it does not have simply does not run.
        try:
            await self.bot.wait_until_ready()
        except RuntimeError:
            self.measure.cancel()
            return

    @app_commands.command(
        description="The world beast everyone is fighting, and what you have done to it."
    )
    async def boss(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])

        state = await fetch_state(player["player_id"])
        await announce_spawn(self.bot)
        if state is None:
            raise GameError(
                "Nothing has come yet, and nothing has been. Try again later."
            )

        screen = BossView(player["player_id"], interaction.user, state)
        await interaction.response.send_message(
            embed=await render(state, player["player_id"]),
            view=screen if screen.children else discord.utils.MISSING,
        )

    @app_commands.command(description="Strike the world beast once.")
    async def strike(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])
        card = await strike(player["player_id"], self.bot)
        # A strike opens one too, if the world had rested - so it is also a
        # place an arrival can go unannounced.
        await announce_spawn(self.bot)
        await interaction.response.send_message(embed=card)


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Boss(bot))
