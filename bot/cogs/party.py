"""Peer Trial parties: /party.

Cultivators of ONE realm invite each other, see what the party can and cannot
answer, and are given a channel of their own that goes away when they are done.

The Trial itself is not here yet. This is the door and the room, built so the
fight can be hung on them without moving either.

ROLES ARE SHOWN, NOT CHOSEN. Nobody picks "tank" from a menu - a tank is
whoever brought a taunt. The roster reports what each peer can answer so the
screen can say "no one here can pull a blow", which is information rather than
a gate: a party that cannot answer everything should be told so and then
allowed to try anyway.

THE CHANNEL IS A NICETY, NOT A DEPENDENCY. Making one needs Manage Channels on
the bot's role, which is a deployment fact rather than a game rule. Every path
here works without it - the party forms, shows its roster, seals and ends
whether or not a room could be made, and the leader is told plainly when one
could not.
"""

import logging

import discord
import psycopg
from discord import app_commands
from discord.ext import commands

from bot import config
from bot import database as db
from bot.formatting import (
    COLOUR_BAD,
    COLOUR_GOOD,
    COLOUR_INFO,
    embed,
    thousands,
)
from bot.players import GameError, require_player, settle_passive
from bot.views import AnsweringView

log = logging.getLogger("gu.party")

DOT = "\N{BULLET}"
YES = "\N{WHITE HEAVY CHECK MARK}"
NO = "\N{HEAVY MULTIPLICATION X}"

# The four answers a Peer Trial asks for, in the order the threats come at you.
ANSWERS = (
    ("can_pull", "Pull a blow", "\N{SHIELD}"),
    ("can_shield", "Harden", "\N{BRICK}"),
    ("can_mend", "Mend", "\N{HERB}"),
    ("can_strike", "Strike", "\N{CROSSED SWORDS}"),
)


def refuse(exc: psycopg.errors.CheckViolation) -> GameError:
    return GameError(str(exc).splitlines()[0].capitalize())


async def fetch_party(player_id: int) -> dict | None:
    return await db.fetch_one(
        """
        SELECT p.party_id, p.leader_id, p.realm_rank, p.status, p.channel_id,
               l.discord_name AS leader_name,
               r.name AS realm_name,
               (SELECT count(*) FROM trial_party_members m
                WHERE m.party_id = p.party_id) AS members,
               game_config_value('trial_party_min')::int AS wants,
               game_config_value('trial_party_max')::int AS holds
        FROM trial_parties p
        JOIN players l ON l.player_id = p.leader_id
                -- LEFT JOIN onto `realms` BY RANK, and `trial_party_open` stores
                -- STANDING there since 0519 - so a Venerable's trial matched no
                -- row and the card fell back to "a trial of realm 22". The
                -- Venerable ladder is a second table, so it needs a second look.
        LEFT JOIN LATERAL (
            SELECT COALESCE(
                (SELECT rr.name FROM realms rr
                 WHERE rr.rank = p.realm_rank ORDER BY rr.realm_id LIMIT 1),
                (SELECT v.name FROM venerable_ranks v
                 WHERE v.rank = p.realm_rank)
            ) AS name
        ) r ON TRUE
        WHERE p.party_id = trial_party_of(%s)
        LIMIT 1
        """,
        (player_id,),
    )


async def fetch_roster(party_id: int) -> list[dict]:
    return await db.fetch_all(
        "SELECT * FROM trial_party_roster(%s)", (party_id,)
    )


async def render_party(party: dict, roster: list[dict]) -> discord.Embed:
    """The party, and what it can answer.

    The gaps are drawn as plainly as the strengths. A party that finds out it
    has no one to pull a blow while the thing is already fixed on somebody has
    been told too late.
    """
    card = embed(
        f"\N{BUSTS IN SILHOUETTE} {party['leader_name']}'s party",
        f"A trial of **{party['realm_name'] or 'realm ' + str(party['realm_rank'])}** "
        f"{DOT} {party['members']} of {party['holds']}"
        + (f"\n*Sealed. The door is shut behind you.*"
           if party["status"] == "sealed" else ""),
        colour=COLOUR_GOOD if party["status"] == "sealed" else COLOUR_INFO,
    )

    for one in roster:
        answers = " ".join(
            f"{glyph}{YES if one[key] else NO}" for key, _label, glyph in ANSWERS
        )
        card.add_field(
            name=("\N{CROWN} " if one["is_leader"] else "")
            + str(one["discord_name"]),
            value=(
                f"\N{HEAVY BLACK HEART} {thousands(one['max_hp'])} "
                f"{DOT} \N{FLEXED BICEPS} {thousands(one['strength'])} "
                f"{DOT} \N{BRICK} {thousands(one['defense'])}\n{answers}"
            ),
            inline=False,
        )

    # What the party as a whole is short of. This is the line the screen
    # exists for: it is cheap to read here and expensive to learn in there.
    missing = [
        label for key, label, _glyph in ANSWERS
        if not any(one[key] for one in roster)
    ]
    if missing:
        card.add_field(
            name="\N{WARNING SIGN} Nobody here can",
            value=", ".join(missing).lower()
            + "\nA Trial asks all four. You may still go.",
            inline=False,
        )
    elif party["members"] >= party["wants"]:
        card.add_field(
            name=f"{YES} Every answer is covered",
            value="Between you, all four.",
            inline=False,
        )

    if party["status"] == "forming" and party["members"] < party["wants"]:
        card.set_footer(
            text=f"A Peer Trial wants {party['wants']}. Invite {party['wants'] - party['members']} more."
        )
    return card


# ---------------------------------------------------------------------------
# The room
# ---------------------------------------------------------------------------


async def open_room(
    bot: commands.Bot, party: dict, roster: list[dict]
) -> tuple[int | None, str | None]:
    """A channel only the party can see. Returns (channel_id, why_not).

    Every failure here is survivable and none of them should stop a party
    setting out, so this reports rather than raises. The commonest by far is
    the bot simply not having Manage Channels, which is a thing somebody has
    to fix in Discord rather than in the game.
    """
    guild_id = config.guild_id()
    if guild_id is None:
        return None, "no guild is configured"

    guild = bot.get_guild(guild_id)
    if guild is None:
        return None, "the guild is not in reach"

    me = guild.me
    if me is None or not me.guild_permissions.manage_channels:
        return None, "I do not have Manage Channels here"

    overwrites = {
        guild.default_role: discord.PermissionOverwrite(view_channel=False),
        me: discord.PermissionOverwrite(view_channel=True, send_messages=True),
    }
    # The roster answers about cultivators; Discord wants accounts. Asked here
    # rather than added to `trial_party_roster`, which has no business knowing
    # about Discord at all.
    for row in await db.fetch_all(
        "SELECT p.discord_id FROM trial_party_members m "
        "JOIN players p ON p.player_id = m.player_id WHERE m.party_id = %s",
        (party["party_id"],),
    ):
        if not row["discord_id"]:
            continue
        # fetch_member, not get_member: the cache behind get_member is filled
        # by the privileged members intent, which this bot deliberately does
        # not ask for (`Intents.none()` plus guilds). Without it get_member
        # returns None for nearly everybody and the party would be locked out
        # of its own room. A party is at most five, so five REST calls is the
        # right price for not needing a privileged intent.
        try:
            member = await guild.fetch_member(int(row["discord_id"]))
        except (discord.NotFound, discord.Forbidden, discord.HTTPException):
            continue
        overwrites[member] = discord.PermissionOverwrite(
            view_channel=True, send_messages=True
        )

    try:
        channel = await guild.create_text_channel(
            name=f"trial-{party['party_id']}",
            overwrites=overwrites,
            topic=(
                f"A Peer Trial of realm {party['realm_rank']}. "
                "This room goes when the trial does."
            ),
            reason=f"Peer Trial party {party['party_id']}",
        )
    except discord.Forbidden:
        return None, "Discord refused the room"
    except discord.HTTPException as exc:
        log.warning("could not make a room for party %s", party["party_id"],
                    exc_info=exc)
        return None, "Discord would not make the room"

    await db.execute(
        "SELECT trial_party_set_channel(%s, %s)",
        (party["party_id"], channel.id),
    )
    return channel.id, None


async def close_room(bot: commands.Bot, channel_id: int | None) -> None:
    """Take the room away. Silent on every failure: a party that has ended has
    ended, and a room that was already gone is the outcome we wanted."""
    if channel_id is None:
        return
    try:
        channel = bot.get_channel(channel_id) or await bot.fetch_channel(channel_id)
    except (discord.NotFound, discord.Forbidden, discord.HTTPException):
        return
    if channel is None:
        return
    try:
        await channel.delete(reason="The Peer Trial party ended")
    except (discord.NotFound, discord.Forbidden, discord.HTTPException) as exc:
        log.warning("could not close room %s", channel_id, exc_info=exc)


# ---------------------------------------------------------------------------
# The screen
# ---------------------------------------------------------------------------


class InviteSelect(discord.ui.UserSelect):
    def __init__(self, screen: "PartyView") -> None:
        self.screen = screen
        super().__init__(
            placeholder="Invite a peer of your realm\N{HORIZONTAL ELLIPSIS}",
            min_values=1, max_values=1, row=0,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        target = self.values[0]

        them = await db.fetch_one(
            "SELECT player_id, discord_name FROM players "
            "WHERE discord_id = %s AND deleted_at IS NULL",
            (target.id,),
        )
        if them is None:
            raise GameError(
                f"**{target.display_name}** has not started cultivating yet."
            )

        try:
            await db.fetch_one(
                "SELECT * FROM trial_party_invite(%s, %s)",
                (player["player_id"], them["player_id"]),
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        await self.screen.reload()
        await interaction.response.edit_message(
            embed=await self.screen.card(), view=self.screen
        )
        await interaction.followup.send(
            f"\N{ENVELOPE} {target.mention}, **{player['discord_name']}** asks you "
            f"to stand with them. **/party** to answer.",
            allowed_mentions=discord.AllowedMentions(users=True),
        )


class SealButton(discord.ui.Button):
    def __init__(self, screen: "PartyView", ready: bool) -> None:
        self.screen = screen
        super().__init__(
            label="Set out", emoji="\N{DOOR}",
            style=discord.ButtonStyle.success if ready else discord.ButtonStyle.secondary,
            disabled=not ready, row=1,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        try:
            await db.fetch_one(
                "SELECT * FROM trial_party_seal(%s)", (player["player_id"],)
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        await self.screen.reload()
        room, why_not = await open_room(
            interaction.client, self.screen.party, self.screen.roster
        )

        said = (
            f"\N{DOOR} The party is sealed."
            + (f" Your room is <#{room}>." if room
               else f"\n*No room could be made \N{EM DASH} {why_not}. "
                    "The trial goes ahead without one.*")
        )
        await self.screen.reload()
        await interaction.response.edit_message(
            embed=await self.screen.card(), view=self.screen
        )
        await interaction.followup.send(said)


class LeaveButton(discord.ui.Button):
    def __init__(self, screen: "PartyView", is_leader: bool) -> None:
        self.screen = screen
        super().__init__(
            label="Disband" if is_leader else "Leave",
            style=discord.ButtonStyle.danger, row=1,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        try:
            gone = await db.fetch_one(
                "SELECT * FROM trial_party_leave(%s)", (player["player_id"],)
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        # The room goes with the party, not with the person who left it.
        if gone["disbanded"]:
            await close_room(interaction.client, gone["channel_id"])

        for item in self.screen.children:
            item.disabled = True
        await interaction.response.edit_message(
            embed=embed(
                "\N{BUSTS IN SILHOUETTE} " + ("Disbanded" if gone["disbanded"]
                                              else "You step away"),
                "The party is over and its room with it."
                if gone["disbanded"] else "They go on without you.",
                colour=COLOUR_BAD,
            ),
            view=self.screen,
        )
        self.screen.stop()


class AnswerButton(discord.ui.Button):
    """Accepting or declining an invitation."""

    def __init__(self, invite: dict, accept: bool) -> None:
        self.invite = invite
        self.accept = accept
        super().__init__(
            label="Stand with them" if accept else "Decline",
            emoji="\N{HANDSHAKE}" if accept else None,
            style=discord.ButtonStyle.success if accept else discord.ButtonStyle.secondary,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        try:
            got = await db.fetch_one(
                "SELECT * FROM trial_party_answer(%s, %s, %s)",
                (player["player_id"], self.invite["party_id"], self.accept),
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        if not got["joined"]:
            await interaction.response.edit_message(
                embed=embed("\N{ENVELOPE} Declined",
                            "They will have to find another.",
                            colour=COLOUR_INFO),
                # MISSING rather than None: discord.py treats None as "leave
                # the view alone" in some paths and crashes in others, which
                # is why the suite refuses `view=None` outright.
                view=discord.utils.MISSING,
            )
            return

        party = await fetch_party(player["player_id"])
        roster = await fetch_roster(party["party_id"])
        view = PartyView(player["player_id"], interaction.user, party, roster)
        await interaction.response.edit_message(
            embed=await view.card(), view=view
        )


class PartyView(AnsweringView):
    def __init__(self, player_id: int, user: discord.abc.User,
                 party: dict, roster: list[dict]) -> None:
        super().__init__(timeout=900)
        self.player_id = player_id
        self.user = user
        self.party = party
        self.roster = roster
        self.build()

    async def reload(self) -> None:
        self.party = await fetch_party(self.player_id)
        if self.party is not None:
            self.roster = await fetch_roster(self.party["party_id"])
        self.build()

    async def card(self) -> discord.Embed:
        if self.party is None:
            return embed("\N{BUSTS IN SILHOUETTE} No party",
                         "It is over.", colour=COLOUR_INFO)
        return await render_party(self.party, self.roster)

    def build(self) -> None:
        self.clear_items()
        if self.party is None:
            return
        is_leader = self.party["leader_id"] == self.player_id
        forming = self.party["status"] == "forming"

        if is_leader and forming and self.party["members"] < self.party["holds"]:
            self.add_item(InviteSelect(self))
        if is_leader and forming:
            self.add_item(
                SealButton(self, self.party["members"] >= self.party["wants"]))
        self.add_item(LeaveButton(self, is_leader))


class Party(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @app_commands.command(
        description="Open a Peer Trial party, or see the one you are in."
    )
    async def party(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])

        # An invitation outranks everything: somebody is waiting on an answer.
        invite = await db.fetch_one(
            """
            SELECT i.party_id, p.realm_rank, l.discord_name AS leader_name,
                   r.name AS realm_name
            FROM trial_party_invites i
            JOIN trial_parties p ON p.party_id = i.party_id
            JOIN players l ON l.player_id = p.leader_id
                    -- LEFT JOIN onto `realms` BY RANK, and `trial_party_open` stores
                    -- STANDING there since 0519 - so a Venerable's trial matched no
                    -- row and the card fell back to "a trial of realm 22". The
                    -- Venerable ladder is a second table, so it needs a second look.
            LEFT JOIN LATERAL (
                SELECT COALESCE(
                    (SELECT rr.name FROM realms rr
                     WHERE rr.rank = p.realm_rank ORDER BY rr.realm_id LIMIT 1),
                    (SELECT v.name FROM venerable_ranks v
                     WHERE v.rank = p.realm_rank)
                ) AS name
            ) r ON TRUE
            WHERE i.player_id = %s AND i.answered_at IS NULL
              AND p.status = 'forming'
              AND i.sent_at > now() - make_interval(
                  mins => game_config_value('trial_invite_minutes')::int)
            ORDER BY i.sent_at DESC LIMIT 1
            """,
            (player["player_id"],),
        )
        if invite is not None and await fetch_party(player["player_id"]) is None:
            card = embed(
                "\N{ENVELOPE} You are asked to stand with them",
                f"**{invite['leader_name']}** is gathering a trial of "
                f"**{invite['realm_name'] or invite['realm_rank']}**.",
                colour=COLOUR_INFO,
            )
            view = AnsweringView(timeout=600)
            view.add_item(AnswerButton(invite, True))
            view.add_item(AnswerButton(invite, False))
            await interaction.response.send_message(embed=card, view=view)
            return

        party = await fetch_party(player["player_id"])
        if party is None:
            try:
                await db.fetch_value(
                    "SELECT trial_party_open(%s)", (player["player_id"],)
                )
            except psycopg.errors.CheckViolation as exc:
                raise refuse(exc) from exc
            party = await fetch_party(player["player_id"])

        roster = await fetch_roster(party["party_id"])
        view = PartyView(player["player_id"], interaction.user, party, roster)
        await interaction.response.send_message(
            embed=await view.card(), view=view
        )


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Party(bot))
