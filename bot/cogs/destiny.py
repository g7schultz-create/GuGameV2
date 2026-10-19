"""Destiny: /destiny.

A great realm rewrites your fate. Crossing into a new rank offers three
Destinies and one is chosen, permanently — by the Ancient Realm a cultivator
carries seven, drawn from a pool of thirty, and no two people carry the same
seven.

The offer is rolled by `breakthrough` and written down there, not here. This
screen only shows what fate already put in front of somebody and takes their
answer, which is why closing it loses nothing.
"""

import discord
import psycopg
from discord import app_commands
from discord.ext import commands

from bot import database as db
from bot.formatting import COLOUR_GOOD, COLOUR_INFO, embed
from bot.players import GameError, require_player
from bot.views import AnsweringView

FATE = "\N{MILKY WAY}"
TAKEN = "\N{WHITE HEAVY CHECK MARK}"


def refuse(exc: psycopg.errors.CheckViolation) -> GameError:
    return GameError(str(exc).splitlines()[0].capitalize())


async def waiting_for(player_id: int) -> dict | None:
    """The lowest realm still owed a choice, so they are taken in order."""
    return await db.fetch_one(
        "SELECT * FROM destiny_pending WHERE player_id = %s ORDER BY rank LIMIT 1",
        (player_id,),
    )


async def written(player_id: int) -> list[dict]:
    return await db.fetch_all(
        """
        SELECT pd.rank, d.name, d.description,
               -- `effect_amount` decides the unit. Since 0370 a fate can grant
               -- Body, Hide or Sinew, which are POINTS added before the realm
               -- multiplies them - printing thirty Body as three thousand per
               -- cent is a different quantity, not a rounding choice. It also
               -- takes the per cent sign out of a parameterised query, which
               -- psycopg reads as a placeholder marker and which the two
               -- comments this replaces were apologising for.
               (SELECT string_agg(ef.emoji || ' ' || ef.name || ' '
                                  || effect_amount(ef.code, de.magnitude),
                                  ', ' ORDER BY ef.sort_order)
                FROM destiny_effects de
                JOIN gu_effects ef ON ef.code = de.effect_code
                WHERE de.code = d.code) AS grants
        FROM player_destinies pd
        JOIN destinies d ON d.code = pd.code
        WHERE pd.player_id = %s
        ORDER BY pd.rank
        """,
        (player_id,),
    )


async def offered_detail(codes: list[str]) -> list[dict]:
    return await db.fetch_all(
        """
        SELECT d.code, d.name, d.description,
               -- `effect_amount` decides the unit. Since 0370 a fate can grant
               -- Body, Hide or Sinew, which are POINTS added before the realm
               -- multiplies them - printing thirty Body as three thousand per
               -- cent is a different quantity, not a rounding choice. It also
               -- takes the per cent sign out of a parameterised query, which
               -- psycopg reads as a placeholder marker and which the two
               -- comments this replaces were apologising for.
               (SELECT string_agg(ef.emoji || ' ' || ef.name || ' '
                                  || effect_amount(ef.code, de.magnitude),
                                  ', ' ORDER BY ef.sort_order)
                FROM destiny_effects de
                JOIN gu_effects ef ON ef.code = de.effect_code
                WHERE de.code = d.code) AS grants
        FROM destinies d
        WHERE d.code = ANY(%s)
        ORDER BY array_position(%s, d.code)
        """,
        (codes, codes),
    )


async def destiny_card(player_id: int, pending: dict | None) -> discord.Embed:
    mine = await written(player_id)

    if pending is None:
        card = embed(
            f"{FATE} Your fate",
            "Nothing is waiting. A great realm rewrites your fate \N{EM DASH} "
            "the next one offers three more.",
            colour=COLOUR_INFO,
        )
    else:
        card = embed(
            f"{FATE} Your breakthrough has changed your fate",
            f"Three stand open to you at **rank {pending['rank']}**. "
            "One is taken, and it is permanent.",
            colour=COLOUR_GOOD,
        )
        for one in await offered_detail(pending["offered"]):
            card.add_field(
                name=one["name"],
                value=f"*{one['description']}*\n{one['grants'] or '—'}",
                inline=False,
            )

    if mine:
        card.add_field(
            name=f"Written ({len(mine)})",
            value="\n".join(
                f"{TAKEN} **{r['name']}** \N{BULLET} rank {r['rank']}\n"
                f"　　{r['grants'] or '—'}"
                for r in mine
            )[:1024],
            inline=False,
        )

    card.set_footer(
        text="A fate cannot be unwritten, and none is offered twice."
    )
    return card


class DestinySelect(discord.ui.Select):
    def __init__(self, screen: "DestinyView", offers: list[dict]) -> None:
        self.screen = screen
        super().__init__(
            placeholder="Take one\N{HORIZONTAL ELLIPSIS}",
            options=[
                discord.SelectOption(
                    label=o["name"][:100],
                    value=o["code"],
                    description=(o["grants"] or o["description"])[:100],
                )
                for o in offers
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        await self.screen.take(interaction, self.values[0])


class DestinyView(AnsweringView):
    def __init__(
        self, player_id: int, user: discord.abc.User, pending: dict | None,
        offers: list[dict],
    ) -> None:
        super().__init__(timeout=600)
        self.player_id = player_id
        self.user = user
        self.pending = pending
        if pending is not None and offers:
            self.add_item(DestinySelect(self, offers))

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "Your own fate is your own \N{EM DASH} **/destiny**.", ephemeral=True
            )
            return False
        return True

    async def take(self, interaction: discord.Interaction, code: str) -> None:
        try:
            took = await db.fetch_one(
                "SELECT * FROM destiny_take(%s, %s, %s)",
                (self.player_id, self.pending["rank"], code),
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        # Another realm may already be owed a choice - somebody who crossed
        # twice without opening this screen has two waiting.
        self.pending = await waiting_for(self.player_id)
        self.clear_items()
        if self.pending is not None:
            self.add_item(
                DestinySelect(self, await offered_detail(self.pending["offered"]))
            )

        await interaction.response.edit_message(
            embed=await destiny_card(self.player_id, self.pending),
            view=self if self.children else discord.utils.MISSING,
        )
        await interaction.followup.send(
            embed=embed(
                f"{FATE} {took['name']}",
                f"*{took['description']}*\n\n{took['grants'] or '—'}",
                colour=COLOUR_GOOD,
            ),
            ephemeral=True,
        )


class Destiny(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @app_commands.command(
        description="The fates a great realm opened to you, and the ones you took."
    )
    async def destiny(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        pending = await waiting_for(player["player_id"])
        offers = (
            await offered_detail(pending["offered"]) if pending is not None else []
        )
        view = DestinyView(player["player_id"], interaction.user, pending, offers)
        await interaction.response.send_message(
            embed=await destiny_card(player["player_id"], pending),
            view=view if view.children else discord.utils.MISSING,
        )


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Destiny(bot))
