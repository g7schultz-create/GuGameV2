"""The free-for-all: /tournament.

Sign up, and when the entry list closes everybody swings at somebody until one
is left. Nothing about the fight is decided here - `run_tournament` resolves
the whole thing in one call and this draws what it wrote.

No scheduler, same trick as the world beast: the screen that would show a
tournament runs any whose list has closed before it reads. A fight nobody is
waiting for can wait.

What a player signs up with is FROZEN at that moment (0151). An hour of
cultivating between entering and fighting changes nothing, which is the whole
reason the snapshot exists and the thing to say plainly on the card.
"""

import logging

import discord
import psycopg
from discord import app_commands
from discord.ext import commands

from bot import config, database as db
from bot.formatting import (
    COLOUR_DEFAULT,
    COLOUR_GOOD,
    COLOUR_INFO,
    embed,
    fit_field,
    humanise_duration,
    thousands,
)
from bot.players import GameError, require_player, settle_passive
from bot.views import AnsweringView

log = logging.getLogger("gu.tournament")

JADE = "\N{GREEN HEART}"
STONE = "\N{LARGE BLUE DIAMOND}"

# Places worth naming on a card. Below this it is a list of people who lost.
PODIUM = 8


def refuse(exc: psycopg.errors.CheckViolation) -> GameError:
    said = str(exc).splitlines()[0]
    return GameError(said[:1].upper() + said[1:])


async def settle_due() -> None:
    """Run anything whose entry list has closed. What stands in for a cron."""
    await db.execute("SELECT * FROM run_tournament()")


async def fetch_current() -> dict | None:
    """The tournament taking entries, else the last one fought."""
    return await db.fetch_one(
        """
        SELECT t.tournament_id, t.status, t.closes_at, t.fought_at, t.rounds,
               t.champion_id, p.discord_name AS champion,
               EXTRACT(EPOCH FROM (t.closes_at - now())) AS seconds_left,
               (SELECT count(*) FROM tournament_entrants te
                WHERE te.tournament_id = t.tournament_id) AS entrants
        FROM tournaments t
        LEFT JOIN players p ON p.player_id = t.champion_id
        ORDER BY (t.status = 'signup') DESC, t.opened_at DESC
        LIMIT 1
        """
    )


async def render(meet: dict, viewer_id: int | None = None) -> discord.Embed:
    if meet["status"] == "signup":
        entered = await db.fetch_all(
            """
            SELECT p.discord_name, te.max_hp,
                   jsonb_array_length(te.snapshot -> 'techniques') AS moves
            FROM tournament_entrants te
            JOIN players p ON p.player_id = te.player_id
            WHERE te.tournament_id = %s
            ORDER BY te.joined_at
            """,
            (meet["tournament_id"],),
        )
        least = await db.fetch_value(
            "SELECT game_config_value('tournament_min_entrants')"
        )
        prize = await db.fetch_value(
            "SELECT game_config_value('tournament_jade_prize')"
        )

        card = embed(
            "\N{TROPHY} The ring is open",
            "Everybody entered swings at somebody entered, round after round, "
            "until one is left standing.\n\n"
            "**What you are when you enter is what fights.** Health, defense, "
            "your techniques and what they are worth are all frozen the moment "
            "you sign up \N{EM DASH} cultivating afterwards will not help you here.",
            colour=COLOUR_INFO,
        )
        card.add_field(
            name=f"Entered ({len(entered)})",
            value="\n".join(
                f"**{row['discord_name']}** \N{BULLET} "
                f"{thousands(row['max_hp'])} HP \N{BULLET} "
                f"{row['moves']} technique(s)"
                for row in entered
            )
            or f"*Nobody yet. {int(least)} needed for it to run at all.*",
            inline=False,
        )
        card.set_footer(
            text=f"Closes in {humanise_duration(float(meet['seconds_left']))} "
            f"\N{BULLET} {int(least)} entrants minimum \N{BULLET} "
            f"{int(prize)} Jade to the champion, Spirit Stones to everyone "
            "by what they dealt"
        )
        return card

    if meet["status"] == "abandoned":
        return embed(
            "\N{TROPHY} Nobody came",
            f"The last ring closed with {meet['entrants']} entrant(s) and was "
            "called off. Enter and a new one opens.",
            colour=COLOUR_DEFAULT,
        )

    standings = await db.fetch_all(
        "SELECT * FROM tournament_standings(%s)", (meet["tournament_id"],)
    )
    card = embed(
        f"\N{TROPHY} {meet['champion']} takes it",
        f"{meet['entrants']} entrants \N{BULLET} {meet['rounds']} rounds "
        "\N{BULLET} one left standing.",
        colour=COLOUR_GOOD,
    )
    card.add_field(
        name="How it fell out",
        value=fit_field([
            f"`{row['place']}` **{row['discord_name']}** \N{BULLET} "
            + (
                f"{thousands(row['current_hp'])}/{thousands(row['max_hp'])} HP left"
                if row["current_hp"] > 0
                else f"fell in round {row['fell_round']}"
            )
            + f" \N{BULLET} {thousands(row['dealt'])} dealt"
            + (f", {row['felled']} felled" if row["felled"] else "")
            + ("  \N{LEFTWARDS BLACK ARROW} *you*"
               if viewer_id and row["player_id"] == viewer_id else "")
            # Everybody is paid now, so everybody's line says what they got. A
            # card reporting the placing and not the purse is why nobody would
            # notice the ring stopped paying only two people.
            + f"\n\N{IDEOGRAPHIC SPACE}{thousands(row['stones_paid'])} "
            + STONE
            + (f"  \N{BULLET}  {thousands(row['jade_paid'])} {JADE}"
               if row["jade_paid"] else "")
            for row in standings[:PODIUM]
        ] + ([f"*\N{HORIZONTAL ELLIPSIS} and {len(standings) - PODIUM} more*"]
             if len(standings) > PODIUM else [])),
        inline=False,
    )
    purse = sum(row["stones_paid"] for row in standings)
    card.set_footer(
        text=f"{thousands(purse)} Spirit Stones across the whole field "
        "\N{BULLET} open another ring below, or with **/tournament**."
    )
    return card


async def announce(bot: commands.Bot, meet: dict) -> None:
    """Post the result where the world beast is posted.

    Best-effort throughout: a fight that resolved is not undone by a channel
    nobody can write to.
    """
    channel_id = config.boss_channel_id()
    if channel_id is None:
        return
    try:
        channel = bot.get_channel(channel_id) or await bot.fetch_channel(channel_id)
        await channel.send(embed=await render(meet))
    except (discord.NotFound, discord.Forbidden, discord.HTTPException):
        log.warning("could not announce the tournament in %s", channel_id)


async def settle_and_announce(bot: commands.Bot) -> dict | None:
    """Resolve any ring whose list has closed, and announce it if one did.

    Two screens run the settle - /tournament and the /cd world block - and
    only the first one to look actually resolves it. Whichever that is has to
    be the one that posts the result, or the ring pays everybody in silence
    and the card naming the purse is only ever seen by somebody who thinks to
    go and read it.
    """
    before = await fetch_current()
    await settle_due()
    meet = await fetch_current()

    if (
        before is not None
        and before["status"] == "signup"
        and meet is not None
        and meet["status"] == "fought"
        and meet["tournament_id"] == before["tournament_id"]
    ):
        await announce(bot, meet)
    return meet


class RingView(AnsweringView):
    def __init__(self, bot: commands.Bot, user: discord.abc.User) -> None:
        super().__init__(timeout=600)
        self.bot = bot
        self.user = user

    @discord.ui.button(
        label="Enter", emoji="\N{TROPHY}", style=discord.ButtonStyle.success
    )
    async def enter(self, interaction: discord.Interaction, button) -> None:
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])
        try:
            joined = await db.fetch_one(
                "SELECT * FROM join_tournament(%s)", (player["player_id"],)
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        await interaction.response.send_message(
            embed=embed(
                "\N{TROPHY} Entered",
                f"Frozen at **{thousands(joined['max_hp'])} HP** with "
                f"**{joined['techniques']}** technique(s). That is what fights "
                "\N{EM DASH} nothing you do between now and then will change it.\n\n"
                f"{joined['entrants']} entered so far.",
                colour=COLOUR_GOOD,
            ),
            ephemeral=True,
        )
        meet = await fetch_current()
        if meet is not None:
            await interaction.message.edit(embed=await render(meet), view=self)


class OpenRing(AnsweringView):
    """Nothing is taking entries, so the only thing to do here is start one.

    `open_tournament` had exactly one caller and it sat behind "has a
    tournament ever existed" - true once, and false for good afterwards. So
    the moment the first ring finished there was no way to open a second: the
    command showed the last result and offered nothing, /cooldowns told people
    anyone could start one, and the results card promised that entering again
    would open one. Three screens describing a button that was not there.

    Anyone may press it. A ring is public and the partial unique index means
    two people racing to open one both end up in the same ring.
    """

    def __init__(self, bot: commands.Bot, user: discord.abc.User) -> None:
        super().__init__(timeout=600)
        self.bot = bot
        self.user = user

    @discord.ui.button(
        label="Open a ring", emoji="\N{TROPHY}", style=discord.ButtonStyle.success
    )
    async def open(self, interaction: discord.Interaction, button) -> None:
        await require_player(interaction.user)
        await db.execute("SELECT open_tournament()")
        meet = await fetch_current()
        if meet is None or meet["status"] != "signup":
            raise GameError("The ring would not open. Try **/tournament** again.")

        self.stop()
        # The message becomes the sign-up sheet, so whoever opened it is
        # looking at the thing they now have to press to be in it.
        await interaction.response.edit_message(
            embed=await render(meet), view=RingView(self.bot, interaction.user)
        )
        # And said out loud where the beast is announced, because a ring
        # nobody hears about closes with too few entrants.
        await announce(self.bot, meet)


class Tournament(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @app_commands.command(
        description="The free-for-all: enter the ring, or read how the last one went."
    )
    async def tournament(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])

        # Anything whose list has closed resolves here, which is the whole of
        # the scheduler this bot does not have. If it resolved on this very
        # look, the result is said out loud where everyone is.
        meet = await settle_and_announce(self.bot)

        # Nothing has ever run: there is no result to read, so the card is
        # the offer to start one.
        if meet is None:
            await interaction.response.send_message(
                embed=embed(
                    "\N{TROPHY} No ring has ever been opened",
                    "Everybody entered swings at somebody entered, round after "
                    "round, until one is left standing. What you are when you "
                    "enter is what fights.\n\nOpen one below.",
                    colour=COLOUR_INFO,
                ),
                view=OpenRing(self.bot, interaction.user),
            )
            return

        # Taking entries, or finished. A finished one still needs the way to
        # start the next, which is the whole of what was missing.
        view = (
            RingView(self.bot, interaction.user)
            if meet["status"] == "signup"
            else OpenRing(self.bot, interaction.user)
        )
        await interaction.response.send_message(
            embed=await render(meet, player["player_id"]), view=view
        )


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Tournament(bot))
