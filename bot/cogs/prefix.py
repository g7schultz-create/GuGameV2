"""Typing `I hunt` instead of `/hunt`, or `I h`.

Discord runs slash commands on an Interaction; a chat message has none. Rather
than write a second copy of thirty-nine commands, this adapts a Message into
the small part of the Interaction surface a command body actually touches -
`user`, `response.send_message`, `followup.send`, `original_response` and the
`is_done` flag. Ten things, checked against the whole `bot/` tree.

**Components keep working.** Only the FIRST response needs adapting: once the
bot posts a message carrying a View, every button and select press produces a
real Interaction, so pickers stay ephemeral and modals open normally. That is
what makes the adapter small enough to be honest.

**Silence is the default.** The prefix is an English pronoun, and "I travel a
lot" must not start a journey. Two rules keep it quiet: a command that takes no
arguments is only run when nothing follows it, and an argument that will not
convert is treated as prose rather than as a mistake to complain about. The
command's own refusals do answer - once it is running, the player meant it.

Nothing is ephemeral here, because a plain message cannot be. Anything that
would have been private is posted as a reply instead.
"""

import asyncio
import contextlib
import logging
import re

import discord
from discord import app_commands
from discord.ext import commands

from bot import database as db
from bot.formatting import error_embed
from bot.players import GameError

# Discord answers a send with a 5xx now and then, and the command is finished
# by the time it does. Three tries costs at most a second and a half.
SEND_TRIES = 3
SEND_BACKOFF = 0.4

log = logging.getLogger("gu.prefix")

PREFIX = "i"

# Short forms, CHOSEN rather than derived.
#
# Deriving them from unique prefixes was the obvious idea and it does not
# survive the command list: `f` is both focus and forge, `m` is manual, manuals
# and mine, and `h` is the only letter in the game that is unambiguous today.
# Worse, a derived abbreviation MOVES - `i f` would quietly stop meaning forge
# the day anything else starting with F ships.
#
# So the meaning is written down. A real command name always wins over an
# alias, so nothing here can shadow `/manual` or `/focus`; the table is only
# consulted when the typed word is not a command at all.
ALIASES = {
    # The world loop
    "g": "gather",
    "m": "mine",
    "h": "hunt",
    "e": "explore",
    "t": "travel",
    "w": "where",
    # The crafts
    "f": "forge",
    "a": "alchemy",
    "r": "refine",
    "rg": "refinegu",
    # The screens worth checking often
    "d": "daily",
    "cd": "cooldowns",
    "help": "tutorial",
    "tut": "tutorial",
    "re": "rest",
    "me": "meditate",
    "c": "cultivation",
    "p": "profile",
    "i": "inventory",
    "ge": "gear",
    "ph": "physique",
    "pr": "professions",
    "in": "insight",
    "bt": "breakthrough",
    "ub": "unbind",
    "te": "temper",
    "dw": "dwelling",
    "bk": "broker",
    "fi": "find",
}


# ---------------------------------------------------------------------------
# The adapter
# ---------------------------------------------------------------------------


class MessageResponse:
    """`interaction.response`, backed by a channel."""

    def __init__(self, shim: "MessageInteraction") -> None:
        self._shim = shim
        self._done = False

    def is_done(self) -> bool:
        return self._done

    async def send_message(
        self, content=None, *, embed=None, view=None, ephemeral=False, **_
    ) -> None:
        self._done = True
        # A reply rather than a bare send: the answer stays attached to the
        # line that asked for it, which is the nearest thing to ephemeral a
        # plain message has.
        self._shim.sent = await reply_through_a_hiccup(
            self._shim.message,
            content=content,
            embed=embed,
            view=view if view is not None else discord.utils.MISSING,
        )

    async def defer(self, *, ephemeral: bool = False, thinking: bool = False) -> None:
        self._done = True
        await self._shim.message.channel.typing()

    async def edit_message(self, **_):
        raise RuntimeError(
            "a command body cannot edit a message it has not sent yet; "
            "this only happens inside a View, which has a real interaction"
        )

    async def send_modal(self, modal) -> None:
        raise RuntimeError(
            "a modal needs a real interaction. Open it from a component, "
            "which has one, rather than from a command body"
        )


async def reply_through_a_hiccup(message, **kwargs):
    """Reply, and do not lose the command to one bad second at Discord.

    A 5xx from the send is not the game failing - the work is already done and
    the embed is already built - but it reached the player as "Something broke
    on our side", which is both alarming and untrue. `I alchemy` died that way
    at 14:14 with a 503 whose body was an upstream connect error; the cauldron
    behind it had rendered perfectly.

    Discord's own client retries nothing above 500 here, so this does: three
    tries with a short backoff. A failure that survives all three is a real
    outage and is allowed to raise.
    """
    last = None
    for attempt in range(SEND_TRIES):
        try:
            return await message.reply(mention_author=False, **kwargs)
        except discord.DiscordServerError as exc:
            last = exc
            log.warning(
                "discord %s on reply, attempt %s of %s",
                exc.status, attempt + 1, SEND_TRIES,
            )
            if attempt + 1 < SEND_TRIES:
                await asyncio.sleep(SEND_BACKOFF * (attempt + 1))
    raise last


class MessageFollowup:
    def __init__(self, shim: "MessageInteraction") -> None:
        self._shim = shim

    async def send(self, content=None, *, embed=None, view=None, ephemeral=False, **_):
        sent = await self._shim.message.channel.send(
            content=content,
            embed=embed,
            view=view if view is not None else discord.utils.MISSING,
        )
        if self._shim.sent is None:
            self._shim.sent = sent
        return sent


class MessageInteraction:
    """Enough of `discord.Interaction` to run a command body against."""

    def __init__(self, message: discord.Message, command, client) -> None:
        self.message = message
        self.user = message.author
        self.channel = message.channel
        self.guild = message.guild
        self.client = client
        self.command = command
        self.sent: discord.Message | None = None
        self.response = MessageResponse(self)
        self.followup = MessageFollowup(self)

    async def original_response(self) -> discord.Message | None:
        return self.sent


# ---------------------------------------------------------------------------
# Finding the command, and reading its arguments
# ---------------------------------------------------------------------------


def resolve(tree: app_commands.CommandTree, words: list[str]):
    """Walk the tree by name. Returns (command, remaining words) or None.

    Groups are walked too, so `I dev ready` reaches the same place `/dev ready`
    does without this knowing that `dev` exists.

    A short form is tried only after the full name misses, which is what keeps
    the table from being able to shadow a real command. It is looked up against
    whichever pool the walk has reached, so an alias cannot smuggle a top-level
    command into a group: `I dev r` finds nothing rather than refining.
    """
    node = None
    pool = {c.name: c for c in tree.get_commands()}

    for index, word in enumerate(words):
        key = word.lower()
        found = pool.get(key) or pool.get(ALIASES.get(key, ""))
        if found is None:
            return None
        node = found
        if isinstance(node, app_commands.Group):
            pool = {c.name: c for c in node.commands}
            continue
        return node, words[index + 1 :]

    return None


async def resolve_user(shim: MessageInteraction, raw: str):
    """A mention, an id or a name, into somebody.

    This used to go through `commands.UserConverter`, which needs a
    `commands.Context` - and reached for `Context.from_message`, which is not
    a discord.py API and never has been. Every prefix command taking a user
    raised AttributeError instead of running, so `I trade @someone` was dead
    while `/trade` worked.

    Nothing here needs a Context. A mention is already parsed onto the message,
    and a name is a lookup on the guild.
    """
    raw = raw.strip()

    said = re.fullmatch(r"<@!?(\d+)>", raw)
    who_id = int(said.group(1)) if said else (int(raw) if raw.isdigit() else None)

    if who_id is not None:
        # The mentions the message already carries first: no fetch, and it is
        # the case that actually happens.
        for user in shim.message.mentions:
            if user.id == who_id:
                return user
        found = shim.client.get_user(who_id) or (
            shim.guild.get_member(who_id) if shim.guild else None
        )
        if found is not None:
            return found
        try:
            return await shim.client.fetch_user(who_id)
        except discord.HTTPException as exc:
            raise ValueError(f"there is nobody called {raw}") from exc

    if shim.guild is not None:
        found = shim.guild.get_member_named(raw)
        if found is not None:
            return found

    raise ValueError(f"there is nobody called {raw}")


async def convert(shim: MessageInteraction, param, raw: str):
    """One typed value out of one chunk of text.

    Only three option types exist across the whole tree - string, integer and
    user - so this handles three and refuses the rest rather than pretending.
    """
    kind = param.type

    if kind is discord.AppCommandOptionType.integer:
        return int(raw)

    if kind is discord.AppCommandOptionType.user:
        return await resolve_user(shim, raw)

    if kind is discord.AppCommandOptionType.string:
        if param.choices:
            wanted = raw.lower()
            for choice in param.choices:
                if wanted in (choice.value.lower(), choice.name.lower()):
                    return choice.value
            raise ValueError(f"{raw} is not one of {param.name}'s choices")
        return raw

    raise ValueError(f"{param.name} cannot be given without a slash command")


async def build_arguments(shim: MessageInteraction, command, rest: list[str]) -> dict:
    """Left to right, with the last parameter taking whatever is left.

    discord.py orders required parameters first, so filling from the left and
    letting the optional tail keep its defaults is the correct reading of a
    short line.
    """
    params = command.parameters
    if not params:
        # `I travel a lot` is a sentence, not a journey.
        if rest:
            raise ValueError("that command takes nothing")
        return {}

    text = " ".join(rest).strip()
    if not text:
        if any(p.required for p in params):
            raise ValueError("that command needs something to work with")
        return {}

    chunks = text.split(maxsplit=len(params) - 1) if len(params) > 1 else [text]

    given = {}
    for param, raw in zip(params, chunks):
        given[param.name] = await convert(shim, param, raw)

    missing = [p.name for p in params if p.required and p.name not in given]
    if missing:
        raise ValueError(f"missing {', '.join(missing)}")
    return given


# ---------------------------------------------------------------------------
# The listener
# ---------------------------------------------------------------------------


class Prefix(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @commands.Cog.listener()
    async def on_message(self, message: discord.Message) -> None:
        if message.author.bot or not message.content:
            return

        # Talking counts as being about. `last_seen_at` was touched only by
        # commands, so a channel could be busy with conversation and read as
        # empty to anything asking who is around - which is exactly what
        # decides whether a tide breaks.
        #
        # The WHERE clause is the throttle: one write per person per watch
        # window, not one per message. No read first, because the condition
        # and the write are the same statement.
        await db.execute(
            """
            UPDATE players SET last_seen_at = now()
            WHERE discord_id = %s AND deleted_at IS NULL
              AND last_seen_at < now() - make_interval(
                      mins => game_config_value('horde_watch_minutes')::integer / 3)
            """,
            (message.author.id,),
        )

        words = message.content.split()
        if len(words) < 2 or words[0].lower() != PREFIX:
            return

        match = resolve(self.bot.tree, words[1:])
        if match is None:
            return
        command, rest = match

        shim = MessageInteraction(message, command, self.bot)
        try:
            given = await build_arguments(shim, command, rest)
        except (ValueError, commands.BadArgument, commands.CommandError):
            # Prose, not a command. Saying so would make the bot argue with
            # every sentence beginning with "I".
            return

        try:
            await command.callback(command.binding, shim, **given)
        except GameError as exc:
            await message.reply(embed=error_embed(str(exc)), mention_author=False)
        except discord.DiscordServerError as exc:
            # Not our fault and not worth blaming ourselves for. Nothing was
            # half-done: the failure is in delivering the answer, not in
            # working it out.
            log.warning("discord %s answering I %s",
                        exc.status, command.qualified_name)
            with contextlib.suppress(discord.HTTPException):
                await message.reply(
                    embed=error_embed(
                        "Discord dropped that one. Nothing was spent — "
                        "try it again."
                    ),
                    mention_author=False,
                )
        except Exception:
            log.exception("unhandled error in I %s", command.qualified_name)
            with contextlib.suppress(discord.HTTPException):
                await message.reply(
                    embed=error_embed(
                        "Something broke on our side. The error has been logged."
                    ),
                    mention_author=False,
                )


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Prefix(bot))
