"""The bestiary: /bestiary, /creature, /study.

What a player knows about a species is a discovery log, not a copy. The
interaction values shown here are read live from the species every time, so
retuning a creature updates everyone's bestiary at once instead of leaving
thousands of stale snapshots behind. "Unknown traits: 2" is therefore a count
difference, computed here, and never a stored number.
"""

import discord
from discord import app_commands
from discord.ext import commands

from bot import database as db
from bot.formatting import (
    COLOUR_DEFAULT,
    COLOUR_GOOD,
    embed,
    interaction_label,
    thousands,
)
from bot.lookups import path_autocomplete, resolve_species, species_autocomplete
from bot.players import GameError, require_player

# Spec section 7: deducing a weakness rather than being hit by it is what high
# Wisdom attainment buys. Expert is the floor for it.
STUDY_MIN_TIER = 2


class Bestiary(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @app_commands.command(description="Every species you have encountered.")
    async def bestiary(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)

        rows = await db.fetch_all(
            """
            SELECT s.code, s.name, s.rank, s.kind,
                   b.times_encountered, b.times_defeated,
                   (SELECT count(*) FROM player_bestiary_paths pbp
                     WHERE pbp.player_id = b.player_id
                       AND pbp.species_id = b.species_id) AS known_traits,
                   (SELECT count(*) FROM creature_incoming_paths cip
                     WHERE cip.species_id = b.species_id) AS total_traits
            FROM player_bestiary b
            JOIN creature_species s ON s.species_id = b.species_id
            WHERE b.player_id = %s
            ORDER BY s.rank, s.name
            """,
            (player["player_id"],),
        )

        if not rows:
            card = embed(
                "Bestiary",
                "Empty. You have met nothing yet — **/study** a species to begin "
                "deducing what it is weak to.",
                colour=COLOUR_DEFAULT,
            )
            await interaction.response.send_message(embed=card, ephemeral=True)
            return

        lines = []
        for row in rows:
            unknown = row["total_traits"] - row["known_traits"]
            lines.append(
                f"`{row['rank']}` **{row['name']}** ({row['kind']}) — "
                f"{row['known_traits']} known"
                + (f", {unknown} unknown" if unknown else ", complete")
                + f"  ·  defeated {row['times_defeated']}×"
            )

        await interaction.response.send_message(
            embed=embed("Bestiary", "\n".join(lines), colour=COLOUR_DEFAULT)
        )

    # -----------------------------------------------------------------------

    @app_commands.command(description="One species, showing only what you have discovered.")
    @app_commands.describe(creature="The species to read.")
    @app_commands.autocomplete(creature=species_autocomplete)
    async def creature(self, interaction: discord.Interaction, creature: str) -> None:
        player = await require_player(interaction.user)
        species = await resolve_species(creature)

        own_paths = await db.fetch_all(
            """
            SELECT p.name, cp.is_primary
            FROM creature_paths cp
            JOIN paths p ON p.code = cp.path_code
            WHERE cp.species_id = %s
            ORDER BY cp.is_primary DESC, p.sort_order
            """,
            (species["species_id"],),
        )

        # The join to player_bestiary_paths is what hides an undiscovered
        # interaction. The value itself still comes from the view, so it is
        # current rather than whatever it was when it was discovered.
        traits = await db.fetch_all(
            """
            SELECT p.name, cip.interaction, cip.is_override, cip.flavour_text,
                   pbp.discovered_via
            FROM creature_incoming_paths cip
            JOIN paths p ON p.code = cip.path_code
            LEFT JOIN player_bestiary_paths pbp
                ON pbp.species_id = cip.species_id
               AND pbp.path_code = cip.path_code
               AND pbp.player_id = %s
            WHERE cip.species_id = %s
            ORDER BY p.sort_order
            """,
            (player["player_id"], species["species_id"]),
        )

        known = [t for t in traits if t["discovered_via"] is not None]
        unknown = len(traits) - len(known)

        card = embed(species["name"], species["description"], colour=COLOUR_DEFAULT)
        card.add_field(name="Rank", value=str(species["rank"]))
        card.add_field(name="Kind", value=species["kind"].title())
        card.add_field(name="HP", value=thousands(species["base_hp"]))
        card.add_field(
            name="Stats",
            value=(
                f"Attack {thousands(species['base_attack'])}  ·  "
                f"Defense {thousands(species['base_defense'])}  ·  "
                f"Speed {thousands(species['base_speed'])}"
            ),
            inline=False,
        )
        card.add_field(
            name="Paths",
            value=", ".join(
                f"{p['name'].replace(' Path', '')}"
                + ("" if p["is_primary"] else " (secondary)")
                for p in own_paths
            )
            or "None.",
            inline=False,
        )

        if known:
            lines = []
            for trait in known:
                line = (
                    f"{p_name(trait)} — {interaction_label(trait['interaction'])}"
                    f"  *({trait['discovered_via']})*"
                )
                if trait["flavour_text"]:
                    line += f"\n> {trait['flavour_text']}"
                lines.append(line)
            card.add_field(name="Known reactions", value="\n".join(lines), inline=False)
        else:
            card.add_field(
                name="Known reactions",
                value="Nothing. You have never seen how it takes a hit.",
                inline=False,
            )

        if unknown:
            card.set_footer(text=f"Unknown traits: {unknown}")
        else:
            card.set_footer(text="Fully catalogued.")
        await interaction.response.send_message(embed=card)

    # -----------------------------------------------------------------------

    @app_commands.command(
        description="Deduce one of a creature's reactions with Wisdom Path, without fighting it."
    )
    @app_commands.describe(
        creature="The species to study.",
        path="Guess at a specific Path, or leave blank to deduce whatever you can.",
    )
    @app_commands.autocomplete(creature=species_autocomplete, path=path_autocomplete)
    async def study(
        self,
        interaction: discord.Interaction,
        creature: str,
        path: str | None = None,
    ) -> None:
        """The bestiary's second way in.

        Discovery normally costs a fight — you learn that a thing resists Sword
        by swinging one at it. Spec section 7 gives Wisdom Path the other
        route, and `discovered_via` exists precisely so the two are told apart
        afterwards rather than collapsing into a single "known" flag.
        """
        player = await require_player(interaction.user)
        species = await resolve_species(creature)

        wisdom = await db.fetch_one(
            """
            SELECT a.tier, t.name AS tier_name
            FROM player_path_attainment a
            JOIN attainment_tiers t ON t.tier = a.tier
            WHERE a.player_id = %s AND a.path_code = 'wisdom'
            """,
            (player["player_id"],),
        )
        if wisdom is None or wisdom["tier"] < STUDY_MIN_TIER:
            current = wisdom["tier_name"] if wisdom else "Uninitiated"
            raise GameError(
                f"Deduction needs Wisdom Path at Expert or better; you are {current}. "
                "**/cultivation** with `path: wisdom` to get there."
            )

        async with db.pool().connection() as conn:
            await conn.execute(
                """
                INSERT INTO player_bestiary (player_id, species_id, times_encountered)
                VALUES (%s, %s, 0)
                ON CONFLICT (player_id, species_id)
                DO UPDATE SET last_seen_at = now()
                """,
                (player["player_id"], species["species_id"]),
            )

            cur = await conn.execute(
                """
                INSERT INTO player_bestiary_paths
                    (player_id, species_id, path_code, discovered_via)
                SELECT %s, cip.species_id, cip.path_code, 'insight'
                FROM creature_incoming_paths cip
                WHERE cip.species_id = %s
                  AND (%s::text IS NULL OR cip.path_code = %s)
                  AND NOT EXISTS (
                      SELECT 1 FROM player_bestiary_paths pbp
                      WHERE pbp.player_id = %s
                        AND pbp.species_id = cip.species_id
                        AND pbp.path_code = cip.path_code
                  )
                ORDER BY random()
                LIMIT 1
                RETURNING path_code
                """,
                (
                    player["player_id"],
                    species["species_id"],
                    path,
                    path,
                    player["player_id"],
                ),
            )
            discovered = await cur.fetchone()

        if discovered is None:
            if path:
                raise GameError(
                    f"Either **{species['name']}** reacts normally to that Path — "
                    "neutral is the absence of a trait, so there is nothing to learn — "
                    "or you already know it."
                )
            raise GameError(f"You already know every reaction **{species['name']}** has.")

        trait = await db.fetch_one(
            """
            SELECT p.name, cip.interaction, cip.flavour_text
            FROM creature_incoming_paths cip
            JOIN paths p ON p.code = cip.path_code
            WHERE cip.species_id = %s AND cip.path_code = %s
            """,
            (species["species_id"], discovered["path_code"]),
        )

        card = embed(
            f"You read the {species['name']}",
            f"**{trait['name']}** — {interaction_label(trait['interaction'])}",
            colour=COLOUR_GOOD,
        )
        if trait["flavour_text"]:
            card.add_field(name="​", value=f"> {trait['flavour_text']}", inline=False)
        card.set_footer(text="Recorded as deduced, not fought.")
        await interaction.response.send_message(embed=card)


def p_name(trait: dict) -> str:
    name = trait["name"].replace(" Path", "")
    return f"**{name}**" + (" *(species trait)*" if trait["is_override"] else "")


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Bestiary(bot))
