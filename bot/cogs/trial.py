"""The Peer Trial itself: /trial.

A sealed party walks a map. The leader chooses the route; everyone chooses
what they throw. Two screens, one command, because a player should never have
to know which of them they are on.

    walking   the grid, the step budget, and four arrows under the leader
    fighting  what the thing is about to do, and what each peer means to do
              about it

ONLY THE LEADER MOVES, EVERYONE FIGHTS. That split is the whole social shape
of the thing: one person is responsible for where the party is, and nobody is
responsible for what anybody else throws.

THE ROUND RESOLVES WHEN EVERYBODY HAS CHOSEN, and the leader can force it
early for a party that has somebody away from their keyboard. A round that
could only ever be forced would make the leader the only player in the fight;
one that could never be forced would let one quiet peer hold five others.
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

log = logging.getLogger("gu.trial")

DOT = "\N{BULLET}"

# The arrows, in the order they are laid out rather than the order they are
# listed anywhere else: up alone, then the two sideways, then down.
WAYS = (
    ("up", "\N{UPWARDS BLACK ARROW}", 0),
    ("left", "\N{LEFTWARDS BLACK ARROW}", 1),
    ("right", "\N{BLACK RIGHTWARDS ARROW}", 1),
    ("down", "\N{DOWNWARDS BLACK ARROW}", 2),
)

OUTCOMES = {
    "cleared": (COLOUR_GOOD, "\N{TROPHY} The Trial is yours"),
    "wiped": (COLOUR_BAD, "\N{SKULL} The party does not walk back out"),
    "stranded": (COLOUR_BAD, "\N{HOURGLASS} The light ran out"),
}


def refuse(exc: psycopg.errors.CheckViolation) -> GameError:
    return GameError(str(exc).splitlines()[0].capitalize())


async def fetch_map(player_id: int) -> dict | None:
    return await db.fetch_one(
        """
        SELECT m.map_id, m.party_id, m.realm_rank, m.width, m.height,
               m.at_x, m.at_y, m.steps_left, m.caches, m.status, m.outcome,
               p.leader_id, l.discord_name AS leader_name,
               r.name AS realm_name,
               trial_map_render(m.map_id) AS grid,
               trial_map_mover(m.map_id) AS mover_id,
               (SELECT mv.discord_name FROM players mv
                WHERE mv.player_id = trial_map_mover(m.map_id)) AS mover_name,
               (SELECT count(*) FROM trial_map_tiles t
                WHERE t.map_id = m.map_id AND t.kind = 'cache' AND NOT t.spent)
                   AS caches_left
        FROM trial_maps m
        JOIN trial_parties p ON p.party_id = m.party_id
        JOIN players l ON l.player_id = p.leader_id
                -- LEFT JOIN onto `realms` BY RANK, and `trial_party_open` stores
                -- STANDING there since 0519 - so a Venerable's trial matched no
                -- row and the card fell back to "a trial of realm 22". The
                -- Venerable ladder is a second table, so it needs a second look.
        LEFT JOIN LATERAL (
            SELECT COALESCE(
                (SELECT rr.name FROM realms rr
                 WHERE rr.rank = m.realm_rank ORDER BY rr.realm_id LIMIT 1),
                (SELECT v.name FROM venerable_ranks v
                 WHERE v.rank = m.realm_rank)
            ) AS name
        ) r ON TRUE
        WHERE m.party_id = trial_party_of(%s) AND m.status <> 'done'
        LIMIT 1
        """,
        (player_id,),
    )


async def fetch_bodies(map_id: int) -> list[dict]:
    return await db.fetch_all(
        """
        SELECT p.discord_name, b.current_hp, b.max_hp
        FROM trial_map_bodies b
        JOIN players p ON p.player_id = b.player_id
        WHERE b.map_id = %s
        ORDER BY b.player_id
        """,
        (map_id,),
    )


async def fetch_run(map_id: int) -> dict | None:
    return await db.fetch_one(
        """
        SELECT r.run_id, r.round_no, r.boss_hp, r.boss_max_hp, r.stacks,
               r.status, r.outcome, r.tile_kind,
               s.name AS beast_name,
               k.label AS tile_label,
               t.name AS threat_name, t.telegraph, t.answers_with,
               game_config_value('trial_round_cap')::int AS round_cap,
               game_config_value('trial_loot_limit')::int AS loot_limit
        FROM trial_runs r
        JOIN creature_species s ON s.species_id = r.species_id
        LEFT JOIN trial_map_kinds k ON k.kind = r.tile_kind
        LEFT JOIN trial_threats t ON t.code = r.coming
        WHERE r.map_id = %s
        ORDER BY r.run_id DESC LIMIT 1
        """,
        (map_id,),
    )


async def fetch_raiders(run_id: int) -> list[dict]:
    return await db.fetch_all(
        """
        SELECT x.player_id, p.discord_name, x.current_hp, x.max_hp,
               x.damage_dealt, x.looting, x.loots_taken, t.name AS intent
        FROM trial_raiders x
        JOIN players p ON p.player_id = x.player_id
        LEFT JOIN techniques t ON t.technique_id = x.intent_id
        WHERE x.run_id = %s
        ORDER BY x.player_id
        """,
        (run_id,),
    )


async def fetch_moves(player_id: int) -> list[dict]:
    """What this peer can throw, the ones that answer a threat first.

    A fight screen that lists twenty attacks and buries the single regen at the
    bottom is a screen that teaches people they have no support technique.
    """
    return await db.fetch_all(
        """
        SELECT t.technique_id, t.name, t.code,
               COALESCE((SELECT pa.name
                         FROM technique_paths tp
                         JOIN paths pa ON pa.code = tp.path_code
                         WHERE tp.technique_id = t.technique_id
                         ORDER BY tp.weight DESC, pa.code
                         LIMIT 1), t.category) AS path_name,
               technique_trial_answers(t.technique_id) AS covers,
               array_length(technique_trial_answers(t.technique_id), 1)
                   IS NOT NULL AS answers
        FROM player_techniques pt
        JOIN techniques t ON t.technique_id = pt.technique_id
        WHERE pt.player_id = %s
        ORDER BY answers DESC, t.name
        LIMIT 25
        """,
        (player_id,),
    )


# ---------------------------------------------------------------------------
# The two screens
# ---------------------------------------------------------------------------


def render_walking(mp: dict, bodies: list[dict],
                   said: str | None = None) -> discord.Embed:
    card = embed(
        f"\N{COMPASS} The trial of "
        f"{mp['realm_name'] or 'realm ' + str(mp['realm_rank'])}",
        f"**{mp['mover_name']}** has the way, and nobody sees past "
        f"their own feet. "
        f"{mp['steps_left']} step{'' if mp['steps_left'] == 1 else 's'} "
        f"of light left."
        + "\n"
        + f"*{mp['leader_name']} is leading. The step passes to the next "
          f"peer each time.*",
        colour=COLOUR_INFO if mp["steps_left"] > 3 else COLOUR_BAD,
    )
    card.add_field(name="Map", value=mp["grid"] or "\N{BLACK QUESTION MARK ORNAMENT}",
                   inline=False)

    card.add_field(
        name="The party",
        value="\n".join(
            f"{DOT} **{b['discord_name']}** {bar(b['current_hp'], b['max_hp'])} "
            f"{thousands(b['current_hp'])}/{thousands(b['max_hp'])}"
            if b["current_hp"] > 0 else
            f"{DOT} ~~{b['discord_name']}~~ \N{SKULL} down"
            for b in bodies
        ) or "nobody",
        inline=False,
    )

    if said:
        card.add_field(name="\N{COMPASS} Just now",
                       value=said[:1024], inline=False)

    card.add_field(
        name="What is out there",
        value=(
            f"\N{BLACK LARGE SQUARE} unwalked  "
            f"\N{WHITE LARGE SQUARE} taken  "
            f"\N{LARGE BLUE SQUARE} open  "
            f"\N{DIAMOND SHAPE WITH A DOT INSIDE} cache  "
            f"\N{FIRE} beast  "
            f"\N{JAPANESE OGRE} warden  "
            f"\N{DRAGON} the Trial\n"
            f"*{mp['caches_left']} cache"
            f"{'' if mp['caches_left'] == 1 else 's'} still out there "
            f"somewhere, "
            f"{mp['caches']} already taken.*"
        ),
        inline=False,
    )
    return card


# What covers each threat, said the way a player can act on it. The screen
# told you what was coming and never what to do about it, which made the
# telegraph decoration unless you had the threat table memorised.
COVERS = {
    "pull": ("\N{SHIELD}", "a pull",
             "somebody has to make it look at them"),
    "harden": ("\N{BRICK}", "a hardening",
               "somebody has to raise a ward or a block"),
    "mend": ("\N{HERB}", "a mend",
             "somebody has to put a regen up before it lands"),
    "strike": ("\N{CROSSED SWORDS}", "a real blow",
               "take a true bite out of it this round"),
    "none": ("\N{DASH SYMBOL}", "nothing",
             "there is nothing to answer. Hit it."),
}


def health_line(current: int, maximum: int) -> str:
    share = (current / maximum * 100) if maximum else 0
    return f"{bar(current, maximum)} `{share:5.1f}%` {thousands(current)}"


def render_fighting(mp: dict, run: dict, raiders: list[dict],
                    said: str | None = None) -> discord.Embed:
    standing = [r for r in raiders if r["current_hp"] > 0]
    waiting = [r for r in standing if not r["intent"] and not r["looting"]]
    glyph, what, how = COVERS.get(
        run["answers_with"] or "none", COVERS["none"])

    card = embed(
        f"\N{CROSSED SWORDS} {run['beast_name']}",
        f"**{run['tile_label'] or 'the Trial'}** {DOT} "
        f"round {run['round_no']} of {run['round_cap']}"
        + (f" {DOT} \N{HIGH VOLTAGE SIGN} **{run['stacks']} stack"
           f"{'' if run['stacks'] == 1 else 's'}** on it"
           if run["stacks"] else ""),
        colour=COLOUR_BAD if run["boss_hp"] > run["boss_max_hp"] * 0.25
        else COLOUR_GOOD,
    )

    card.add_field(
        name="\N{DRAGON} It carries",
        value=health_line(run["boss_hp"], run["boss_max_hp"]),
        inline=False,
    )

    if run["threat_name"]:
        card.add_field(
            name=f"\N{WARNING SIGN} {run['threat_name']}",
            value=f"*{run['telegraph']}*\n\n"
                  f"{glyph} **Answer with {what}** {DOT} {how}",
            inline=False,
        )

    lines = []
    for r in raiders:
        if r["current_hp"] <= 0:
            lines.append(f"\N{SKULL} ~~{r['discord_name']}~~")
            continue
        if r["looting"]:
            doing = "\N{PURSE} *looting the place*"
        elif r["intent"]:
            doing = f"\N{WHITE HEAVY CHECK MARK} *{r['intent']}*"
        else:
            doing = "\N{HOURGLASS WITH FLOWING SAND} *still choosing*"
        lines.append(
            f"**{r['discord_name']}**\n"
            f"{health_line(r['current_hp'], r['max_hp'])} {DOT} {doing}"
        )

    card.add_field(
        name=f"\N{BUSTS IN SILHOUETTE} The party "
             f"({len(standing)} of {len(raiders)} standing)",
        value="\n".join(lines) or "nobody",
        inline=False,
    )

    if said:
        card.add_field(name="\N{CROSSED SWORDS} Just now",
                       value=said[:1024], inline=False)

    card.set_footer(
        text=(f"waiting on {len(waiting)}"
              if waiting else "everybody has chosen \N{EM DASH} the leader calls it")
    )
    return card


# ---------------------------------------------------------------------------
# Walking
# ---------------------------------------------------------------------------


class EnterButton(discord.ui.Button):
    def __init__(self, screen: "TrialView") -> None:
        self.screen = screen
        super().__init__(label="Walk in", emoji="\N{COMPASS}",
                         style=discord.ButtonStyle.success, row=0)

    async def callback(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        try:
            await db.fetch_value(
                "SELECT trial_map_open(%s)", (player["player_id"],)
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc
        await self.screen.reload()
        await interaction.response.edit_message(
            embed=await self.screen.card(), view=self.screen
        )


class MoveButton(discord.ui.Button):
    def __init__(self, screen: "TrialView", way: str, glyph: str, row: int,
                 allowed: bool) -> None:
        self.screen = screen
        self.way = way
        super().__init__(
            emoji=glyph,
            style=discord.ButtonStyle.primary if allowed
            else discord.ButtonStyle.secondary,
            disabled=not allowed, row=row,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        try:
            step = await db.fetch_one(
                "SELECT * FROM trial_map_move(%s, %s)",
                (player["player_id"], self.way),
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        self.screen.said = step["said"] or None
        await self.screen.reload()
        await interaction.response.edit_message(
            embed=await self.screen.card(), view=self.screen
        )


# ---------------------------------------------------------------------------
# Fighting
# ---------------------------------------------------------------------------


class MoveSelect(discord.ui.Select):
    def __init__(self, screen: "TrialView", moves: list[dict],
                 chosen: str | None, coming: str | None) -> None:
        self.screen = screen

        def describe(m: dict) -> tuple[str, str]:
            """The glyph and the line under a technique.

            A technique that answers THIS threat is worth saying so about; one
            that answers some other threat is worth distinguishing from one
            that answers nothing, because next round it may be the one.
            """
            covers = m["covers"] or []
            if coming and coming in covers:
                return ("\N{SPARKLES}", f"answers what is coming {DOT} "
                                        f"{m['path_name']}")
            if covers:
                return ("\N{SHIELD}", f"answers {'/'.join(covers)} {DOT} "
                                      f"{m['path_name']}")
            return ("\N{CROSSED SWORDS}", m["path_name"])

        options = []
        for m in moves:
            glyph, note = describe(m)
            options.append(discord.SelectOption(
                label=m["name"][:100],
                value=str(m["technique_id"]),
                description=note[:100],
                emoji=glyph,
                default=chosen == m["name"],
            ))

        # The ones that cover what is actually coming float to the top, so the
        # telegraph and the menu agree about what matters this round; then the
        # ones that answer something else, because next round they may be it.
        rank = {"\N{SPARKLES}": 0, "\N{SHIELD}": 1}
        options.sort(key=lambda o: (rank.get(str(o.emoji), 2), o.label))

        super().__init__(
            placeholder="What do you throw?",
            options=options
            or [discord.SelectOption(label="nothing to throw", value="0")],
            row=0,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        if self.values[0] == "0":
            raise GameError("You have not learned a technique to throw.")
        try:
            await db.execute(
                "SELECT trial_choose(%s, %s)",
                (player["player_id"], int(self.values[0])),
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        await self.screen.settle_if_ready()
        await self.screen.reload()
        await interaction.response.edit_message(
            embed=await self.screen.card(), view=self.screen
        )


class ResolveButton(discord.ui.Button):
    def __init__(self, screen: "TrialView", waiting: int) -> None:
        self.screen = screen
        super().__init__(
            label="Go now" if waiting else "Go",
            emoji="\N{CROSSED SWORDS}",
            style=discord.ButtonStyle.danger,
            row=1,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        if self.screen.map["leader_id"] != player["player_id"]:
            raise GameError("The one leading calls the round.")
        await self.screen.resolve()
        await self.screen.reload()
        await interaction.response.edit_message(
            embed=await self.screen.card(), view=self.screen
        )


class LootButton(discord.ui.Button):
    """Spend the round turning the place over instead of fighting.

    The cost is the round. The creature is sized off what the party deals
    while attacking, so a looted round is a round the health bar does not
    move and one more roll on the threat table.
    """

    def __init__(self, screen: "TrialView", left: int) -> None:
        self.screen = screen
        super().__init__(
            label=f"Loot ({left} left)" if left else "Nothing left here",
            emoji="\N{PURSE}",
            style=discord.ButtonStyle.success if left
            else discord.ButtonStyle.secondary,
            disabled=left <= 0,
            row=1,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        try:
            took = await db.fetch_one(
                "SELECT * FROM trial_loot(%s)", (player["player_id"],)
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        self.screen.said = (
            f"\N{PURSE} **{interaction.user.display_name}** starts going "
            "through the place and will deal nothing this round "
            f"\N{EM DASH} {took['left_to_take'] - 1} more after this one."
        )
        await self.screen.reload()
        await interaction.response.edit_message(
            embed=await self.screen.card(), view=self.screen
        )


class RefreshButton(discord.ui.Button):
    """Redraw. Icon only since 0464, because the row now has to hold Loot."""

    def __init__(self, screen: "TrialView", row: int = 1) -> None:
        self.screen = screen
        super().__init__(emoji="\N{ANTICLOCKWISE DOWNWARDS AND UPWARDS OPEN CIRCLE ARROWS}",
                         style=discord.ButtonStyle.secondary, row=row)

    async def callback(self, interaction: discord.Interaction) -> None:
        await require_player(interaction.user)
        await self.screen.settle_if_ready()
        await self.screen.reload()
        await interaction.response.edit_message(
            embed=await self.screen.card(), view=self.screen
        )


# ---------------------------------------------------------------------------


class TrialView(AnsweringView):
    def __init__(self, player_id: int, mp: dict | None) -> None:
        super().__init__(timeout=1800)
        self.player_id = player_id
        self.map = mp
        self.run: dict | None = None
        self.raiders: list[dict] = []
        self.bodies: list[dict] = []
        self.moves: list[dict] = []
        # What the last action did. Shown IN the card rather than posted as
        # its own message, so a thirteen-step map is one message and not
        # fourteen.
        self.said: str | None = None

    async def reload(self) -> None:
        self.map = await fetch_map(self.player_id)
        self.run = None
        self.raiders = []
        self.bodies = []
        if self.map is not None:
            if self.map["status"] == "fighting":
                self.run = await fetch_run(self.map["map_id"])
                if self.run is not None:
                    self.raiders = await fetch_raiders(self.run["run_id"])
                self.moves = await fetch_moves(self.player_id)
            else:
                self.bodies = await fetch_bodies(self.map["map_id"])
        self.build()

    async def resolve(self) -> None:
        """One round, then read it back onto the map."""
        if self.run is None:
            return
        got = await db.fetch_one(
            "SELECT * FROM trial_resolve_round(%s)", (self.run["run_id"],)
        )
        if got is not None:
            self.said = got["said"]
        await self.settle_if_ready()

    async def settle_if_ready(self) -> None:
        """Hand a finished fight back to the map.

        Called from everywhere a screen is rebuilt rather than only from the
        round that ended it, because the peer who presses next is rarely the
        one who landed the last blow.
        """
        if self.map is None or self.map["status"] != "fighting":
            return
        await db.fetch_one(
            "SELECT * FROM trial_map_settle(%s)", (self.map["map_id"],)
        )

    async def card(self) -> discord.Embed:
        if self.map is None:
            return await self.done_card()
        if self.map["status"] == "fighting" and self.run is not None:
            return render_fighting(self.map, self.run, self.raiders, self.said)
        return render_walking(self.map, self.bodies, self.said)

    async def done_card(self) -> discord.Embed:
        last = await db.fetch_one(
            """
            SELECT m.outcome, m.caches, m.steps_left
            FROM trial_maps m
            JOIN trial_party_members mem ON mem.party_id = m.party_id
            WHERE mem.player_id = %s
            ORDER BY m.map_id DESC LIMIT 1
            """,
            (self.player_id,),
        )
        if last is None or last["outcome"] is None:
            return embed("\N{COMPASS} No trial",
                         "Seal a party with `/party` first.", colour=COLOUR_INFO)
        colour, title = OUTCOMES.get(
            last["outcome"], (COLOUR_INFO, "It is over"))
        return embed(
            title,
            f"{last['caches']} cache{'' if last['caches'] == 1 else 's'} taken, "
            f"{last['steps_left']} step"
            f"{'' if last['steps_left'] == 1 else 's'} of light left over.",
            colour=colour,
        )

    def build(self) -> None:
        self.clear_items()
        if self.map is None:
            return
        is_leader = self.map["leader_id"] == self.player_id

        if self.map["status"] == "fighting" and self.run is not None:
            mine = next((r for r in self.raiders
                         if r["player_id"] == self.player_id), None)
            standing = mine is not None and mine["current_hp"] > 0
            if standing:
                self.add_item(MoveSelect(
                    self, self.moves, mine["intent"],
                    self.run["answers_with"]))
                self.add_item(LootButton(
                    self,
                    self.run["loot_limit"] - (mine["loots_taken"] or 0)))
            waiting = sum(
                1 for r in self.raiders
                if r["current_hp"] > 0 and not r["intent"] and not r["looting"]
            )
            if is_leader:
                self.add_item(ResolveButton(self, waiting))
            self.add_item(RefreshButton(self))
            return

        mine = self.map["mover_id"] == self.player_id
        for way, glyph, row in WAYS:
            self.add_item(MoveButton(self, way, glyph, row, mine))
        self.add_item(RefreshButton(self, row=3))


class Trial(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @app_commands.command(
        description="Walk your sealed party into its Peer Trial."
    )
    async def trial(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])

        party = await db.fetch_one(
            """
            SELECT p.party_id, p.status, p.leader_id
            FROM trial_parties p
            WHERE p.party_id = trial_party_of(%s)
            """,
            (player["player_id"],),
        )
        if party is None:
            raise GameError(
                "You are not in a party. `/party` opens one and asks peers in."
            )
        if party["status"] != "sealed":
            raise GameError(
                "The party has not set out yet \N{EM DASH} the one leading "
                "seals it from `/party`."
            )

        view = TrialView(player["player_id"], None)
        await view.reload()

        # A sealed party with no map yet: the leader is the one who can lay it.
        if view.map is None:
            if party["leader_id"] != player["player_id"]:
                raise GameError(
                    "The one leading has not walked the party in yet."
                )
            card = embed(
                "\N{COMPASS} The ground ahead",
                "Your party is sealed. Walking in lays out the map \N{EM DASH} "
                "caches, beasts, and the thing you came for.",
                colour=COLOUR_INFO,
            )
            view.clear_items()
            view.add_item(EnterButton(view))
            await interaction.response.send_message(embed=card, view=view)
            return

        await interaction.response.send_message(
            embed=await view.card(), view=view
        )


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Trial(bot))
