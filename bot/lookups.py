"""Autocomplete and code-to-row resolution for the content tables.

Paths, techniques and creatures are all addressed by their `code` column, which
is stable and typo-prone in equal measure. Every command that takes one gets
autocomplete from here, so the player picks from a list instead of guessing at
spelling, and gets the same "no such thing" message when they type one anyway.

Discord gives autocomplete about three seconds and fires it on every keystroke,
so each callback is one indexed query returning at most 25 rows.
"""

import discord
from discord import app_commands

from bot import database as db
from bot.players import GameError

CHOICE_LIMIT = 25


def _choices(rows: list[dict]) -> list[app_commands.Choice[str]]:
    return [
        app_commands.Choice(name=row["name"], value=row["code"]) for row in rows
    ]


# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------


async def path_autocomplete(
    interaction: discord.Interaction, current: str
) -> list[app_commands.Choice[str]]:
    rows = await db.fetch_all(
        """
        SELECT code, name FROM paths
        WHERE name ILIKE %s OR code ILIKE %s
        ORDER BY sort_order
        LIMIT %s
        """,
        (f"%{current}%", f"%{current}%", CHOICE_LIMIT),
    )
    return _choices(rows)


async def resolve_path(code: str) -> dict:
    row = await db.fetch_one("SELECT * FROM paths WHERE code = %s", (code,))
    if row is None:
        raise GameError(f"There is no Path called `{code}`.")
    return row


# ---------------------------------------------------------------------------
# Techniques
#
# Canonical content only (`created_by IS NULL`). A player's own killer moves
# are theirs; surfacing them in everyone's autocomplete would leak them.
# ---------------------------------------------------------------------------


async def technique_autocomplete(
    interaction: discord.Interaction, current: str
) -> list[app_commands.Choice[str]]:
    rows = await db.fetch_all(
        """
        SELECT code, name || ' (rank ' || rank || ')' AS name
        FROM techniques
        WHERE created_by IS NULL
          AND code IS NOT NULL
          AND (name ILIKE %s OR code ILIKE %s)
        ORDER BY rank, name
        LIMIT %s
        """,
        (f"%{current}%", f"%{current}%", CHOICE_LIMIT),
    )
    return _choices(rows)


async def known_technique_autocomplete(
    interaction: discord.Interaction, current: str
) -> list[app_commands.Choice[str]]:
    """Only what this player has learned. Used by /equip, where offering
    anything else is offering a choice the composite FK will refuse.
    """
    rows = await db.fetch_all(
        """
        SELECT t.code, t.name
        FROM player_techniques pt
        JOIN techniques t ON t.technique_id = pt.technique_id
        JOIN players p ON p.player_id = pt.player_id
        WHERE p.discord_id = %s
          AND t.code IS NOT NULL
          AND (t.name ILIKE %s OR t.code ILIKE %s)
        ORDER BY t.rank, t.name
        LIMIT %s
        """,
        (interaction.user.id, f"%{current}%", f"%{current}%", CHOICE_LIMIT),
    )
    return _choices(rows)


async def resolve_technique(code: str) -> dict:
    row = await db.fetch_one(
        "SELECT * FROM techniques WHERE code = %s AND created_by IS NULL",
        (code,),
    )
    if row is None:
        raise GameError(f"There is no technique called `{code}`.")
    return row


# ---------------------------------------------------------------------------
# Creatures
# ---------------------------------------------------------------------------


async def species_autocomplete(
    interaction: discord.Interaction, current: str
) -> list[app_commands.Choice[str]]:
    rows = await db.fetch_all(
        """
        SELECT code, name || ' (rank ' || rank || ')' AS name
        FROM creature_species
        WHERE name ILIKE %s OR code ILIKE %s
        ORDER BY rank, name
        LIMIT %s
        """,
        (f"%{current}%", f"%{current}%", CHOICE_LIMIT),
    )
    return _choices(rows)


async def resolve_species(code: str) -> dict:
    row = await db.fetch_one(
        "SELECT * FROM creature_species WHERE code = %s", (code,)
    )
    if row is None:
        raise GameError(f"There is no creature called `{code}`.")
    return row
