"""The table: /gamble.

Two games with the same currency and very different arithmetic behind them.

Against the HOUSE, the opponent has infinite Spirit Jade, so the payout table
is the only thing holding the economy up - it returns 96 Jade per 100 staked
and the schema refuses to accept a table that says otherwise. See 0149.

Against a PERSON it is zero sum and takes no rake: what one loses the other
wins and the currency's total is untouched. BOTH sides have to accept, and each
one's stake is escrowed as they do - so a half-agreed wager can sit there with
one purse light and the other untouched, and a decline or a lapse hands back
exactly what was taken.

Nothing about the odds is decided here. `play_house` and `accept_wager` roll,
and this draws what they say.
"""

import discord
import psycopg
from discord import app_commands
from discord.ext import commands

from bot import database as db
from bot.formatting import (
    COLOUR_BAD,
    COLOUR_DEFAULT,
    COLOUR_GOOD,
    COLOUR_INFO,
    embed,
    percent,
    thousands,
)
from bot.players import GameError, require_player, settle_passive
from bot.views import AnsweringView

JADE = "\N{GREEN HEART}"


def refuse(exc: psycopg.errors.CheckViolation) -> GameError:
    said = str(exc).splitlines()[0]
    return GameError(said[:1].upper() + said[1:])


async def house_odds() -> list[dict]:
    """The payout table, read rather than restated.

    A screen that wrote these numbers out itself would be a second copy of the
    house edge, and the one that drifts is always the one players read.
    """
    return await db.fetch_all(
        """
        SELECT gb.min_roll, gb.name, gb.emoji, gb.multiplier, gb.flavour,
               count(*) AS rolls
        FROM gamble_bands gb
        JOIN generate_series(1, 100) AS r (roll)
          ON gb.min_roll = (SELECT max(g2.min_roll) FROM gamble_bands g2
                            WHERE g2.min_roll <= r.roll)
        GROUP BY gb.min_roll, gb.name, gb.emoji, gb.multiplier, gb.flavour
        ORDER BY gb.min_roll
        """
    )


async def render_table(jade: int) -> discord.Embed:
    bands = await house_odds()
    take = await db.fetch_value("SELECT game_config_value('gamble_house_take')")
    lo = await db.fetch_value("SELECT game_config_value('gamble_min_stake')")
    hi = await db.fetch_value("SELECT game_config_value('gamble_max_stake')")

    card = embed(
        "\N{GAME DIE} The table",
        "Stake Spirit Jade on a hundred-sided roll \N{EM DASH} against the "
        "house, or against somebody who will take the other side of it.",
        colour=COLOUR_INFO,
    )
    card.add_field(
        name=f"{JADE} Spirit Jade",
        value=f"**{thousands(jade)}** \N{BULLET} stakes from {int(lo)} to {int(hi)}",
        inline=False,
    )
    card.add_field(
        name="Against the house",
        value="\n".join(
            f"{band['emoji']} `{band['min_roll']:>3}+` **{band['name']}** "
            f"\N{BULLET} pays {band['multiplier']:g}\N{MULTIPLICATION SIGN} "
            f"\N{BULLET} {band['rolls']}%"
            for band in bands
        ),
        inline=False,
    )
    card.add_field(
        name="Against a person",
        value="Both roll, higher takes the pot, a tie hands both stakes back. "
        "No cut is taken \N{EM DASH} what one loses the other wins.",
        inline=False,
    )
    card.set_footer(
        text=f"The house keeps {percent(take, signed=False)} of everything "
        "staked against it. That is the whole of its advantage, and it is "
        "checked by the schema."
    )
    return card


# 0159 briefly settled a wager where it was issued, which meant anybody could
# put another cultivator's Jade at risk without being asked. 0160 took that
# back and went further than the flow before it: BOTH sides press, rather than
# the challenger consenting by typing and the opponent pressing. A mistyped
# mention is not a wager.


def offer_card(
    challenger: discord.abc.User,
    opponent: discord.abc.User,
    stake: int,
    said_yes: set[int],
) -> discord.Embed:
    """A wager on the table, and who has put a hand on it.

    Both sides press. The challenger typing the command is not their
    acceptance - a mistyped mention should not be a wager, and requiring the
    press is what makes that true.
    """
    card = embed(
        f"\N{GAME DIE} {thousands(stake)} Spirit Jade a side",
        f"**{challenger.display_name}** against **{opponent.display_name}** "
        f"\N{EM DASH} a hundred-sided roll each, higher takes {JADE} "
        f"**{thousands(stake * 2)}**. A tie hands both stakes back.\n\n"
        "**Both of you have to accept.** Your stake is held the moment you do, "
        "and comes back whole if the other says no or the clock runs out.",
        colour=COLOUR_INFO,
    )
    card.add_field(
        name="Accepted",
        value="\n".join(
            ("\N{WHITE HEAVY CHECK MARK} " if who.id in said_yes
             else "\N{HOURGLASS WITH FLOWING SAND} ")
            + f"**{who.display_name}**"
            + ("" if who.id in said_yes else "  *\N{EM DASH} waiting*")
            for who in (challenger, opponent)
        ),
        inline=False,
    )
    return card


def duel_card(
    challenger: discord.abc.User, opponent: discord.abc.User, done: dict
) -> discord.Embed:
    """Both dice, then who took the pot."""
    rolls = (
        f"**{challenger.display_name}** rolled **{done['challenger_roll']}**\n"
        f"**{opponent.display_name}** rolled **{done['opponent_roll']}**"
    )

    if done["tied"]:
        card = embed(
            f"\N{HANDSHAKE} {done['challenger_roll']} against "
            f"{done['opponent_roll']}",
            f"{rolls}\n\nA tie. Both stakes go home \N{EM DASH} {JADE} "
            f"**{thousands(done['stake'])}** each.",
            colour=COLOUR_DEFAULT,
        )
    else:
        won = (
            challenger
            if done["winner_id"] == done["challenger_id"]
            else opponent
        )
        lost = opponent if won is challenger else challenger
        card = embed(
            f"\N{GAME DIE} {won.display_name} takes it",
            f"{rolls}\n\n{JADE} **{thousands(done['pot'])}** to "
            f"**{won.display_name}**, out of **{lost.display_name}**'s purse.",
            colour=COLOUR_GOOD,
        )

    return card


class WagerView(AnsweringView):
    """A wager waiting on two people.

    Either may walk away and that ends it, because a wager one side has gone
    cold on is not a wager. Only the person who has not yet accepted can
    accept, which the database enforces too - this only says so in English
    first.
    """

    def __init__(
        self,
        wager_id: int,
        challenger: discord.abc.User,
        opponent: discord.abc.User,
        stake: int,
    ) -> None:
        super().__init__(timeout=600)
        self.wager_id = wager_id
        self.challenger = challenger
        self.opponent = opponent
        self.stake = stake
        self.said_yes: set[int] = set()

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id in (self.challenger.id, self.opponent.id):
            return True
        await interaction.response.send_message(
            "That wager is not yours to answer.", ephemeral=True
        )
        return False

    def close(self) -> None:
        for item in self.children:
            item.disabled = True
        self.stop()

    @discord.ui.button(
        label="Accept", emoji="\N{GAME DIE}", style=discord.ButtonStyle.success
    )
    async def accept(self, interaction: discord.Interaction, button) -> None:
        who = await require_player(interaction.user)
        try:
            step = await db.fetch_one(
                "SELECT * FROM accept_wager(%s, %s)",
                (self.wager_id, who["player_id"]),
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        self.said_yes.add(interaction.user.id)

        if not step["settled"]:
            await interaction.response.edit_message(
                embed=offer_card(
                    self.challenger, self.opponent, self.stake, self.said_yes
                ),
                view=self,
            )
            return

        self.close()
        await interaction.response.edit_message(
            embed=duel_card(self.challenger, self.opponent, step), view=self
        )

    @discord.ui.button(label="Decline", style=discord.ButtonStyle.secondary)
    async def decline(self, interaction: discord.Interaction, button) -> None:
        who = await require_player(interaction.user)
        try:
            off = await db.fetch_one(
                "SELECT * FROM decline_wager(%s, %s)",
                (self.wager_id, who["player_id"]),
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        self.close()
        await interaction.response.edit_message(
            embed=embed(
                "Left on the table",
                f"**{interaction.user.display_name}** walked away."
                + (f"\n\n{JADE} **{thousands(off['refunded'])}** back to "
                   "whoever had already staked it."
                   if off["refunded"] else "\n\nNothing had been staked yet."),
                colour=COLOUR_DEFAULT,
            ),
            view=self,
        )

    async def on_timeout(self) -> None:
        # `expire_wagers` is what actually refunds; the next screen to look
        # sweeps it. Disabling here only stops a dead button being pressed.
        for item in self.children:
            item.disabled = True


class Gamble(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @app_commands.command(
        description="Stake Spirit Jade against the house, or against somebody else."
    )
    @app_commands.describe(
        stake="How much Spirit Jade to put up. Omit to just read the table.",
        against="Who to stake it against. Omit to play the house.",
    )
    async def gamble(
        self,
        interaction: discord.Interaction,
        stake: app_commands.Range[int, 1, 1000] | None = None,
        against: discord.Member | None = None,
    ) -> None:
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])
        # Sweeps anything half-agreed that ran out its clock while nobody was
        # looking, which is what stands in for a scheduler here.
        await db.execute("SELECT expire_wagers()")

        if stake is None:
            jade = await db.fetch_value(
                "SELECT jade_held(%s)", (player["player_id"],)
            )
            await interaction.response.send_message(embed=await render_table(jade))
            return

        if against is None:
            await interaction.response.send_message(
                embed=await self.house(player["player_id"], stake)
            )
            return

        if against.id == interaction.user.id:
            raise GameError("You cannot stake against yourself.")
        if against.bot:
            raise GameError(
                "Leave the bots out of it \N{EM DASH} **/gamble** with no "
                "opponent plays the house."
            )

        other = await require_player(against)
        try:
            made = await db.fetch_one(
                "SELECT * FROM offer_wager(%s, %s, %s)",
                (player["player_id"], other["player_id"], stake),
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        view = WagerView(made["wager_id"], interaction.user, against, stake)
        await interaction.response.send_message(
            content=against.mention,
            embed=offer_card(interaction.user, against, stake, set()),
            view=view,
        )

    async def house(self, player_id: int, stake: int) -> discord.Embed:
        try:
            got = await db.fetch_one(
                "SELECT * FROM play_house(%s, %s)", (player_id, stake)
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        won = got["net"] > 0
        card = embed(
            f"{got['emoji']} {got['roll']} \N{EM DASH} {got['band_name']}",
            f"*{got['flavour']}*",
            colour=COLOUR_GOOD if won else (
                COLOUR_DEFAULT if got["net"] == 0 else COLOUR_BAD
            ),
        )
        card.add_field(
            name="Staked",
            value=f"{JADE} {thousands(got['stake'])}",
        )
        card.add_field(
            name="Paid",
            value=f"{JADE} {thousands(got['paid'])} "
            f"({got['multiplier']:g}\N{MULTIPLICATION SIGN})",
        )
        card.add_field(
            name="Net",
            value=f"{'+' if got['net'] > 0 else ''}{thousands(got['net'])}",
        )
        card.set_footer(text=f"{thousands(got['jade_left'])} Spirit Jade left.")
        return card


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Gamble(bot))
