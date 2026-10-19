"""Answering a refusal that happened inside a button.

`tree.on_error` in `client.py` covers command bodies. It does not cover
components: a failure inside a button, a select or a modal goes to that View's
or Modal's own handler, and discord.py's default writes a traceback to the log
and leaves the interaction unanswered. The player sees "This interaction
failed" and is told nothing - even when the game knew exactly what was wrong
and had a sentence ready.

That is how `/gu` came to answer "your aperture holds 4 and this needs 2 more"
into a log file and a red box to the player. The message was built correctly
and thrown away, because `GuView` was a plain `discord.ui.View`.

Five cogs had each written this out for themselves and six had not, which is
the arrangement that guarantees the next screen forgets. So it lives here,
once, and `AnsweringView` is what every view in this bot is built on.
"""

import discord

from bot.formatting import error_embed
from bot.players import GameError


async def answer_error(interaction: discord.Interaction, error: Exception) -> bool:
    """Reply to a refusal, or report that it was not one.

    Returns False for anything that is not a `GameError` - a bug, in other
    words - so the caller hands it back to discord.py and it reaches the log
    with its traceback intact. A screen that swallowed those would be worse
    than one that says nothing.
    """
    if not isinstance(error, GameError):
        return False

    card = error_embed(str(error))
    if interaction.response.is_done():
        await interaction.followup.send(embed=card, ephemeral=True)
    else:
        await interaction.response.send_message(embed=card, ephemeral=True)
    return True


class AnsweringView(discord.ui.View):
    """A view whose refusals reach the player rather than the log."""

    async def on_error(
        self, interaction: discord.Interaction, error: Exception, item
    ) -> None:
        if not await answer_error(interaction, error):
            await super().on_error(interaction, error, item)


class AnsweringModal(discord.ui.Modal):
    """The same, for a form. A modal has its own handler and its own default."""

    async def on_error(
        self, interaction: discord.Interaction, error: Exception
    ) -> None:
        if not await answer_error(interaction, error):
            await super().on_error(interaction, error)
