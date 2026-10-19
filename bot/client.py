"""The client: what starts, in what order, and what happens when a command
raises.

Startup order matters and is the reason `setup_hook` does all of it. discord.py
calls it after login but before the gateway starts delivering events, so the
pool is open and the cogs are loaded before any interaction can arrive. Opening
the pool in `on_ready` instead leaves a window where a command can fire against
a pool that is not there yet.
"""

import logging

import discord
from discord import app_commands
from discord.ext import commands

from bot import config
from bot import database as db
from bot.formatting import error_embed
from bot.players import GameError

log = logging.getLogger("gu.bot")

EXTENSIONS = (
    "bot.cogs.core",
    "bot.cogs.tutorial",
    "bot.cogs.character",
    "bot.cogs.paths",
    "bot.cogs.insight",
    "bot.cogs.techniques",
    "bot.cogs.bestiary",
    "bot.cogs.cultivation",
    "bot.cogs.physique",
    "bot.cogs.world",
    "bot.cogs.battle",
    "bot.cogs.manuals",
    "bot.cogs.refine",
    "bot.cogs.trade",
    "bot.cogs.gu",
    "bot.cogs.gurefine",
    "bot.cogs.nurture",
    "bot.cogs.presets",
    "bot.cogs.dungeon",
    "bot.cogs.destiny",
    "bot.cogs.enlighten",
    "bot.cogs.eggs",
    "bot.cogs.servants",
    "bot.cogs.gearfusing",
    "bot.cogs.party",
    "bot.cogs.trial",
    "bot.cogs.delve",
    "bot.cogs.alchemy",
    "bot.cogs.forge",
    "bot.cogs.smelt",
    "bot.cogs.auction",
    "bot.cogs.reroll",
    "bot.cogs.professions",
    "bot.cogs.dwelling",
    "bot.cogs.broker",
    "bot.cogs.index",
    "bot.cogs.leaderboard",
    "bot.cogs.boss",
    "bot.cogs.fusion",
    "bot.cogs.horde",
    "bot.cogs.gamble",
    "bot.cogs.tournament",
    "bot.cogs.venerable",
    "bot.cogs.duel",
    "bot.cogs.raisegear",
    "bot.cogs.garden",
    "bot.cogs.farm",
    "bot.cogs.prefix",
    "bot.cogs.dev",
)


class GuBot(commands.Bot):
    def __init__(
        self,
        *,
        read_messages: bool = True,
        sync_on_start: bool = True,
        dev_commands: bool | None = None,
    ) -> None:
        # Slash commands need no privileged intents. `I hunt` does: reading
        # what somebody typed is MESSAGE CONTENT, which is privileged and has
        # to be switched on in the Developer Portal as well - asking for it in
        # code is only half of the arrangement, and Discord refuses the
        # connection outright when the other half is missing.
        #
        # So it is a flag rather than a requirement. `bot/__main__.py` asks for
        # it, and falls back to a bot without it if Discord says no: an
        # optional convenience must not be able to keep the whole bot offline.
        #
        # The cost is worth stating: an application holding this intent needs
        # Discord's review once it reaches 100 servers.
        self.read_messages = read_messages
        # The intent fallback below builds a second bot in the same process,
        # and syncing the identical tree twice costs a 60-second rate limit on
        # every restart. The first attempt got as far as syncing before the
        # gateway refused it, so the second has nothing to do.
        self.sync_on_start = sync_on_start
        # None means "ask the environment", so a caller can still force it
        # either way without setting a variable.
        self.dev_commands = (
            config.dev_commands() if dev_commands is None else dev_commands
        )

        intents = discord.Intents.none()
        intents.guilds = True
        if read_messages:
            intents.messages = True
            intents.message_content = True

        super().__init__(
            command_prefix=commands.when_mentioned,
            intents=intents,
            help_command=None,
        )
        self.tree.on_error = self.on_tree_error

    async def setup_hook(self) -> None:
        await db.open_pool()
        log.info("database pool open")

        # A listener that can never see a message is worse than no listener:
        # it would swallow nothing and explain nothing.
        #
        # And /dev is off unless asked for. The tree holds 100 of Discord's 100
        # slash commands, so the thirteen-subcommand Group that nobody but the
        # owner runs is the cheapest slot there is to buy back. The cog is still
        # on disk and the test harness still loads it out of EXTENSIONS - this
        # drops the REGISTRATION, not the tool. DEV_COMMANDS=1 brings it back.
        wanted = [
            e for e in EXTENSIONS
            if (self.read_messages or e != "bot.cogs.prefix")
            and (self.dev_commands or e != "bot.cogs.dev")
        ]
        for extension in wanted:
            await self.load_extension(extension)
        log.info("loaded %d extension(s)", len(wanted))

        if self.sync_on_start:
            await self.sync_commands()

    async def sync_commands(self) -> list[app_commands.AppCommand]:
        """Register the command tree.

        Guild-scoped when GUILD_ID is set, which is what makes a command
        editable in seconds during development; global otherwise, which is
        correct for a real deployment and takes up to an hour to propagate.
        """
        guild = config.guild_id()
        if guild is None:
            synced = await self.tree.sync()
            log.info("synced %d command(s) globally", len(synced))
            return synced

        target = discord.Object(id=guild)
        self.tree.copy_global_to(guild=target)
        synced = await self.tree.sync(guild=target)
        log.info("synced %d command(s) to guild %s", len(synced), guild)
        return synced

    async def close(self) -> None:
        await db.close_pool()
        await super().close()

    async def on_ready(self) -> None:
        log.info("logged in as %s (%s)", self.user, self.user.id)

    async def on_tree_error(
        self,
        interaction: discord.Interaction,
        error: app_commands.AppCommandError,
    ) -> None:
        """Answer every failed interaction, and tell the truth about which kind
        of failure it was.

        A Discord interaction that is never responded to shows the player
        "The application did not respond", which is indistinguishable from the
        bot being down. So this always replies - with the actual reason when
        the player can act on it, and with a generic line plus a logged
        traceback when it is our bug.
        """
        original = getattr(error, "original", error)

        if isinstance(original, GameError):
            message = str(original)
        elif isinstance(error, app_commands.CheckFailure):
            message = "You cannot use that command."
        elif isinstance(error, app_commands.CommandOnCooldown):
            message = f"Too fast. Try again in {error.retry_after:.0f}s."
        else:
            log.exception(
                "unhandled error in /%s",
                interaction.command.qualified_name if interaction.command else "?",
                exc_info=original,
            )
            message = (
                "Something broke on our side. The error has been logged."
            )

        embed = error_embed(message)
        try:
            if interaction.response.is_done():
                await interaction.followup.send(embed=embed, ephemeral=True)
            else:
                await interaction.response.send_message(embed=embed, ephemeral=True)
        except discord.HTTPException:
            log.exception("could not deliver the error reply")
