"""Duels: /duel and /yield.

Two cultivators, one round at a time, and BOTH BLOWS AT ONCE. That is the
whole difference from a hunt: `battle_act` resolves your half and the
creature's answer together because the creature has no say, and a duel cannot
work that way - so a duel goes through `duel_choose`, which records what you
picked and resolves the round the moment the second of you has picked too.
Neither of you learns what the other chose until both are locked in.

A CHALLENGE IS ACCEPTED, NEVER IMPOSED. `duel_open` would take any two player
ids, and a command that drew somebody into a fight without their word would be
a way to pester people rather than a way to fight them. So /duel names an
opponent, posts the challenge, and waits.

Nothing here computes damage or decides a winner. `duel_resolve` does both,
through the same `compute_duel_damage` the raid's betrayal uses, so a duel is
not a second opinion about how hard anybody hits.

THE ROUND HAS A CLOCK. Nothing ticks in this game, so the clock is read the
next time somebody looks: "Press on" calls `duel_force`, which braces whoever
has not answered - and refuses until the round has actually run out, because
0548 shipped that guard on the wrong column and 0549 moved it onto the round's
own timestamp. Without it, forcing was a way to win every duel untouched.
"""

import discord
import psycopg
from discord import app_commands
from discord.ext import commands

from bot import database as db
from bot.battle import health_block, usable_techniques
from bot.formatting import (
    COLOUR_BAD,
    COLOUR_DEFAULT,
    COLOUR_GOOD,
    COLOUR_INFO,
    embed,
    thousands,
)
from bot.players import GameError, fetch_player, require_player
from bot.views import AnsweringView

BLADE = "\N{CROSSED SWORDS}"
SHIELD = "\N{SHIELD}"
WAIT = "\N{HOURGLASS WITH FLOWING SAND}"
DONE = "\N{WHITE HEAVY CHECK MARK}"
SKULL = "\N{SKULL}"
FLAG = "\N{WAVING WHITE FLAG}"

# Long enough to notice a ping, short enough that a challenge nobody answered
# is not still sitting there tomorrow. The view only stops offering the
# button; `duel_open` was never called, so nothing is left behind.
CHALLENGE_SECONDS = 180


def refuse(exc: psycopg.errors.CheckViolation) -> GameError:
    return GameError(str(exc).splitlines()[0].capitalize() + ".")


# ---------------------------------------------------------------------------
# What is standing in the duel
# ---------------------------------------------------------------------------


async def duel_seats(battle_id: int) -> tuple[dict, list[dict]] | None:
    """The fight and its two seats, in seat order and never flipped.

    The screen is NEUTRAL - "A vs B", not "you vs them" - because both
    cultivators read the same card and a seat-relative one would be a lie to
    whichever of them is sitting in the other chair. The only part that knows
    who is looking is the set of buttons underneath.
    """
    rows = await db.fetch_all(
        """
        SELECT b.status, b.kind, b.turn_number, b.winner_side,
               c.combatant_no, c.player_id, c.current_hp, c.max_hp,
               c.current_qi, (c.snapshot->>'max_qi')::bigint AS max_qi,
               c.guarding, (c.intent_action IS NOT NULL) AS chosen,
               p.discord_name
        FROM battles b
        JOIN battle_combatants c ON c.battle_id = b.battle_id
        JOIN players p ON p.player_id = c.player_id
        WHERE b.battle_id = %s
        ORDER BY c.combatant_no
        """,
        (battle_id,),
    )
    if len(rows) != 2:
        return None
    return rows[0], rows


async def last_round(battle_id: int) -> list[dict]:
    """The round that was just played, read off the log rather than kept.

    `duel_choose` resolves the round and returns only whether anybody is still
    being waited on, so the blows are not handed back to the caller. They do
    not need to be: `duel_resolve` writes both of them to `battle_actions`,
    which is what makes the screen reopenable - the other cultivator's copy of
    it shows the same round, and so does yours after a restart.
    """
    return await db.fetch_all(
        """
        SELECT a.actor_no, a.technique_name, a.damage, a.detail
        FROM battle_actions a
        WHERE a.battle_id = %s
          AND a.turn_number = (SELECT max(a2.turn_number)
                               FROM battle_actions a2
                               WHERE a2.battle_id = %s)
        ORDER BY a.actor_no
        """,
        (battle_id, battle_id),
    )


def _ending(fight: dict, seats: list[dict]) -> tuple[str, str, int]:
    """Title, sentence and colour for a duel that is over.

    The three endings `duel_resolve` can write are told apart here because
    they mean different things and `status` alone does not say: 'complete' is
    a win, 'fled' is what a double knockout is recorded as, and 'expired' is
    the turn cap 0548 put on it - two cultivators who guarded until the sky
    lost interest.
    """
    if fight["winner_side"] is not None:
        won = seats[fight["winner_side"]]
        lost = seats[1 - fight["winner_side"]]
        return (
            f"{BLADE} {won['discord_name']} stands",
            f"**{lost['discord_name']}** does not. "
            f"{won['discord_name']} walks away with it.",
            COLOUR_GOOD,
        )
    if fight["status"] == "expired":
        return (
            f"{SHIELD} Neither of you moved",
            "The duel ran out of rounds. Two cultivators who will not swing "
            "are not fighting, and nobody won.",
            COLOUR_DEFAULT,
        )
    return (
        f"{SKULL} Both of you fall",
        "You landed together and neither got up. Nobody takes it.",
        COLOUR_BAD,
    )


def render_duel(
    fight: dict, seats: list[dict], lines: list[dict] | None = None
) -> discord.Embed:
    a, b = seats
    over = fight["status"] != "active"

    if over:
        title, said, colour = _ending(fight, seats)
    else:
        title = f"{BLADE} {a['discord_name']} vs {b['discord_name']}"
        said = f"**Round {fight['turn_number']}**"
        colour = COLOUR_INFO

    card = embed(title, said, colour=colour)

    for seat in seats:
        # Once it is over, "still choosing" is not a thing anybody is doing -
        # the hourglass sat on the winner of a finished duel.
        if seat["current_hp"] <= 0:
            mark = SKULL
        elif over:
            mark = BLADE
        else:
            mark = DONE if seat["chosen"] else WAIT
        block = health_block(
            seat["discord_name"], mark, seat["current_hp"], seat["max_hp"]
        )
        # Qi is on the card because a duel is won by what you can still afford
        # to throw, and this is the only screen that shows both sides of that.
        block += (
            f"\n\N{CYCLONE} Qi `{thousands(seat['current_qi'])} / "
            f"{thousands(seat['max_qi'] or seat['current_qi'])}`"
        )
        if seat["guarding"] and not over:
            block += f" \N{BULLET} {SHIELD} braced"
        card.add_field(name="​", value=block, inline=False)

    if lines:
        told = []
        for one in lines:
            who = seats[one["actor_no"]]["discord_name"]
            detail = one["detail"] or {}
            if detail.get("guarded"):
                told.append(f"{SHIELD} **{who}** braced.")
                continue
            told.append(
                f"{BLADE} **{who}** struck with {one['technique_name']} "
                f"\N{EM DASH} {thousands(one['damage'] or 0)}"
                + (f" {SKULL} **down**" if detail.get("felled") else "")
            )
        card.add_field(name="Last round", value="\n".join(told), inline=False)

    if over:
        card.set_footer(text="**/duel @them** to draw on somebody again.")
    else:
        waiting = [s["discord_name"] for s in seats if not s["chosen"]]
        card.set_footer(
            text="Both of you have chosen."
            if not waiting
            else f"Waiting on {', '.join(waiting)} \N{BULLET} neither of you "
            "sees the other's move until both have picked."
        )
    return card


# ---------------------------------------------------------------------------
# The challenge
# ---------------------------------------------------------------------------


class AcceptButton(discord.ui.Button):
    def __init__(self, screen: "Challenge") -> None:
        self.screen = screen
        super().__init__(
            label="Draw", emoji=BLADE, style=discord.ButtonStyle.danger
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        them = await require_player(interaction.user)
        try:
            battle_id = await db.fetch_value(
                "SELECT duel_open(%s, %s)",
                (self.screen.challenger_id, them["player_id"]),
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        fight, seats = await duel_seats(battle_id)
        for item in self.screen.children:
            item.disabled = True
        self.screen.stop()

        # The public record of the fight, with no controls on it: the moves
        # belong on each cultivator's own screen, because the techniques
        # listed there are theirs. **/duel** is how either of them opens it,
        # the same way **/dungeon** reopens a room.
        card = render_duel(fight, seats)
        card.set_footer(text="**/duel** \N{EM DASH} both of you, to take your turn.")
        await interaction.response.edit_message(embed=card, view=self.screen)


class DeclineButton(discord.ui.Button):
    def __init__(self, screen: "Challenge") -> None:
        self.screen = screen
        super().__init__(label="Walk away", style=discord.ButtonStyle.secondary)

    async def callback(self, interaction: discord.Interaction) -> None:
        for item in self.screen.children:
            item.disabled = True
        self.screen.stop()
        await interaction.response.edit_message(
            embed=embed(
                "The challenge goes unanswered",
                f"**{interaction.user.display_name}** does not draw. "
                "Nothing was staked and nothing was lost.",
                colour=COLOUR_DEFAULT,
            ),
            view=self.screen,
        )


class Challenge(AnsweringView):
    """A duel offered, which is not a duel yet.

    No row exists in `battles` until the button is pressed. That is the
    consent: `duel_open` is called by the person being challenged, not by the
    person challenging them, so nobody is ever pulled into a fight by somebody
    else typing a command.
    """

    def __init__(self, challenger_id: int, challenger: discord.abc.User,
                 target: discord.abc.User) -> None:
        super().__init__(timeout=CHALLENGE_SECONDS)
        self.challenger_id = challenger_id
        self.challenger = challenger
        self.target = target
        self.message: discord.Message | None = None
        self.add_item(AcceptButton(self))
        self.add_item(DeclineButton(self))

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.target.id:
            await interaction.response.send_message(
                "That challenge is not yours to answer.", ephemeral=True
            )
            return False
        return True

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True
        if self.message is not None:
            try:
                await self.message.edit(view=self)
            except discord.HTTPException:
                pass


# ---------------------------------------------------------------------------
# The duel itself
# ---------------------------------------------------------------------------


class MoveSelect(discord.ui.Select):
    """Your own techniques, which is why this screen is yours and not shared.

    Unaffordable moves are listed and refused rather than hidden, the same
    call `/battle` makes: a cultivator needs to see that the good one is one
    braced round away, not wonder where it went.
    """

    def __init__(self, screen: "Duel") -> None:
        self.screen = screen
        mine = screen.me
        options = []
        for row in screen.techniques:
            cost = row["qi_cost"]
            options.append(
                discord.SelectOption(
                    label=f"{row['name']} \N{BULLET} {thousands(cost)} qi"[:100],
                    value=str(row["technique_id"]),
                    description=(
                        (
                            f"power {thousands(row['base_power'])}"
                            if row["category"] == "attack" or not row["effect_text"]
                            else row["effect_text"]
                        )
                        + ("" if cost <= mine["current_qi"] else " \N{BULLET} not enough qi")
                    )[:100],
                    emoji=row["emoji"][:1] if row["emoji"] else None,
                )
            )
        super().__init__(placeholder="Strike with\N{HORIZONTAL ELLIPSIS}",
                         options=options, row=0)

    async def callback(self, interaction: discord.Interaction) -> None:
        await self.screen.choose(interaction, "attack", int(self.values[0]))


class GuardButton(discord.ui.Button):
    def __init__(self, screen: "Duel") -> None:
        self.screen = screen
        super().__init__(label="Brace", emoji=SHIELD,
                         style=discord.ButtonStyle.secondary, row=1)

    async def callback(self, interaction: discord.Interaction) -> None:
        await self.screen.choose(interaction, "guard")


class PressOnButton(discord.ui.Button):
    """For a round the other cultivator walked out of.

    It is not a refresh and it is not free: `duel_force` braces whoever has
    not answered, and refuses until the round has genuinely run out. Before
    0549 it read the wrong clock and could be pressed the instant a round
    resolved - which braced both sides over and over and drew the duel on
    demand. The refusal it gives now is a sentence, so the button can simply
    be offered and the answer read.
    """

    def __init__(self, screen: "Duel") -> None:
        self.screen = screen
        super().__init__(label="Press on", emoji=WAIT,
                         style=discord.ButtonStyle.primary, row=1)

    async def callback(self, interaction: discord.Interaction) -> None:
        try:
            await db.execute(
                "SELECT duel_force(%s)", (self.screen.battle_id,)
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc
        await self.screen.redraw(interaction, played=True)


class YieldButton(discord.ui.Button):
    def __init__(self, screen: "Duel") -> None:
        self.screen = screen
        super().__init__(label="Yield", emoji=FLAG,
                         style=discord.ButtonStyle.danger, row=1)

    async def callback(self, interaction: discord.Interaction) -> None:
        try:
            await db.execute(
                "SELECT duel_concede(%s, %s)",
                (self.screen.battle_id, self.screen.player_id),
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc
        await self.screen.redraw(interaction)


class Duel(AnsweringView):
    """One cultivator's side of a duel.

    Each of them opens their own with **/duel**, because the moves on it are
    theirs. The card is the same card on both screens - the fight is a row in
    `battles` and this is a window onto it, so a timeout, a restart or a lost
    message costs nothing.
    """

    def __init__(self, player_id: int, user: discord.abc.User, battle_id: int,
                 fight: dict, seats: list[dict], techniques: list[dict],
                 lines: list[dict] | None = None) -> None:
        super().__init__(timeout=900)
        self.player_id = player_id
        self.user = user
        self.battle_id = battle_id
        self.fight = fight
        self.seats = seats
        self.techniques = techniques
        self.lines = lines
        self.message: discord.Message | None = None
        self.build()

    @property
    def me(self) -> dict:
        return next(s for s in self.seats if s["player_id"] == self.player_id)

    @property
    def them(self) -> dict:
        return next(s for s in self.seats if s["player_id"] != self.player_id)

    @classmethod
    async def build_for(cls, player_id: int, user: discord.abc.User,
                        battle_id: int) -> "Duel":
        fight, seats = await duel_seats(battle_id)
        mine = next(s for s in seats if s["player_id"] == player_id)
        techniques = await usable_techniques(
            player_id, mine["max_qi"] or mine["current_qi"]
        )
        return cls(player_id, user, battle_id, fight, seats, techniques,
                   await last_round(battle_id))

    def build(self) -> None:
        self.clear_items()
        if self.fight["status"] != "active":
            return
        # Already answered: the only thing left to do this round is wait for
        # them, or stop waiting.
        if not self.me["chosen"] and self.techniques:
            self.add_item(MoveSelect(self))
        if not self.me["chosen"]:
            self.add_item(GuardButton(self))
        self.add_item(PressOnButton(self))
        self.add_item(YieldButton(self))

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "That is not your duel.", ephemeral=True
            )
            return False
        return True

    async def on_timeout(self) -> None:
        # The duel outlives the view on purpose: nothing is resolved here.
        for item in self.children:
            item.disabled = True
        if self.message is not None:
            try:
                await self.message.edit(view=self)
            except discord.HTTPException:
                pass

    async def choose(self, interaction: discord.Interaction, action: str,
                     technique_id: int | None = None) -> None:
        try:
            answer = await db.fetch_one(
                "SELECT * FROM duel_choose(%s, %s, %s, %s)",
                (self.battle_id, self.player_id, action, technique_id),
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc
        # `waiting` false means the round resolved on this very call - the
        # second cultivator to choose is the one who plays the round, so
        # whether there is anything new to show depends on which of them you
        # turned out to be.
        await self.redraw(interaction, played=not answer["waiting"])

    async def redraw(self, interaction: discord.Interaction,
                     played: bool = False) -> None:
        state = await duel_seats(self.battle_id)
        if state is None:
            raise GameError("That duel is gone.")
        self.fight, self.seats = state
        if played:
            self.lines = await last_round(self.battle_id)
        if self.fight["status"] == "active":
            self.techniques = await usable_techniques(
                self.player_id, self.me["max_qi"] or self.me["current_qi"]
            )
        self.build()
        if self.fight["status"] != "active":
            self.stop()
        await interaction.response.edit_message(
            embed=render_duel(self.fight, self.seats, self.lines), view=self
        )


# ---------------------------------------------------------------------------


class Duels(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @app_commands.command(description="Draw on another cultivator, or take your turn.")
    @app_commands.describe(
        opponent="Who to challenge. Leave it out for the duel you are already in."
    )
    async def duel(
        self, interaction: discord.Interaction,
        opponent: discord.Member | None = None,
    ) -> None:
        me = await require_player(interaction.user)

        standing = await db.fetch_one(
            """
            SELECT a.battle_id, b.kind
            FROM player_active_battle a
            JOIN battles b ON b.battle_id = a.battle_id
            WHERE a.player_id = %s
            """,
            (me["player_id"],),
        )

        # THE DUEL YOU ARE IN comes first, whoever you named. Challenging
        # somebody while standing in a fight is refused by `duel_open` anyway,
        # and "here is the fight you forgot about" is a better answer than
        # that refusal.
        if standing and standing["kind"] == "duel":
            view = await Duel.build_for(
                me["player_id"], interaction.user, standing["battle_id"]
            )
            await interaction.response.send_message(
                embed=render_duel(view.fight, view.seats, view.lines), view=view
            )
            view.message = await interaction.original_response()
            return

        if standing:
            raise GameError(
                "You are in the middle of a fight. **/battle** to finish it."
            )

        if opponent is None:
            raise GameError(
                "You are not in a duel. **/duel** and name somebody to start one."
            )
        if opponent.id == interaction.user.id:
            raise GameError("You cannot draw on yourself.")
        if opponent.bot:
            raise GameError("That one does not cultivate.")

        them = await fetch_player(opponent.id)
        if them is None:
            raise GameError(
                f"**{opponent.display_name}** has not started cultivating yet."
            )

        view = Challenge(me["player_id"], interaction.user, opponent)
        await interaction.response.send_message(
            content=opponent.mention,
            embed=embed(
                f"{BLADE} {interaction.user.display_name} draws on "
                f"{opponent.display_name}",
                f"**{opponent.display_name}**, this is yours to answer. "
                "Both of you strike in the same round and neither sees the "
                "other's move until both have picked.\n\n"
                "Yielding costs what losing costs, so do not draw on somebody "
                "you are not willing to lose to.",
                colour=COLOUR_INFO,
            ),
            view=view,
        )
        view.message = await interaction.original_response()

    # -----------------------------------------------------------------------

    @app_commands.command(
        name="yield", description="Give up a duel you cannot win."
    )
    async def yield_duel(self, interaction: discord.Interaction) -> None:
        """Deliberately not **/abandon**.

        Abandoning a hunt is honest: the creature keeps its wounds and nobody
        won. A duel has somebody on the other side of it, so walking out has
        to mean they won - otherwise the losing cultivator presses a button
        and the fight never happened. `battle_abandon` refuses a duel outright
        since 0548 for that reason, and `duel_concede` is this.
        """
        me = await require_player(interaction.user)

        standing = await db.fetch_one(
            """
            SELECT a.battle_id FROM player_active_battle a
            JOIN battles b ON b.battle_id = a.battle_id
            WHERE a.player_id = %s AND b.kind = 'duel'
            """,
            (me["player_id"],),
        )
        if standing is None:
            raise GameError("You are not in a duel.")

        try:
            won = await db.fetch_value(
                "SELECT winner FROM duel_concede(%s, %s)",
                (standing["battle_id"], me["player_id"]),
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        name = await db.fetch_value(
            "SELECT discord_name FROM players WHERE player_id = %s", (won,)
        )
        await interaction.response.send_message(
            embed=embed(
                f"{FLAG} You yield",
                f"**{name}** takes it. You are down as surely as if they had "
                "put you there, which is what yielding means.",
                colour=COLOUR_BAD,
            )
        )


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Duels(bot))
