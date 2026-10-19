"""Beast Hordes: /horde, and a channel that fills itself.

THIS IS THE ONLY THING IN THE GAME THAT TICKS. Everywhere else the rule holds
that nothing happens until somebody looks - passive cultivation settles when
you ask, a world beast spawns when a command notices it is due, a dungeon round
resolves the next time anybody opens the room. That rule is right for all of
them and wrong for exactly this: a horde whose beasts only appear when somebody
clicks is a channel that is empty until it is busy, which is the opposite of an
invasion. So there is a loop, it is contained to this cog, and it does one
cheap query and stops when no tide is running.

Everything the loop does is idempotent and driven off the database rather than
off anything held in this process. A restart mid-tide loses no beast: the rows
are there, the message ids are on them, and the next tick picks them up.

The damage is the database's - `horde_strike` calls the same
`compute_technique_damage` a duel does. Nothing about hitting things works
differently because it happened in a channel.
"""

import logging

import discord
import psycopg
from discord import app_commands
from discord.ext import commands, tasks

from bot import config
from bot import database as db
from bot.battle import usable_techniques
from bot.formatting import (
    COLOUR_BAD,
    COLOUR_DEFAULT,
    COLOUR_GOOD,
    COLOUR_INFO,
    bar,
    embed,
    humanise_duration,
    thousands,
)
from bot.players import GameError, require_player
from bot.views import AnsweringView

log = logging.getLogger("gu.horde")

TICK_SECONDS = 20

PAW = "\N{PAW PRINTS}"
FIRE = "\N{FIRE}"
CROWN = "\N{CROWN}"
SKULL = "\N{SKULL}"
CHEST = "\N{WRAPPED PRESENT}"
WARN = "\N{WARNING SIGN}"
SWING = "\N{CROSSED SWORDS}"

FACE = {"normal": PAW, "elite": FIRE, "king": CROWN}


def refuse(exc: psycopg.errors.CheckViolation) -> GameError:
    return GameError(str(exc).splitlines()[0].capitalize())


# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------


async def live_horde() -> dict | None:
    return await db.fetch_one(
        "SELECT * FROM horde_board WHERE status IN ('fighting', 'king') "
        "ORDER BY horde_id DESC LIMIT 1"
    )


async def latest_horde() -> dict | None:
    return await db.fetch_one(
        "SELECT * FROM horde_board ORDER BY horde_id DESC LIMIT 1"
    )


async def fetch_beast(encounter_id: int) -> dict | None:
    return await db.fetch_one(
        """
        SELECT e.encounter_id, e.horde_id, e.kind, e.hp, e.max_hp, e.status,
               e.message_id, cs.name, cs.rank, cs.description,
               p.discord_name AS slayer,
               EXTRACT(EPOCH FROM (e.expires_at - now())) AS seconds_left
        FROM horde_encounters e
        JOIN creature_species cs ON cs.species_id = e.species_id
        LEFT JOIN players p ON p.player_id = e.slain_by
        WHERE e.encounter_id = %s
        """,
        (encounter_id,),
    )


def beast_card(
    beast: dict, last: dict | None = None, by: str | None = None
) -> discord.Embed:
    if beast["status"] == "slain":
        card = embed(
            f"\N{WHITE HEAVY CHECK MARK} {beast['name']} is down",
            f"Felled by **{beast['slayer'] or 'the line'}**."
            + (
                f" +{thousands(last['bounty'])} for the blow that did it."
                if last and last.get("bounty")
                else ""
            ),
            colour=COLOUR_GOOD,
        )
        return card

    if beast["status"] == "escaped":
        return embed(
            f"\N{DASH SYMBOL} {beast['name']} broke through",
            "It is past the line and into the region.",
            colour=COLOUR_BAD,
        )

    left = max(0.0, float(beast["seconds_left"] or 0))
    card = embed(
        f"{FACE.get(beast['kind'], PAW)} {beast['name']}"
        + ("  \N{CROWN}" if beast["kind"] == "king" else ""),
        f"*{beast['description']}*" if beast["description"] else None,
        colour=COLOUR_BAD if beast["kind"] == "king" else COLOUR_DEFAULT,
    )
    card.add_field(
        name=f"{thousands(beast['hp'])} / {thousands(beast['max_hp'])}",
        value=bar(beast["hp"], beast["max_hp"]),
        inline=False,
    )
    # The blow that just landed, on the shared card rather than in a private
    # message to whoever threw it. Every swing used to send its own ephemeral,
    # so a long fight buried the striker's screen under "Only you can see
    # this" - the one screen in the bot that got noisier the more you played.
    # The card is edited on every swing anyway, so this costs no message.
    if last is not None:
        blows = [f"{thousands(last['dealt'])} damage"]
        if (last.get("strikes") or 1) > 1:
            blows.append(f"{last['strikes']} strikes")
        if last.get("crits"):
            blows.append(
                f"{last['crits']} critical" + ("s" if last["crits"] > 1 else "")
            )
        card.add_field(
            name="Last blow" + (f" \N{EM DASH} {by}" if by else ""),
            value=" \N{BULLET} ".join(blows),
            inline=False,
        )

    card.set_footer(
        text=f"Rank {beast['rank']} \N{BULLET} through the line in "
        f"{humanise_duration(left)}"
    )
    return card


# ---------------------------------------------------------------------------
# Striking
# ---------------------------------------------------------------------------


class StrikeButton(discord.ui.Button):
    """One button, on the beast's own message, for anybody who can see it.

    Deliberately not restricted to one player: a horde beast is public, and the
    whole point is that somebody else can finish what you started.
    """

    def __init__(self, encounter_id: int, kind: str) -> None:
        self.encounter_id = encounter_id
        super().__init__(
            label="Strike" if kind != "king" else "Strike the King",
            emoji="\N{CROSSED SWORDS}",
            style=discord.ButtonStyle.danger
            if kind == "king"
            else discord.ButtonStyle.primary,
            custom_id=f"horde:strike:{encounter_id}",
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        try:
            hit = await db.fetch_one(
                "SELECT * FROM horde_strike(%s, %s)",
                (self.encounter_id, player["player_id"]),
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        beast = await fetch_beast(self.encounter_id)

        # The public message is the shared state, so it is edited rather than
        # replied to - five people swinging must not become five messages.
        try:
            await interaction.response.edit_message(
                embed=beast_card(beast, hit, interaction.user.display_name),
                view=None if beast["status"] != "alive" else BeastView(beast),
            )
        except discord.HTTPException:
            log.warning("could not edit the beast message", exc_info=True)



class BeastView(AnsweringView):
    def __init__(self, beast: dict) -> None:
        # No timeout: the beast's own clock decides when it is gone, and the
        # loop edits the message when it does. A view that timed out first
        # would leave a live beast nobody could hit.
        super().__init__(timeout=None)
        self.add_item(StrikeButton(beast["encounter_id"], beast["kind"]))


# ---------------------------------------------------------------------------
# The board
# ---------------------------------------------------------------------------


PLACES = ("\N{FIRST PLACE MEDAL}", "\N{SECOND PLACE MEDAL}",
          "\N{THIRD PLACE MEDAL}", "\N{SMALL BLUE DIAMOND}",
          "\N{SMALL BLUE DIAMOND}")


async def roll_lines(horde_id: int, top: int = 5) -> str:
    """Who is holding it, and what each of them has already earned.

    The chest count sits beside the ranking on purpose: the chests are
    thresholds and the ranking pays nobody, so a board that showed only the
    order would be quietly promising a prize for first.
    """
    rows = await db.fetch_all(
        "SELECT * FROM horde_leaders(%s, %s)", (horde_id, top)
    )
    if not rows:
        return "*Nobody has swung yet.*"

    return "\n".join(
        f"{PLACES[min(int(r['standing']) - 1, len(PLACES) - 1)]} "
        f"**{r['discord_name']}** \N{BULLET} {thousands(r['contribution'])}"
        + (f" \N{BULLET} {CHEST}x{r['chests_earned']}" if r["chests_earned"] else "")
        + (
            f"\n     {r['beasts_slain']} felled"
            + (f", {r['elites_slain']} of them elites" if r["elites_slain"] else "")
            if r["beasts_slain"] or r["elites_slain"]
            else ""
        )
        for r in rows
    )


async def board_card(tide: dict, player_id: int | None = None) -> discord.Embed:
    if tide["status"] == "won":
        head, colour = f"\N{SUNRISE OVER MOUNTAINS} {tide['region_name']} held", COLOUR_GOOD
    elif tide["status"] == "lost":
        head, colour = f"{SKULL} {tide['region_name']} is overrun", COLOUR_BAD
    elif tide["king_up"]:
        head, colour = f"{CROWN} The King is on the field", COLOUR_BAD
    else:
        head, colour = (
            f"{PAW} Beast Horde \N{EM DASH} {tide['region_name']}",
            COLOUR_INFO,
        )

    card = embed(
        head,
        f"Rank **{tide['rank']}** tide \N{BULLET} **{tide['hands']}** hand(s) "
        f"on the line \N{BULLET} **{tide['defenders']}** have fought",
        colour=colour,
    )

    card.add_field(
        name=f"The line \N{EM DASH} {tide['line_left']} more may pass",
        value=bar(tide["line_left"], tide["line_holds"])
        + f"\n{thousands(tide['beasts_lost'])} of {thousands(tide['line_holds'])} "
        "have got by",
        inline=False,
    )
    card.add_field(
        name="Slain",
        value=f"**{thousands(tide['beasts_slain'])}** "
        f"of {thousands(tide['beasts_total'])}"
        + (
            f"\n{thousands(tide['loose'])} loose in the channel"
            if tide["status"] in ("fighting", "king")
            else ""
        ),
        inline=True,
    )

    if player_id is not None:
        mine = await db.fetch_one(
            """
            SELECT horde_contribution(%(h)s, %(p)s) AS contribution,
                   horde_chests_earned(%(h)s, %(p)s) AS earned,
                   horde_king_chest_due(%(h)s, %(p)s) AS crown,
                   COALESCE((SELECT c.chest_taken FROM horde_contributions c
                             WHERE c.horde_id = %(h)s
                               AND c.player_id = %(p)s), 0) AS taken,
                   COALESCE((SELECT c.king_damage FROM horde_contributions c
                             WHERE c.horde_id = %(h)s
                               AND c.player_id = %(p)s), 0) AS bled,
                   COALESCE((SELECT c.swings FROM horde_contributions c
                             WHERE c.horde_id = %(h)s
                               AND c.player_id = %(p)s), 0) AS swings,
                   horde_beast_worth(%(h)s)
                       * game_config_value('horde_swing_worth') AS a_swing,
                   horde_chest_bar(%(h)s,
                       LEAST(3, horde_chests_earned(%(h)s, %(p)s) + 1)::smallint
                   ) AS next_bar
            """,
            {"h": tide["horde_id"], "p": player_id},
        )
        told = (
            f"**{thousands(mine['contribution'])}** contribution\n"
            f"{CHEST} {mine['earned']} of 3 chests earned"
            + (f", {mine['taken']} opened" if mine["taken"] else "")
        )
        # Swinging counts towards a chest whether or not the blow was a big
        # one, so the screen has to say so - otherwise somebody whose damage
        # cannot move the bar has no way to tell that turning up is the road.
        if mine["swings"]:
            told += f"\n{SWING} {thousands(mine['swings'])} swings on the line"
        if mine["earned"] < 3 and mine["a_swing"]:
            short = int(mine["next_bar"]) - int(mine["contribution"])
            if short > 0:
                more = -(-short // int(mine["a_swing"]))
                told += (
                    f"\n{more} more swing{'' if more == 1 else 's'}"
                    " would earn the next"
                )
        # The fourth is not on the ladder and must not read as though it were:
        # it is owed for meeting the King, and no ranking can take it.
        if mine["crown"]:
            told += f"\n{CROWN} **The King's chest** is yours to open"
        elif mine["bled"]:
            told += f"\n{CROWN} {thousands(mine['bled'])} into the King"
        # Tides that have already been and gone and still owe this cultivator
        # something. The board is about THIS tide; what you are owed is not,
        # and until 0413 no screen anywhere said so.
        stale = await db.fetch_value(
            "SELECT count(*) FROM horde_owed(%s) WHERE horde_id <> %s",
            (player_id, tide["horde_id"]),
        )
        if stale:
            told += (
                f"\n{CHEST} **{stale}** earlier tide(s) still owe you "
                "\N{EM DASH} open them below"
            )
        card.add_field(name="Yours", value=told, inline=True)

    card.add_field(
        name=f"The roll \N{EM DASH} {tide['defenders']} on it",
        value=await roll_lines(tide["horde_id"]),
        inline=False,
    )

    if tide["status"] in ("fighting", "king"):
        card.set_footer(
            text=f"{humanise_duration(max(0.0, float(tide['seconds_left'] or 0)))} "
            "left \N{EM DASH} strike what stands here, or /fight horde to walk "
            "the line alone. Chests are thresholds, not places: the roll pays "
            "nobody."
        )
    else:
        card.set_footer(text="/horde to open what you earned.")
    return card


# ---------------------------------------------------------------------------
# The line, walked alone
# ---------------------------------------------------------------------------
# The channel is where a crowd meets one big thing. This is the other lane:
# waves of weaker beasts, one at a time, each harder than the last, until you
# are put down. Both draw on the same pool, so a run here empties the sea the
# channel is drawing from - that is what makes it part of the tide rather than
# a minigame beside it.


HEART = "\N{BEATING HEART}"
BLADE = "\N{CROSSED SWORDS}"
SPARK = "\N{HIGH VOLTAGE SIGN}"


async def gauntlet_of(player_id: int) -> dict | None:
    return await db.fetch_one(
        "SELECT * FROM horde_gauntlet_board "
        "WHERE player_id = %s AND status = %s",
        (player_id, "fighting"),
    )


def gauntlet_card(run: dict, last: dict | None = None) -> discord.Embed:
    """Where the run stands, and what the last press did to it."""
    if run["status"] == "fallen":
        card = embed(
            f"{SKULL} Put down at wave {run['wave']}",
            f"**{run['felled']}** felled before the line took you. "
            "Nothing here follows you out \N{EM DASH} **/fight horde** again "
            "while the tide has beasts left.",
            colour=COLOUR_BAD,
        )
    elif run["status"] == "cleared":
        card = embed(
            f"\N{SUNRISE OVER MOUNTAINS} The sea is empty",
            f"**{run['felled']}** felled over {run['wave']} wave(s), and there "
            "is nothing left to send. What remains is in the channel.",
            colour=COLOUR_GOOD,
        )
    else:
        card = embed(
            f"{BLADE} The line \N{EM DASH} wave {run['wave']}",
            f"*{run['description']}*" if run.get("description") else None,
            colour=COLOUR_DEFAULT,
        )
        card.add_field(
            name=f"{PAW} {run['beast_name']} \N{EM DASH} "
            f"{thousands(run['beast_hp'])} / {thousands(run['beast_max_hp'])}",
            value=bar(run["beast_hp"], run["beast_max_hp"]),
            inline=False,
        )

    card.add_field(
        name=f"{HEART} You \N{EM DASH} {thousands(run['hp'])} / "
        f"{thousands(run['max_hp'])}",
        value=bar(run["hp"], run["max_hp"])
        + f"\n{SPARK} Qi `{thousands(run['qi'])} / {thousands(run['max_qi'])}`\n"
        + bar(run["qi"], run["max_qi"]),
        inline=False,
    )

    if last is not None:
        told = []
        if last["guarded"]:
            told.append(f"**Guard** \N{BULLET} +{thousands(last['qi_left'])} qi held")
        else:
            told.append(f"**{last['move_name']}**")
            told.append(f"{thousands(last['dealt'])} dealt")
            if last["strikes"] and last["strikes"] > 1:
                told.append(f"{last['strikes']} strikes")
            if last["crits"]:
                told.append(f"{last['crits']} critical")
            if last["qi_spent"]:
                told.append(f"\N{HIGH VOLTAGE SIGN}{thousands(last['qi_spent'])}")
        if last["taken"]:
            told.append(f"{thousands(last['taken'])} taken")
        if last["healed"]:
            told.append(f"{thousands(last['healed'])} drained back")
        if last["beast_down"]:
            told.append(f"**felled** (+{thousands(last['earned'])})")
        card.add_field(
            name=f"Wave {last['wave']}", value=" \N{BULLET} ".join(told), inline=False
        )

    card.add_field(
        name="This run",
        value=f"**{run['felled']}** felled \N{BULLET} "
        f"{thousands(run['damage_dealt'])} dealt",
        inline=True,
    )
    card.add_field(
        name="This tide",
        value=f"**{thousands(run['contribution'])}** contribution\n"
        f"{thousands(run['sea_left'])} still to come",
        inline=True,
    )
    return card


class GauntletSelect(discord.ui.Select):
    """The same choice a hunt asks for, against the same list.

    `usable_techniques` is the duel's, so a move that is affordable in one
    fight is affordable in the other and nobody has to learn a second set of
    costs. Unaffordable moves stay on the list and are refused, for the reason
    the duel gives: seeing that the good one is one Guard away is the whole
    decision.
    """

    def __init__(self, view: "GauntletView") -> None:
        self.walk = view
        options = []
        for row in view.techniques:
            cost = row["qi_cost"]
            options.append(
                discord.SelectOption(
                    label=f"{row['name']} \N{MIDDLE DOT} {thousands(cost)} qi"[:100],
                    value=str(row["technique_id"]),
                    description=(
                        f"{row['paths'] or 'untyped'} \N{MIDDLE DOT} "
                        f"power {thousands(row['base_power'])}"
                        + ("" if cost <= view.qi else " \N{MIDDLE DOT} not enough qi")
                    )[:100],
                    emoji=row["emoji"][:1] if row["emoji"] else None,
                )
            )
        super().__init__(placeholder="Strike with\N{HORIZONTAL ELLIPSIS}",
                         options=options, row=0)

    async def callback(self, interaction: discord.Interaction) -> None:
        await self.walk.act(interaction, "attack", int(self.values[0]))


class GuardButton(discord.ui.Button):
    def __init__(self) -> None:
        super().__init__(
            label="Guard",
            emoji="\N{SHIELD}",
            style=discord.ButtonStyle.secondary,
            row=1,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        await self.view.act(interaction, "guard")


class GauntletView(AnsweringView):
    """One exchange a press, with the technique named by the press.

    The whole-wave button this replaces was quicker and decided nothing: it
    swung with whatever `dungeon_default_move` returned, which is the same move
    every time. Qi is what turns the list into a choice, so the view rebuilds
    it after every exchange against what is actually left in the pool.
    """

    def __init__(
        self,
        gauntlet_id: int,
        user: discord.abc.User,
        techniques: list[dict],
        qi: int,
    ) -> None:
        super().__init__(timeout=900)
        self.gauntlet_id = gauntlet_id
        self.user = user
        self.techniques = techniques
        self.qi = qi
        self.build()

    def build(self) -> None:
        self.clear_items()
        if self.techniques:
            self.add_item(GauntletSelect(self))
        self.add_item(GuardButton())

    async def act(
        self,
        interaction: discord.Interaction,
        action: str,
        technique_id: int | None = None,
    ) -> None:
        try:
            last = await db.fetch_one(
                "SELECT * FROM horde_gauntlet_swing(%s, %s, %s)",
                (self.gauntlet_id, action, technique_id),
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        run = await db.fetch_one(
            "SELECT * FROM horde_gauntlet_board WHERE gauntlet_id = %s",
            (self.gauntlet_id,),
        )

        if run["status"] != "fighting":
            self.clear_items()
        else:
            # The pool moved, so what is affordable moved with it.
            self.qi = run["qi"]
            self.build()

        await interaction.response.edit_message(
            embed=gauntlet_card(run, last), view=self if self.children else discord.utils.MISSING
        )

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "Walk your own line \N{EM DASH} **/fight horde**.", ephemeral=True
            )
            return False
        return True


# ---------------------------------------------------------------------------
# The loop
# ---------------------------------------------------------------------------


class Horde(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot
        self.tick.start()

    async def cog_unload(self) -> None:
        self.tick.cancel()

    # -----------------------------------------------------------------------

    async def channel(self, tide: dict | None = None) -> discord.abc.Messageable | None:
        """Where this tide is being fought.

        The tide's own channel first: moving HORDE_CHANNEL_ID during a live
        event must not strand the beasts already standing in the old one. The
        config is the fallback, for a tide opened before 0223 and for the
        moment a new one is being placed.
        """
        channel_id = (tide or {}).get("channel_id") or config.horde_channel_id()
        if channel_id is None:
            return None
        try:
            return self.bot.get_channel(channel_id) or await self.bot.fetch_channel(
                channel_id
            )
        except Exception:
            log.warning("no horde channel at %s", channel_id, exc_info=True)
            return None

    async def post_beast(self, encounter_id: int, tide: dict | None = None) -> None:
        beast = await fetch_beast(encounter_id)
        if beast is None or beast["status"] != "alive":
            return
        room = await self.channel(tide)
        if room is None:
            return
        try:
            said = await room.send(embed=beast_card(beast), view=BeastView(beast))
        except Exception:
            log.warning("could not post a beast", exc_info=True)
            return
        await db.execute(
            "UPDATE horde_encounters SET message_id = %s WHERE encounter_id = %s",
            (said.id, encounter_id),
        )

    async def close_message(self, encounter_id: int, tide: dict | None = None) -> None:
        """Edit a beast's own message to say what became of it.

        Best-effort throughout: a message somebody deleted, a channel the bot
        lost access to, a restart between the kill and the edit - none of those
        are reasons to fail the tick that noticed.
        """
        beast = await fetch_beast(encounter_id)
        if beast is None or beast["message_id"] is None:
            return
        room = await self.channel(tide)
        if room is None:
            return
        try:
            said = await room.fetch_message(beast["message_id"])
            await said.edit(embed=beast_card(beast), view=None)
        except Exception:
            log.debug("could not close a beast message", exc_info=True)

    async def keep_board(self, tide: dict) -> None:
        """Post the board once, then edit it for the rest of the tide.

        A scoreboard that re-sent itself every twenty seconds would be the
        noisiest thing in a channel that is already filling with beasts. The
        message id lives on the row rather than in this process, so a restart
        keeps editing the same message instead of starting a second one.

        Best-effort throughout: somebody deleting the board is not a reason to
        stop running the tide.
        """
        room = await self.channel(tide)
        if room is None:
            return

        card = await board_card(tide)

        if tide["board_id"]:
            try:
                said = await room.fetch_message(tide["board_id"])
                await said.edit(embed=card)
                return
            except discord.NotFound:
                # Deleted. Fall through and post a new one rather than going
                # silent for the rest of the event.
                pass
            except Exception:
                log.debug("could not edit the board", exc_info=True)
                return

        try:
            said = await room.send(embed=card)
        except Exception:
            log.warning("could not post the board", exc_info=True)
            return

        await db.execute(
            "UPDATE beast_hordes SET board_id = %s WHERE horde_id = %s",
            (said.id, tide["horde_id"]),
        )
        # Pinning is a courtesy and needs Manage Messages, which the bot may
        # not have. A board that is not pinned is still a board.
        try:
            await said.pin(reason="the horde board")
        except Exception:
            log.debug("could not pin the board", exc_info=True)

    @tasks.loop(seconds=TICK_SECONDS)
    async def tick(self) -> None:
        """One cheap query when nothing is happening, and a channel when it is."""
        try:
            tide = await live_horde()
            if tide is None:
                # Nothing running, so this is the one moment a tide can start.
                # `horde_open_if_due` does the deciding - the rest since the
                # last one, how many are about, and the roll - so this stays a
                # single cheap call on a quiet tick.
                made = await db.fetch_value(
                    "SELECT horde_open_if_due(%s)", (config.horde_channel_id(),)
                )
                if made is None:
                    return

                tide = await db.fetch_one(
                    "SELECT * FROM horde_board WHERE horde_id = %s", (made,)
                )
                log.info(
                    "a tide broke over %s at rank %s: %s beasts, line holds %s",
                    tide["region_code"], tide["rank"],
                    tide["beasts_total"], tide["line_holds"],
                )
                # `keep_board` posts the board the first time it is called
                # and edits it thereafter, so this both announces the tide and
                # is the same call the rest of the tick makes.

            # What got past while nobody was looking, recorded before anything
            # else so the verdict below reads the truth.
            gone = await db.fetch_all(
                """
                SELECT e.encounter_id FROM horde_encounters e
                WHERE e.horde_id = %s AND e.status = 'alive'
                  AND e.expires_at <= now()
                """,
                (tide["horde_id"],),
            )
            await db.execute("SELECT horde_sweep(%s)", (tide["horde_id"],))
            for row in gone:
                await self.close_message(row["encounter_id"], tide)

            # Anything killed since the last tick, tidied.
            for row in await db.fetch_all(
                """
                SELECT e.encounter_id FROM horde_encounters e
                WHERE e.horde_id = %s AND e.status = 'slain'
                  AND e.message_id IS NOT NULL
                  AND e.settled_at > now() - make_interval(secs => %s)
                """,
                (tide["horde_id"], TICK_SECONDS * 2),
            ):
                await self.close_message(row["encounter_id"], tide)

            # Re-read after the sweep so the board never shows a line that
            # has already moved.
            tide = await db.fetch_one(
                "SELECT * FROM horde_board WHERE horde_id = %s",
                (tide["horde_id"],),
            )
            standing = tide["standing"]

            if standing == "king":
                made = await db.fetch_value(
                    "SELECT horde_king_rise(%s)", (tide["horde_id"],)
                )
                if made is not None:
                    await self.post_beast(made, tide)
                # The King rising is the moment the board most needs to be
                # right, and the early return used to skip it.
                await self.keep_board(await db.fetch_one(
                    "SELECT * FROM horde_board WHERE horde_id = %s",
                    (tide["horde_id"],)))
                return

            if standing in ("won", "lost"):
                await self.finish(tide)
                return

            await self.keep_board(tide)

            # Top the board back up TO ITS CAP, not by one. The first live
            # tide ran with an empty channel most of the time: one spawn a
            # tick against a defender who one-shots things meant the board
            # never reached the three beasts it was allowed. `horde_spawn`
            # refuses past the cap, so this stops on its own; the bound here
            # is only so a burst is a burst Discord will accept.
            for _ in range(5):
                made = await db.fetch_value(
                    "SELECT horde_spawn(%s)", (tide["horde_id"],)
                )
                if made is None:
                    break
                await self.post_beast(made, tide)
        except Exception:
            # A loop that dies takes the whole event with it and says nothing.
            log.exception("the horde tick failed")

    @tick.before_loop
    async def before_tick(self) -> None:
        # Under the test harness `bot` is a stand-in with no gateway, so
        # this raises and discord.py reports it as an unretrieved task
        # exception - three of them, every test, drowning the output that
        # says which assertion actually failed. A loop that cannot wait
        # for a client it does not have simply does not run.
        try:
            await self.bot.wait_until_ready()
        except RuntimeError:
            self.tick.cancel()
            return
        await self.adopt_standing_beasts()

    async def adopt_standing_beasts(self) -> None:
        """Take ownership of the buttons on boards posted before this process.

        `BeastView` is built to outlive a restart - no timeout, and every
        StrikeButton carries a custom_id - but discord.py only routes an
        interaction to a persistent view it has been TOLD about. Nothing told
        it, so every restart during a tide silently killed every Strike button
        already on the board: the beasts and the King went on standing, the
        message went on showing them, and pressing the button did nothing.
        The log said `referencing unknown view ... Discarding` and the players
        said the King was broken.

        Re-registering by encounter id is enough, because that is the whole of
        what the button carries.
        """
        try:
            standing = await db.fetch_all(
                """
                SELECT e.encounter_id, e.kind
                FROM horde_encounters e
                JOIN beast_hordes h ON h.horde_id = e.horde_id
                WHERE e.status = 'alive' AND h.status IN ('fighting', 'king')
                """
            )
        except Exception:
            log.warning("could not look up standing beasts", exc_info=True)
            return

        for beast in standing:
            self.bot.add_view(BeastView(beast))

        if standing:
            log.info(
                "adopted %s standing beast(s) from before the restart", len(standing)
            )

    async def finish(self, tide: dict) -> None:
        call = await db.fetch_value("SELECT horde_settle(%s)", (tide["horde_id"],))
        if call not in ("won", "lost"):
            return
        done = await db.fetch_one(
            "SELECT * FROM horde_board WHERE horde_id = %s", (tide["horde_id"],)
        )
        # Leave the board on the final state rather than on the last tick
        # before it - somebody scrolling back should not read a live line.
        await self.keep_board(done)

        room = await self.channel(done)
        if room is None:
            return
        card = await board_card(done)
        card.add_field(
            name="Afterwards",
            value="\n".join(
                f"\N{BULLET} {r['kind'].replace('_', ' ')} "
                f"{'+' if r['magnitude'] > 0 else ''}"
                f"{round(float(r['magnitude']) * 100)}% for "
                f"{humanise_duration(float(r['seconds']))}"
                for r in await db.fetch_all(
                    "SELECT kind, magnitude, "
                    "EXTRACT(EPOCH FROM (until - now())) AS seconds "
                    "FROM region_effects WHERE region_code = %s AND until > now()",
                    (done["region_code"],),
                )
            )
            or "*nothing lingers*",
            inline=False,
        )
        try:
            await room.send(embed=card)
        except Exception:
            log.warning("could not post the verdict", exc_info=True)

    # -----------------------------------------------------------------------

    fight = app_commands.Group(
        name="fight", description="Take something on directly."
    )

    @fight.command(
        name="horde", description="Walk the line: waves of beasts until you drop."
    )
    async def fight_horde(self, interaction: discord.Interaction) -> None:
        """Resume the run they are on, or start one.

        Resuming rather than refusing is the whole reason there is no stand-down
        button: a closed message, a timed-out view or a restart cannot strand
        anybody, so the run only ever ends by being lost or by the sea running
        out.
        """
        player = await require_player(interaction.user)

        run = await gauntlet_of(player["player_id"])
        if run is None:
            try:
                made = await db.fetch_value(
                    "SELECT horde_gauntlet_open(%s)", (player["player_id"],)
                )
            except psycopg.errors.CheckViolation as exc:
                raise refuse(exc) from exc
            run = await db.fetch_one(
                "SELECT * FROM horde_gauntlet_board WHERE gauntlet_id = %s", (made,)
            )

        view = GauntletView(
            run["gauntlet_id"],
            interaction.user,
            await usable_techniques(player["player_id"], run["max_qi"]),
            run["qi"],
        )
        # Ephemeral: this is one cultivator's fight and it takes a press per
        # exchange. The board in the channel is where the tide is public.
        await interaction.response.send_message(
            embed=gauntlet_card(run),
            view=view if run["status"] == "fighting" else discord.utils.MISSING,
            ephemeral=True,
        )

    # -----------------------------------------------------------------------

    @app_commands.command(description="The Beast Horde, and what you are owed.")
    async def horde(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        tide = await live_horde() or await latest_horde()

        if tide is None:
            raise GameError(
                "No tide has ever come. They arrive on their own \N{EM DASH} "
                "watch the horde channel."
            )

        if tide["status"] in ("fighting", "king"):
            await db.execute("SELECT horde_sweep(%s)", (tide["horde_id"],))
            tide = await db.fetch_one(
                "SELECT * FROM horde_board WHERE horde_id = %s", (tide["horde_id"],)
            )

        owed = await db.fetch_value(
            "SELECT count(*) FROM horde_owed(%s)", (player["player_id"],)
        )
        view = ClaimView(tide, player["player_id"], interaction.user, owed)
        await interaction.response.send_message(
            embed=await board_card(tide, player["player_id"]),
            view=view if view.children else discord.utils.MISSING,
        )


class ClaimButton(discord.ui.Button):
    def __init__(self, tide: dict, player_id: int) -> None:
        self.tide = tide
        self.player_id = player_id
        super().__init__(
            label="Open your chests",
            emoji=CHEST,
            style=discord.ButtonStyle.success,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        try:
            # Everything owed, across every finished tide - not just the one
            # the board happens to be showing. Before 0413 a chest had to be
            # opened in the gap between one tide ending and the next starting,
            # and 21 of them had quietly missed that window.
            got = await db.fetch_value(
                "SELECT horde_claim_all(%s)", (self.player_id,)
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        tides = got.get("tides") or 1
        card = embed(
            f"{CHEST} {got['chests']} chest(s) opened",
            (f"Across **{tides}** tides." if tides > 1
             else f"Through {got['through']} of 3.")
            + (f"  {CROWN} **and the King's**" if got.get("king") else ""),
            colour=COLOUR_GOOD,
        )
        def merged(said: list[str] | None) -> str:
            """One line per kind, however many chests happened to roll it.

            Each chest spills its own pile, so a four chest opening can name
            Boar Tusk three times at three different numbers. That is honest
            and it reads like a bug - and it buries how wide the spread
            actually was under a wall of repeats.
            """
            piles: dict[str, int] = {}
            for one in said or []:
                count, _, name = one.partition("x ")
                piles[name] = piles.get(name, 0) + int(count)
            return ", ".join(
                f"{thousands(n)}x {name}"
                for name, n in sorted(piles.items(), key=lambda kv: -kv[1])
            )

        lines = [f"\N{LARGE BLUE DIAMOND} {thousands(got['stones'])} Spirit Stones"]
        # Beast materials first: they are what a horde is for, and burying
        # them under the herbs was how nobody noticed the herbs were the whole
        # reward.
        if got.get("parts"):
            lines.append("\N{PAW PRINTS} " + merged(got["parts"]))
        if got.get("herbs"):
            lines.append("\N{HERB} " + merged(got["herbs"]))
        if got.get("pages"):
            lines.append(f"\N{SCROLL} {got['pages']} page(s)")
        for name in got.get("eggs") or []:
            lines.append(f"\N{HATCHING CHICK} {name}")
        for name in got.get("gu") or []:
            lines.append(f"\N{BUG} **{name}**")

        # A full four-chest opening names a lot of things; the field cap is
        # 1024 and a claim that 400s is a claim that silently ate the loot.
        told = "\n".join(lines)
        if len(told) > 1024:
            told = told[:1000].rsplit(",", 1)[0] + "\N{HORIZONTAL ELLIPSIS} (see /inventory)"
        card.add_field(name="Carried off", value=told, inline=False)

        self.disabled = True
        await interaction.response.edit_message(view=self.view)
        await interaction.followup.send(embed=card)


class ClaimView(AnsweringView):
    def __init__(self, tide: dict, player_id: int, user: discord.abc.User,
                 owed: int = 0) -> None:
        super().__init__(timeout=300)
        self.user = user
        # `owed` counts finished tides with something still on them, so the
        # button is offered while a NEW tide is running too. Keying it on the
        # shown tide's status meant a live tide hid the button outright, which
        # was half of how chests went unclaimed.
        if owed:
            self.add_item(ClaimButton(tide, player_id))

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "Open your own.", ephemeral=True
            )
            return False
        return True


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Horde(bot))
