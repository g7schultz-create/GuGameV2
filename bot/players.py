"""Resolving a Discord user to a player row.

Every gameplay command starts here, so the soft-delete filter and the
`last_seen_at` touch live in one place instead of in thirty command bodies.
"""

import discord

from bot import database as db


class GameError(Exception):
    """A failure the player caused and can fix.

    Raised freely from command bodies; the tree's error handler turns it into
    an ephemeral reply. Anything else that escapes a command is a bug and gets
    logged as one, which is the distinction this type exists to draw.
    """


async def fetch_player(discord_id: int) -> dict | None:
    """The active player row for a Discord account, or None.

    Touches `last_seen_at` on the way past. That column exists to answer "who
    is playing" without an events table, which only works if the lookup every
    command already performs is what maintains it.
    """
    return await db.fetch_one(
        """
        UPDATE players
        SET last_seen_at = now()
        WHERE discord_id = %s AND deleted_at IS NULL
        RETURNING player_id, discord_id, discord_name, created_at
        """,
        (discord_id,),
    )


async def require_player(user: discord.abc.User) -> dict:
    player = await fetch_player(user.id)
    if player is None:
        raise GameError(
            "You have not begun cultivating yet. Use **/register** first."
        )
    return player


async def settle_passive(player_id: int) -> dict | None:
    """Pay out idle cultivation before showing anything.

    Called at the top of every command that displays progress. Nothing is
    actually ticking - the accrual is computed from `last_tick_at` at the
    moment somebody looks - so this is what makes the bar current rather than
    stale, and a zero-elapsed call grants exactly zero.

    Returns None for a character still being created: time should not accrue
    for someone who has not committed to a body yet.
    """
    confirmed = await db.fetch_value(
        "SELECT confirmed_at IS NOT NULL FROM player_character WHERE player_id = %s",
        (player_id,),
    )
    if not confirmed:
        return None
    return await db.fetch_one(
        "SELECT * FROM settle_passive_cultivation(%s)", (player_id,)
    )


async def create_player(user: discord.abc.User) -> dict:
    """Register a Discord account and open its pillars.

    One transaction: a player with no cultivation row is a player every later
    command has to defend against, so the inserts are not allowed to come
    apart. The Root and Physique are rolled here rather than chosen, and the
    character stays unconfirmed until the player commits to them.
    """
    async with db.pool().connection() as conn:
        existing = await (
            await conn.execute(
                "SELECT player_id, deleted_at FROM players WHERE discord_id = %s",
                (user.id,),
            )
        ).fetchone()

        if existing and existing["deleted_at"] is None:
            confirmed = await (
                await conn.execute(
                    "SELECT confirmed_at FROM player_character WHERE player_id = %s",
                    (existing["player_id"],),
                )
            ).fetchone()
            # An unconfirmed character is a session that was interrupted, not a
            # duplicate registration - /register resumes it.
            if confirmed and confirmed["confirmed_at"] is None:
                cur = await conn.execute(
                    "SELECT player_id, discord_id, discord_name, created_at "
                    "FROM players WHERE player_id = %s",
                    (existing["player_id"],),
                )
                return await cur.fetchone()
            raise GameError("You are already registered. Try **/profile**.")

        if existing:
            # Soft-deleted: revive the identity rather than orphaning its
            # history behind a second row for the same Discord account.
            cur = await conn.execute(
                """
                UPDATE players
                SET deleted_at = NULL, discord_name = %s, last_seen_at = now()
                WHERE player_id = %s
                RETURNING player_id, discord_id, discord_name, created_at
                """,
                (str(user), existing["player_id"]),
            )
            return await cur.fetchone()

        cur = await conn.execute(
            """
            INSERT INTO players (discord_id, discord_name)
            VALUES (%s, %s)
            RETURNING player_id, discord_id, discord_name, created_at
            """,
            (user.id, str(user)),
        )
        player = await cur.fetchone()

        await conn.execute(
            "INSERT INTO player_cultivation (player_id) VALUES (%s)",
            (player["player_id"],),
        )
        # The physique is rolled straight into place: `player_physique` is
        # where a body lives, so there is no second column holding a copy of
        # which one it is.
        await conn.execute(
            "INSERT INTO player_physique (player_id, physique_id) VALUES (%s, roll_physique())",
            (player["player_id"],),
        )
        # Everyone starts in the Central Continent - the middle of the map,
        # and the shortest walk to anywhere else.
        await conn.execute(
            "INSERT INTO player_location (player_id, region_code) VALUES (%s, 'central')",
            (player["player_id"],),
        )
        await conn.execute(
            """
            INSERT INTO player_character
                (player_id, race_code, root_code,
                 root_rerolls_left, physique_rerolls_left)
            VALUES (
                %s, 'human', roll_root(),
                game_config_value('character_root_rerolls')::smallint,
                game_config_value('character_physique_rerolls')::smallint
            )
            """,
            (player["player_id"],),
        )
        return player
