"""The bot's half of the environment.

`db.connection` owns DATABASE_URL; this owns everything Discord-shaped, so
neither has to know about the other's variables.
"""

import os

from dotenv import load_dotenv

load_dotenv()


def discord_token() -> str:
    """The bot token. Raises rather than starting a bot that cannot log in."""
    token = os.getenv("DISCORD_TOKEN")
    if not token:
        raise RuntimeError(
            "DISCORD_TOKEN is not set. Create an application at "
            "https://discord.com/developers/applications, copy the bot token, "
            "and put it in .env (see .env.example)."
        )
    return token


def guild_id() -> int | None:
    """Guild to register commands to, or None for a global registration.

    Guild-scoped commands appear the moment the bot syncs them; global ones
    take up to an hour to propagate. During development you always want the
    former, which is why .env.example ships with this set and empty.
    """
    raw = os.getenv("GUILD_ID", "").strip()
    if not raw:
        return None
    if not raw.isdigit():
        raise RuntimeError(
            f"GUILD_ID must be a Discord snowflake (digits only), got {raw!r}. "
            "Right-click the server -> Copy Server ID with Developer Mode on."
        )
    return int(raw)


def dev_commands() -> bool:
    """Whether to register the /dev group, which is off unless asked for.

    The tree holds 100 of Discord's 100 slash commands and /dev is one of them -
    a single slot carrying thirteen subcommands, since it is a Group. Dropping it
    from the live registration is the cheapest slot in the game to buy back.

    It is only the REGISTRATION that goes. The cog stays on disk and the test
    harness loads it directly out of EXTENSIONS, because 33 tests use `dev ready`
    and friends to put a character into a known state.

    Set DEV_COMMANDS=1 to get it back in Discord for a session.
    """
    return os.getenv("DEV_COMMANDS", "").strip().lower() in {"1", "true", "yes", "on"}


def horde_channel_id() -> int | None:
    """Where a Beast Horde runs, or None to run one nowhere.

    Same reasoning as the boss channel: a channel is deployment, not balance.
    Returning None rather than raising matters more here than there, though -
    the horde loop asks for this every twenty seconds, and a bot with no horde
    channel configured has to keep running everything else without complaint.
    """
    raw = os.getenv("HORDE_CHANNEL_ID", "").strip()
    if not raw:
        return None
    if not raw.isdigit():
        raise RuntimeError(
            f"HORDE_CHANNEL_ID must be a Discord snowflake (digits only), got "
            f"{raw!r}. Right-click the channel -> Copy Channel ID with "
            "Developer Mode on."
        )
    return int(raw)


def boss_channel_id() -> int | None:
    """Where a slain world beast is announced, or None to announce nowhere.

    A channel is deployment, not balance, so it lives here beside GUILD_ID
    rather than in `game_config` with the tunables. Returning None rather than
    raising is deliberate: a bot with no channel configured must still run the
    fight, and a beast that dies unannounced is a missing post rather than a
    broken command.
    """
    raw = os.getenv("BOSS_CHANNEL_ID", "").strip()
    if not raw:
        return None
    if not raw.isdigit():
        raise RuntimeError(
            f"BOSS_CHANNEL_ID must be a Discord snowflake (digits only), got "
            f"{raw!r}. Right-click the channel -> Copy Channel ID with "
            "Developer Mode on."
        )
    return int(raw)
