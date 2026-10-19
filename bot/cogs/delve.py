"""The deep places: /delve.

One cultivator, a dark map under wherever they are standing, and a fixed
number of actions to spend on it. Two screens like a Trial, and for the same
reason: a player should never have to know which one they are on.

    walking   the map, what is left of the light, and how deep the stone goes
    fighting  what is in the way, and whether to kill it or leave it

WHY ANYONE GOES DOWN: the stone. `mine` caps every strike at the miner's own
tier, and most cultivators are held at tier 1 by a profession they have not
levelled. Depth lifts that cap - it is a floor, never a ceiling - so a delve
is where a middling miner touches tier 6 ore.

IT DOES NOT RE-IMPLEMENT ANYTHING. A seam calls `mine`, a growth calls
`gather`, a trace calls `explore`. What a delve adds is the cap and the number
of pulls, which is all "better rates" ever meant.
"""

import logging

import discord
import psycopg
from discord import app_commands
from discord.ext import commands

from bot import database as db
from bot.formatting import (
    COLOUR_BAD,
    COLOUR_GOOD,
    COLOUR_INFO,
    bar,
    embed,
    thousands,
)
from bot.players import GameError, require_player, settle_passive
from bot.views import AnsweringView

log = logging.getLogger("gu.delve")

DOT = "\N{BULLET}"

WAYS = (
    ("up", "\N{UPWARDS BLACK ARROW}", 0),
    ("left", "\N{LEFTWARDS BLACK ARROW}", 1),
    ("right", "\N{BLACK RIGHTWARDS ARROW}", 1),
    ("down", "\N{DOWNWARDS BLACK ARROW}", 2),
)

OUTCOMES = {
    "climbed_out": (COLOUR_GOOD, "\N{SUNRISE OVER MOUNTAINS} You climb back out"),
    "spent": (COLOUR_INFO, "\N{SUNRISE OVER MOUNTAINS} You climb back out"),
    "died": (COLOUR_BAD, "\N{SKULL} You do not climb back out"),
}


def refuse(exc: psycopg.errors.CheckViolation) -> GameError:
    return GameError(str(exc).splitlines()[0].capitalize())


async def fetch_delve(player_id: int) -> dict | None:
    return await db.fetch_one(
        """
        SELECT d.delve_id, d.region_code, d.width, d.height, d.at_x, d.at_y,
               d.actions_left, d.deepest, d.status, d.outcome,
               g.name AS region_name, g.emoji AS region_emoji,
               delve_render(d.delve_id) AS grid,
               delve_tier_floor(d.player_id) AS tier_floor,
               mining_tier_cap(profession_level(d.player_id, 'mining'))
                   AS own_cap,
               pp.current_hp, pp.max_hp,
               (SELECT count(*) FROM delve_tiles t
                WHERE t.delve_id = d.delve_id AND NOT t.seen) AS unwalked,
               delve_haul_of(d.delve_id) AS haul
        FROM delve_runs d
        JOIN regions g ON g.code = d.region_code
        LEFT JOIN player_physique pp ON pp.player_id = d.player_id
        WHERE d.player_id = %s AND d.status <> 'done'
        LIMIT 1
        """,
        (player_id,),
    )


async def fetch_fight(delve_id: int) -> dict | None:
    return await db.fetch_one(
        """
        SELECT f.fight_id, f.hp, f.max_hp, f.round_no, f.tile_kind, f.rage,
               s.name AS beast_name,
               k.label AS tile_label, k.emoji AS tile_emoji,
               round(100 * k.bite) AS bite_share,
               mv.name AS move_name, mv.telegraph, mv.answered_by
        FROM delve_fights f
        JOIN creature_species s ON s.species_id = f.species_id
        JOIN delve_tile_kinds k ON k.kind = f.tile_kind
        LEFT JOIN delve_beast_moves mv ON mv.code = f.coming
        WHERE f.delve_id = %s AND f.status = 'fighting'
        LIMIT 1
        """,
        (delve_id,),
    )


async def fetch_moves(player_id: int) -> list[dict]:
    return await db.fetch_all(
        """
        SELECT t.technique_id, t.name, t.category,
               -- What it would actually hit for, not the souvenir stored on
               -- the row. `technique_power_for` is the only honest answer and
               -- test_no_screen_orders_or_prints_a_stored_technique_power
               -- exists because five screens reached for the other one.
               technique_power_for(%(who)s, t.technique_id) AS power,
               technique_trial_answers(t.technique_id) AS covers
        FROM player_techniques pt
        JOIN techniques t ON t.technique_id = pt.technique_id
        WHERE pt.player_id = %(who)s
        -- Anything that mends, wards or pulls first, THEN by power. A regen
        -- has no damage to sort on, so ordering by power alone buries it at
        -- the bottom of twenty-five attacks - or past the limit entirely -
        -- and teaches people they have no support technique. Since 0476 a
        -- mend thrown down here actually mends, so it has to be findable.
        ORDER BY (array_length(technique_trial_answers(t.technique_id), 1)
                  IS NOT NULL) DESC,
                 power DESC, t.name
        LIMIT 25
        """,
        {"who": player_id},
    )


async def fetch_pills(player_id: int) -> list[dict]:
    """What is worth swallowing down here.

    Restoratives only. `take_pill` will happily hand over a cultivation pill
    and refuse an insight one for want of a Path, and neither belongs on a
    screen whose question is whether you survive the next round.
    """
    return await db.fetch_all(
        """
        SELECT p.pill_id, p.name, p.kind, p.quantity
        FROM player_pills p
        WHERE p.owner_id = %s AND p.quantity > 0
          AND p.kind IN ('healing', 'qi')
        ORDER BY p.kind, p.tier DESC, p.name
        LIMIT 25
        """,
        (player_id,),
    )


def found_line(found: list | None) -> str:
    if not found:
        return ""
    return "\n".join(
        f"{DOT} **{thousands(f['how_many'])}x** {f['what']}"
        + (f" \N{PICK} tier {f['tier']}" if f.get("tier") else "")
        + (" \N{SPARKLES} *rich*" if f.get("rich") else "")
        for f in found
    )


# ---------------------------------------------------------------------------


def render_walking(d: dict, last: str | None = None) -> discord.Embed:
    reach = max(d["tier_floor"] or 0, d["own_cap"] or 0)
    card = embed(
        f"\N{PICK} Under {d['region_name']}",
        f"**{d['actions_left']}** action"
        f"{'' if d['actions_left'] == 1 else 's'} of strength left "
        f"{DOT} {d['unwalked']} tiles never walked",
        colour=COLOUR_INFO if d["actions_left"] > 3 else COLOUR_BAD,
    )
    card.add_field(name="Below", value=d["grid"] or "?", inline=False)

    card.add_field(
        name="You",
        value=f"{bar(d['current_hp'] or 0, d['max_hp'] or 1)} "
              f"{thousands(d['current_hp'] or 0)}/{thousands(d['max_hp'] or 1)}",
        inline=False,
    )

    card.add_field(
        name="The stone",
        value=(
            f"Down **{d['deepest']}** row{'' if d['deepest'] == 1 else 's'} "
            f"{DOT} you can work **tier {reach}** ore here"
            + (f"\n*Your own mining reaches tier {d['own_cap']}. "
               f"The depth is what opened the rest.*"
               if (d["tier_floor"] or 0) > (d["own_cap"] or 0) else
               "\n*Your own mining already reaches further than this depth.*")
        ),
        inline=False,
    )

    if last:
        card.add_field(name="⛏ Just now", value=last[:1024], inline=False)

    # The whole point of the tally: you can see what the trip has been worth
    # without scrolling back through every step that produced it.
    card.add_field(
        name="📜 Carrying out",
        value=(d["haul"] or "*nothing yet*")[:1024],
        inline=False,
    )

    card.add_field(
        name="What is down here",
        value=(
            f"\N{BLACK LARGE SQUARE} unwalked  "
            f"\N{WHITE LARGE SQUARE} worked out  "
            f"\N{LARGE BLUE SQUARE} bare rock\n"
            f"\N{PICK} seam  \N{HERB} growth  "
            f"\N{LEFT-POINTING MAGNIFYING GLASS} trace  "
            f"\N{MONEY BAG} hoard  \N{GREEN HEART} jade  "
            f"\N{BOAR} beast  \N{JAPANESE OGRE} the deep thing"
        ),
        inline=False,
    )
    return card


# How to meet each thing a beast announces, said so a player can act on it
# rather than having to remember a table. The key is the move's `answered_by`,
# which is also a stance code - the two sides of the fight are one rule.
MEETS = {
    "guard": ("\N{SHIELD}", "Guard",
              "brace, and it costs a quarter of what it meant to"),
    "press": ("\N{DASH SYMBOL}", "Dodge",
              "it is wide open - slip it and make it pay"),
    "strike": ("\N{COLLISION SYMBOL}", "Heavy attack",
               "take a real bite out of it now or it finishes building"),
    "none": ("\N{EYES}", "Nothing to meet",
             "it is only thinking. A free round to search the lair"),
}


def render_fighting(d: dict, f: dict, last: str | None = None) -> discord.Embed:
    glyph, how, why = MEETS.get(f["answered_by"] or "none", MEETS["none"])

    card = embed(
        f"\N{CROSSED SWORDS} {f['beast_name']}",
        f"**{f['tile_label']}** {DOT} round {f['round_no']}"
        + (f" {DOT} \N{HIGH VOLTAGE SIGN} **{f['rage']} stack"
           f"{'' if f['rage'] == 1 else 's'}** on it"
           if f["rage"] else ""),
        colour=COLOUR_BAD,
    )

    if f["move_name"]:
        card.add_field(
            name=f"\N{WARNING SIGN} {f['move_name']}",
            value=f"*{f['telegraph']}*\n\n{glyph} **{how}** {DOT} {why}",
            inline=False,
        )

    card.add_field(
        name=f"{f['tile_emoji']} It carries",
        value=f"{bar(f['hp'], f['max_hp'])} "
              f"`{100 * f['hp'] / max(1, f['max_hp']):5.1f}%` "
              f"{thousands(f['hp'])}",
        inline=False,
    )
    card.add_field(
        name="\N{BUSTS IN SILHOUETTE} You",
        value=f"{bar(d['current_hp'] or 0, d['max_hp'] or 1)} "
              f"`{100 * (d['current_hp'] or 0) / max(1, d['max_hp'] or 1):5.1f}%` "
              f"{thousands(d['current_hp'] or 0)}",
        inline=False,
    )
    if last:
        card.add_field(name="⚔ Just now",
                       value=last[:1024], inline=False)
    if d["haul"]:
        card.add_field(name="📜 Carrying out",
                       value=d["haul"][:1024], inline=False)
    card.set_footer(text=f"{d['actions_left']} actions left in the delve")
    return card


# ---------------------------------------------------------------------------


class DownButton(discord.ui.Button):
    def __init__(self, screen: "DelveView") -> None:
        self.screen = screen
        super().__init__(label="Go down", emoji="\N{PICK}",
                         style=discord.ButtonStyle.success, row=0)

    async def callback(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        try:
            await db.fetch_value("SELECT delve_open(%s)", (player["player_id"],))
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc
        await self.screen.reload()
        await interaction.response.edit_message(
            embed=await self.screen.card(), view=self.screen
        )


class StepButton(discord.ui.Button):
    def __init__(self, screen: "DelveView", way: str, glyph: str,
                 row: int) -> None:
        self.screen = screen
        self.way = way
        super().__init__(emoji=glyph, style=discord.ButtonStyle.primary, row=row)

    async def callback(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        try:
            step = await db.fetch_one(
                "SELECT * FROM delve_step(%s, %s)",
                (player["player_id"], self.way),
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        told = step["said"] or ""
        spoils = found_line(step["found"])
        if spoils:
            told += "\n" + spoils
        self.screen.last = told.strip() or None

        await self.screen.reload()
        await interaction.response.edit_message(
            embed=await self.screen.card(), view=self.screen
        )


class MoveSelect(discord.ui.Select):
    def __init__(self, screen: "DelveView", moves: list[dict]) -> None:
        self.screen = screen
        super().__init__(
            placeholder="What do you throw?",
            options=[
                discord.SelectOption(
                    label=m["name"][:100],
                    value=str(m["technique_id"]),
                    description=(
                        ("/".join(m["covers"]) + " \N{BULLET} ")
                        if m["covers"] else ""
                    ) + (f"{thousands(m['power'])} power"
                         if m["power"] else m["category"])[:80],
                    emoji="\N{HERB}" if m["covers"] and "mend" in m["covers"]
                    else ("\N{SHIELD}" if m["covers"]
                          else "\N{CROSSED SWORDS}"),
                )
                for m in moves
            ] or [discord.SelectOption(label="nothing to throw", value="0")],
            row=0,
        )
        for option in self.options:
            option.default = (screen.chosen is not None
                              and option.value == str(screen.chosen))

    async def callback(self, interaction: discord.Interaction) -> None:
        """Picking a technique no longer spends the round.

        The stance buttons are what resolve a round now, so this only decides
        WHAT you throw when you do. Swinging on selection would have meant
        choosing a technique and choosing how to meet the beast were the same
        press, which is the thing the telegraph exists to separate.
        """
        await require_player(interaction.user)
        if self.values[0] == "0":
            raise GameError("You have not learned a technique to throw.")
        self.screen.chosen = int(self.values[0])
        self.screen.build()
        await interaction.response.edit_message(
            embed=await self.screen.card(), view=self.screen
        )


# The four ways to meet a round, in the order they are offered.
STANCES = (
    ("strike", "Strike", "\N{CROSSED SWORDS}", 1),
    ("guard", "Guard", "\N{SHIELD}", 1),
    ("press", "Dodge", "\N{DASH SYMBOL}", 1),
    ("search", "Search the lair", "\N{MONEY BAG}", 2),
)


class StanceButton(discord.ui.Button):
    """One way of meeting what is coming.

    The stance that answers this round is drawn in green. That is not
    the game giving anything away - the telegraph already said it in
    words, and a button that quietly disagrees with the text above it
    is worse than no button at all.
    """

    def __init__(self, screen: "DelveView", code: str, label: str,
                 glyph: str, row: int, right: bool) -> None:
        self.screen = screen
        self.code = code
        super().__init__(
            label=label, emoji=glyph, row=row,
            style=discord.ButtonStyle.success if right
            else discord.ButtonStyle.secondary,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        await require_player(interaction.user)
        await self.screen.swing(interaction, self.code)


class FleeButton(discord.ui.Button):
    def __init__(self, screen: "DelveView", costs: int) -> None:
        self.screen = screen
        # Row 2 with Search and the redraw, so row 1 holds the three ways of
        # meeting what is coming and nothing else.
        super().__init__(label=f"Back away ({costs} actions)",
                         emoji="\N{RUNNER}",
                         style=discord.ButtonStyle.secondary, row=2)

    async def callback(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        try:
            await db.fetch_one("SELECT * FROM delve_flee(%s)",
                               (player["player_id"],))
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc
        self.screen.last = ("You back away. It is still there, "
                            "and so is the tile.")
        await self.screen.reload()
        await interaction.response.edit_message(
            embed=await self.screen.card(), view=self.screen
        )


class PillSelect(discord.ui.Select):
    """Swallowing something, at no cost in actions.

    Pills are finite and somebody brewed them. Charging a tile to take one
    you are already carrying would just mean nobody carries one down.
    """

    def __init__(self, screen: "DelveView", pills: list[dict], row: int) -> None:
        self.screen = screen
        super().__init__(
            placeholder="Take a pill (costs no action)",
            options=[
                discord.SelectOption(
                    label=pill["name"][:100],
                    value=str(pill["pill_id"]),
                    description=f"{pill['kind']} \N{BULLET} "
                                f"{pill['quantity']} held"[:100],
                    emoji="\N{PILL}",
                )
                for pill in pills
            ] or [discord.SelectOption(label="nothing to take", value="0")],
            row=row,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        if self.values[0] == "0":
            raise GameError("You are carrying nothing to take.")
        try:
            took = await db.fetch_one(
                "SELECT * FROM delve_swallow(%s, %s)",
                (player["player_id"], int(self.values[0])),
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        self.screen.last = (
            f"\N{PILL} **{took['pill_name']}** \N{EM DASH} {took['detail']}"
            f"{chr(10)}You are at {thousands(took['my_hp'])}"
            f"/{thousands(took['my_max'])}."
        )
        await self.screen.reload()
        await interaction.response.edit_message(
            embed=await self.screen.card(), view=self.screen
        )


class RestButton(discord.ui.Button):
    def __init__(self, screen: "DelveView", costs: int, hurt: bool) -> None:
        self.screen = screen
        super().__init__(
            label=f"Rest ({costs} action)", emoji="\N{SLEEPING SYMBOL}",
            style=discord.ButtonStyle.success if hurt
            else discord.ButtonStyle.secondary,
            row=3,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        try:
            rested = await db.fetch_one(
                "SELECT * FROM delve_rest(%s)", (player["player_id"],)
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        self.screen.last = (
            f"\N{SLEEPING SYMBOL} You sit down against the rock and "
            f"take **{thousands(rested['healed'])}** back."
        )
        await self.screen.reload()
        await interaction.response.edit_message(
            embed=await self.screen.card(), view=self.screen
        )


class LookButton(discord.ui.Button):
    def __init__(self, screen: "DelveView", row: int = 1) -> None:
        self.screen = screen
        super().__init__(
            emoji="\N{ANTICLOCKWISE DOWNWARDS AND UPWARDS OPEN CIRCLE ARROWS}",
            style=discord.ButtonStyle.secondary, row=row)

    async def callback(self, interaction: discord.Interaction) -> None:
        await require_player(interaction.user)
        await self.screen.reload()
        await interaction.response.edit_message(
            embed=await self.screen.card(), view=self.screen
        )


class DelveView(AnsweringView):
    def __init__(self, player_id: int) -> None:
        super().__init__(timeout=1800)
        self.player_id = player_id
        self.delve: dict | None = None
        self.fight: dict | None = None
        self.moves: list[dict] = []
        self.flee_cost = 2
        self.rest_cost = 1
        # What the last action did. Shown IN the card rather than sent as its
        # own message: a sixteen-action delve was producing sixteen chat
        # messages, which buried the thing they were reporting.
        self.last: str | None = None
        # Which technique the stance buttons will throw. A stance
        # button has no room to carry one, so the select parks it here.
        self.chosen: int | None = None
        self.pills: list[dict] = []

    async def reload(self) -> None:
        self.delve = await fetch_delve(self.player_id)
        self.fight = None
        if self.delve is not None:
            self.pills = await fetch_pills(self.player_id)
        if self.delve is not None and self.delve["status"] == "fighting":
            self.fight = await fetch_fight(self.delve["delve_id"])
            self.moves = await fetch_moves(self.player_id)
            self.flee_cost = await db.fetch_value(
                "SELECT game_config_value('delve_flee_actions')::int"
            )
        self.build()

    async def swing(self, interaction: discord.Interaction,
                    stance: str) -> None:
        """One round, met the way the player chose.

        The technique is whatever they last picked from the select and is
        carried on the view, because a stance button has no room to hold one.
        """
        player = await require_player(interaction.user)
        try:
            blow = await db.fetch_one(
                "SELECT * FROM delve_act(%s, %s, %s)",
                (player["player_id"], stance, self.chosen),
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        told = [
            f"**{blow['was_name']}** "
            + ("\N{WHITE HEAVY CHECK MARK} you met it"
               if blow["answered"]
               else "\N{HEAVY EXCLAMATION MARK SYMBOL} you did not"),
            f"*{blow['said']}*",
            f"You deal **{thousands(blow['dealt'])}**"
            + (f" and it takes **{thousands(blow['taken'])}** out of you"
               if blow["taken"] else " and it does not touch you")
            + ".",
        ]
        if blow["rage"]:
            told.append(f"\N{HIGH VOLTAGE SIGN} It carries "
                        f"**{blow['rage']}** stack"
                        f"{'' if blow['rage'] == 1 else 's'} now.")
        if blow["outcome"] == "slain":
            told.insert(0, "\N{CROSSED SWORDS} **It goes down.**")
        elif blow["outcome"] == "died":
            told.insert(0, "\N{SKULL} **It stands over you.**")
        spoils = found_line(blow["found"])
        if spoils:
            told.append("It was carrying:")
            told.append(spoils)
        self.last = "\n".join(told)

        await self.reload()
        await interaction.response.edit_message(
            embed=await self.card(), view=self
        )

    async def card(self) -> discord.Embed:
        if self.delve is None:
            return await self.done_card()
        if self.delve["status"] == "fighting" and self.fight is not None:
            return render_fighting(self.delve, self.fight, self.last)
        return render_walking(self.delve, self.last)

    async def done_card(self) -> discord.Embed:
        last = await db.fetch_one(
            """
            SELECT d.outcome, d.deepest, d.actions_left, g.name AS region_name,
                   delve_haul_of(d.delve_id) AS haul
            FROM delve_runs d JOIN regions g ON g.code = d.region_code
            WHERE d.player_id = %s ORDER BY d.delve_id DESC LIMIT 1
            """,
            (self.player_id,),
        )
        if last is None or last["outcome"] is None:
            return embed(
                "\N{PICK} The deep places",
                "There is stone under wherever you are standing, and most of "
                "it is deeper than your mining can reach. Going down opens it.",
                colour=COLOUR_INFO,
            )
        colour, title = OUTCOMES.get(last["outcome"], (COLOUR_INFO, "It is over"))
        card = embed(
            title,
            f"You went **{last['deepest']}** row"
            f"{'' if last['deepest'] == 1 else 's'} under "
            f"{last['region_name']}.",
            colour=colour,
        )
        if last["haul"]:
            card.add_field(name="📜 You came out with",
                           value=last["haul"][:1024], inline=False)
        return card

    def build(self) -> None:
        self.clear_items()
        if self.delve is None:
            self.add_item(DownButton(self))
            return

        if self.delve["status"] == "fighting" and self.fight is not None:
            answers = self.fight["answered_by"]
            self.add_item(MoveSelect(self, self.moves))
            for code, label, glyph, row in STANCES:
                self.add_item(StanceButton(
                    self, code, label, glyph, row, code == answers))
            self.add_item(FleeButton(self, self.flee_cost))
            self.add_item(LookButton(self, row=2))
            # A pill costs no action, so it belongs in a fight as much as on
            # the map - and this is the screen where you find out you need it.
            if self.pills:
                self.add_item(PillSelect(self, self.pills, row=3))
            return

        for way, glyph, row in WAYS:
            self.add_item(StepButton(self, way, glyph, row))
        hurt = (self.delve["current_hp"] or 0) < (self.delve["max_hp"] or 1)
        self.add_item(RestButton(
            self, self.rest_cost, hurt))
        self.add_item(LookButton(self, row=3))
        if self.pills:
            self.add_item(PillSelect(self, self.pills, row=4))


class Delve(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @app_commands.command(
        description="Go under the region you are standing in for deep ore, "
                    "and what lives down there."
    )
    async def delve(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])

        view = DelveView(player["player_id"])
        await view.reload()
        await interaction.response.send_message(
            embed=await view.card(), view=view
        )


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Delve(bot))
