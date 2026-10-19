"""Entry point. `python -m bot`, which is what the Procfile's worker runs."""

import asyncio
import logging
import logging.handlers
import sys
from pathlib import Path

import discord

from bot import config
from bot.client import GuBot


def loop_factory():
    """The event loop to run on.

    Windows defaults to `ProactorEventLoop`, and psycopg refuses to run in
    async mode on it - so on Windows the bot would log in to Discord happily
    and then fail on the first query with a message about event loops. The
    selector loop is what psycopg needs, and discord.py does not need anything
    the selector loop lacks (subprocesses, which it never spawns).

    Everywhere else, including Railway, the default is already correct.

    Passed to `asyncio.run` rather than set as a global policy because
    `asyncio.set_event_loop_policy` is deprecated from Python 3.14 onward.
    """
    if sys.platform == "win32":
        return asyncio.SelectorEventLoop()
    return asyncio.new_event_loop()


def log_to_file() -> None:
    """Keep the tracebacks that `on_tree_error` promises are "logged".

    Until now they went to stdout and nowhere else, so a restart threw away
    the only copy - which made "The error has been logged" a thing the player
    was told and nobody could act on. Three files of a megabyte is enough to
    still have last night's failure this morning and never enough to matter.

    Added to the root logger alongside discord.py's handler rather than
    instead of it: the console output is what you watch a restart in.
    """
    log_file = Path(__file__).resolve().parent.parent / "gu-bot.log"
    handler = logging.handlers.RotatingFileHandler(
        log_file, maxBytes=1_000_000, backupCount=2, encoding="utf-8"
    )
    handler.setFormatter(
        logging.Formatter(
            "[{asctime}] [{levelname:<8}] {name}: {message}",
            "%Y-%m-%d %H:%M:%S",
            style="{",
        )
    )
    logging.getLogger().addHandler(handler)


def main() -> None:
    # discord.py's own handler configures the root logger and colourises when
    # attached to a terminal; on Railway it degrades to plain lines.
    discord.utils.setup_logging(level=logging.INFO)
    log_to_file()

    token = config.discord_token()

    async def run() -> None:
        try:
            async with GuBot() as bot:
                await bot.start(token)
        except discord.PrivilegedIntentsRequired:
            # `I hunt` needs MESSAGE CONTENT, which Discord will not hand over
            # until it is enabled in the Developer Portal. That is a switch
            # only a human can throw, and a convenience nobody has enabled yet
            # must not be able to keep the bot offline - so it starts without.
            logging.getLogger("gu.bot").warning(
                "MESSAGE CONTENT is not enabled for this application, so `I hunt` "
                "cannot be read. Starting without it; slash commands are "
                "unaffected. Turn it on at "
                "https://discord.com/developers/applications -> your app -> Bot "
                "-> Privileged Gateway Intents, then restart."
            )
            async with GuBot(read_messages=False, sync_on_start=False) as bot:
                await bot.start(token)

    try:
        asyncio.run(run(), loop_factory=loop_factory)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
