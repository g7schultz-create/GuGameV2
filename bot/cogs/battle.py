"""The fight you are already in: /battle, /flee.

A battle is a database row, so the screen for it can be reopened. A view that
timed out, a message that scrolled away, a bot that restarted mid-fight - none
of those lose the fight, and /battle draws it again from where it stands.
"""

import discord
from discord import app_commands
from discord.ext import commands

from bot import database as db
from bot.battle import (
    BattleView,
    active_battle,
    fetch_state,
    render_battle,
    usable_techniques,
)
from bot.players import GameError, require_player


async def _not_a_duel(battle_id: int, instead: str) -> None:
    """Both commands here are for a fight with a creature on the far side.

    `player_active_battle` holds one row per player whatever kind of fight it
    is, and `duel_open` writes it for both seats - so the moment a duel exists,
    /battle and /abandon can find one. Neither should touch it:

      * `battle_act` reads seat 1 as a creature and takes no player argument,
        so it always acts as seat 0. On a duel the second cultivator would be
        swinging as the first, at an opponent with no species.
      * `battle_abandon` ends a fight with nobody winning and releases both
        claims, which on a duel is the losing side pressing a button and the
        fight never having happened.

    0548 refuses both in the database as well. This is the same refusal said
    early, in a sentence that names the command to use instead - a screen that
    tells you where to go beats a screen that tells you no.
    """
    kind = await db.fetch_value(
        "SELECT kind FROM battles WHERE battle_id = %s", (battle_id,)
    )
    if kind == "duel":
        raise GameError("You are in a duel. " + instead)


class Battle(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @app_commands.command(description="The fight you are in the middle of.")
    async def battle(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)

        battle_id = await active_battle(player["player_id"])
        if battle_id is None:
            raise GameError(
                "You are not fighting anything. **/hunt** to find something."
            )
        await _not_a_duel(battle_id, "**/duel** to take your turn in it.")

        state = await fetch_state(battle_id)
        region = await db.fetch_value(
            "SELECT region_code FROM player_location WHERE player_id = %s",
            (player["player_id"],),
        )
        techniques = await usable_techniques(player["player_id"], state["player_max_qi"])

        view = BattleView(
            player["player_id"], interaction.user, state, techniques, region
        )
        await interaction.response.send_message(
            embed=render_battle(state, interaction.user.display_name), view=view
        )
        view.message = await interaction.original_response()

    # -----------------------------------------------------------------------

    @app_commands.command(description="Walk away from a fight you cannot finish.")
    async def abandon(self, interaction: discord.Interaction) -> None:
        """The escape hatch, and deliberately not the same thing as fleeing.

        Fleeing is a roll inside the fight. Abandoning is giving up on it
        entirely - it releases the claim so /hunt works again, and the creature
        keeps whatever HP it had left.
        """
        player = await require_player(interaction.user)

        battle_id = await active_battle(player["player_id"])
        if battle_id is None:
            raise GameError("You are not fighting anything.")
        await _not_a_duel(
            battle_id,
            "A duel has somebody on the other side of it, so there is no "
            "walking away that costs nothing. **/yield** gives it to them.",
        )

        state = await fetch_state(battle_id)
        await db.execute("SELECT battle_abandon(%s)", (battle_id,))

        await interaction.response.send_message(
            embed=discord.Embed(
                title="You leave it standing",
                description=f"The {state['creature_name']} does not follow. "
                "Whatever you did to it, it keeps.",
                colour=discord.Colour(0x5B4B8A),
            )
        )


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Battle(bot))
