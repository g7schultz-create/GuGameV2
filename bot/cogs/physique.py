"""The body: /physique.

Cultivation is a ladder you climb; the body is a ladder you choose how to
climb. The rank says where you have got to and the path says what you were
building on the way, and the two together are the only reason "body level 7"
was ever worth naming.

The choice is the screen's real content, so the trade each path makes is
spelled out in the numbers it will actually move rather than in an adjective.
Nothing here decides whether the choice is still open — `player_body` answers
that with the same rule the trigger enforces, so the screen can never offer a
button the database will refuse.
"""

import discord
import psycopg
from discord import app_commands
from discord.ext import commands

from bot import database as db
from bot.character import RARITY_MARK
from bot.formatting import (
    COLOUR_DEFAULT,
    COLOUR_GOOD,
    COLOUR_INFO,
    bar,
    embed,
    percent,
    thousands,
)
from bot.views import AnsweringView
from bot.players import GameError, require_player, settle_passive

HEART = "\N{HEAVY BLACK HEART}"
SHIELD = "\N{SHIELD}"
MUSCLE = "\N{FLEXED BICEPS}"


async def fetch_body(player_id: int) -> dict | None:
    return await db.fetch_one(
        "SELECT * FROM player_body WHERE player_id = %s", (player_id,)
    )


async def fetch_paths() -> list[dict]:
    return await db.fetch_all(
        "SELECT * FROM body_paths ORDER BY sort_order"
    )


async def fetch_gift(player_id: int) -> dict | None:
    """What the body you were born with is called, and what it still owes.

    `player_body` does not carry these: that view is about the body you have
    built, and this is about the one you were given.
    """
    return await db.fetch_one(
        """
        SELECT p.special_name, p.special_text, p.unmodelled
        FROM player_physique pp
        JOIN physiques p ON p.physique_id = pp.physique_id
        WHERE pp.player_id = %s
        """,
        (player_id,),
    )


async def fetch_gift_effects(player_id: int) -> list[dict]:
    """Everything the physique grants, in one query and one ordering.

    Effects and Path resistances live in different tables and are the same
    sentence to a player — this is what being born in this body is worth — so
    they come back together rather than as two fields that would have to be
    read in order to be compared.
    """
    return await db.fetch_all(
        """
        -- Capped here because `physique_stat` caps it too: a body may be
        -- written down as worth more than an effect's ceiling, and showing the
        -- stored number would be showing a figure the game never uses.
        SELECT ef.emoji, ef.name,
               LEAST(ef.cap, pe.magnitude) AS magnitude, FALSE AS is_resistance,
               -- In the effect's own units. `is_base` lives on the effect, so
               -- the rendering does too - three bodies grant Body in POINTS
               -- and this screen called 29.7 of them a 2970 per cent bonus.
               effect_amount(ef.code, LEAST(ef.cap, pe.magnitude)) AS amount
        FROM player_physique pp
        JOIN physique_effects pe ON pe.physique_id = pp.physique_id
        JOIN gu_effects ef ON ef.code = pe.effect_code
        WHERE pp.player_id = %s

        UNION ALL

        -- A resistance is always a fraction, so it renders as one.
        SELECT pa.emoji, pa.name, b.resistance, TRUE,
               round(100 * b.resistance)::text || '%%'
        FROM player_physique pp
        JOIN physique_path_bonuses b ON b.physique_id = pp.physique_id
        JOIN paths pa ON pa.code = b.path_code
        WHERE pp.player_id = %s AND b.resistance > 0

        ORDER BY 3 DESC
        """,
        (player_id, player_id),
    )


def trade_line(path: dict) -> str:
    """What a path costs, in the three numbers it moves."""
    return "  \N{BULLET}  ".join(
        f"{icon} {percent(path[key])}"
        for icon, key in (
            (HEART, "hp_bonus"),
            (SHIELD, "defense_bonus"),
            (MUSCLE, "strength_bonus"),
        )
    )


def gift_lines(rows: list[dict]) -> str:
    """What the body grants, one line each.

    A resistance reads as what it spares you rather than as a number against a
    Path, because "18% less from Fire" is the sentence a player can act on and
    "Fire resistance 18%" is the sentence they have to translate first.
    """
    return "\n".join(
        f"{r['emoji']} **{r['amount']}** less from "
        f"{r['name']}"
        if r["is_resistance"]
        else f"{r['emoji']} **{r['amount']}** {r['name']}"
        for r in rows
    )


async def render_body(
    body: dict, display_name: str, player_id: int
) -> discord.Embed:
    # Fetched here rather than passed in: `player_body` carries the player_id,
    # both callers already have the row, and threading two more arguments
    # through them would be two more chances for one caller to forget.
    gift = await fetch_gift(body["player_id"])
    grants = await fetch_gift_effects(body["player_id"])

    if body["rank_name"]:
        title = f"{body['path_emoji']} {body['rank_name']}"
        subtitle = (
            f"**{body['path_name']}** \N{BULLET} {body['temperament']} "
            f"\N{BULLET} body level {body['body_level']}"
        )
    else:
        title = f"\N{FLEXED BICEPS} Rank {body['body_rank']}"
        subtitle = (
            f"{display_name} has not chosen a body "
            f"\N{BULLET} body level {body['body_level']}"
        )

    card = embed(title, subtitle, colour=COLOUR_DEFAULT)

    if body["next_floor"] is not None:
        span = body["next_floor"] - body["rank_floor"]
        into = body["physique_xp"] - body["rank_floor"]
        ahead = body["next_rank_name"] or f"Rank {body['body_rank'] + 1}"

        # Capped at the door. Since 0108 the training keeps going while the
        # rank waits, so this bar could read 209% - which looks like a bug
        # rather than like "you are ready and have been for a while".
        filled = min(into, span)
        lines = [
            f"{bar(filled, span, width=18)}  "
            f"{percent(filled / span if span else 1, signed=False)}",
            f"{thousands(min(into, span))} / {thousands(span)} toward **{ahead}**",
        ]

        # A door nobody is told about is a wall. The crossing costs beast
        # material now, so the screen says whether you have it.
        cost = await db.fetch_one(
            """
            SELECT body_rank_cost((pp.body_rank + 1)::smallint) AS wants,
                   player_beast_weight(pp.player_id) AS carries,
                   ready_to_temper(pp.player_id) AS ready
            FROM player_physique pp WHERE pp.player_id = %s
            """,
            (player_id,),
        )
        if cost["ready"]:
            lines.append(
                f"\N{WHITE HEAVY CHECK MARK} **Ready.** "
                f"**/temper** crosses into {ahead} for "
                f"{thousands(cost['wants'])} weight of beast material."
            )
        elif into >= span:
            lines.append(
                f"\N{CROSSED SWORDS} The training is done. The crossing wants "
                f"**{thousands(cost['wants'])}** weight of beast material and "
                f"you carry **{thousands(cost['carries'])}** \N{EM DASH} **/hunt**, "
                "then **/temper**."
            )
        else:
            lines.append(
                f"*Then **/temper**, which also wants "
                f"{thousands(cost['wants'])} weight of beast material.*"
            )

        card.add_field(name="Tempering", value="\n".join(lines), inline=False)
    else:
        # The top rung stopped being a wall in 0383. Nothing is held back
        # here any more and every level still pays, so the screen has to say
        # so - "there is no further body to build" would now be telling the
        # people who got furthest that the only thing left to do is worth
        # nothing.
        over = await db.fetch_one(
            """
            SELECT body_rank_progress(pp.player_id)
                       - (pp.body_rank - 1) AS through,
                   game_config_value('body_overflow_weight') AS weight
            FROM player_physique pp WHERE pp.player_id = %s
            """,
            (player_id,),
        )
        through = float(over["through"])
        lines = [
            f"{bar(min(through, 1.0), 1.0, width=18)}  "
            f"{percent(through, signed=False)} of the last rung",
            "The top of the ladder \N{EM DASH} nothing holds your levels "
            "back now.",
        ]
        if through > 1:
            lines.append(
                f"Past the end of it every **doubling** of what you have "
                f"trained is worth another "
                f"{percent(float(over['weight']), signed=False)} of a rank, "
                f"so tempering never stops counting."
            )
        else:
            lines.append(
                "Train past the end of this band and it keeps paying \N{EM DASH} "
                "more slowly the further you go, and never nothing."
            )
        card.add_field(name="Tempering", value="\n".join(lines), inline=False)

    card.add_field(
        name="The body",
        value=(
            f"{HEART} **{thousands(body['max_hp'])}** HP  \N{BULLET}  "
            f"{SHIELD} **{thousands(body['defense'])}** defence  \N{BULLET}  "
            f"{MUSCLE} **{thousands(body['strength'])}** strength\n"
            f"Regenerating {body['regeneration']} HP a minute."
        ),
        inline=False,
    )

    if body["physique_name"]:
        lines = [
            f"{RARITY_MARK.get(body['physique_rarity'], '')} "
            f"**{body['physique_name']}** \N{BULLET} "
            f"{HEART} {percent(body['hp_multiplier'] - 1)}  "
            f"{SHIELD} {percent(body['defense_multiplier'] - 1)}  "
            f"{MUSCLE} {percent(body['strength_multiplier'] - 1)}"
        ]
        if gift and gift["special_name"]:
            lines.append(f"***{gift['special_name']}*** — *{gift['special_text']}*")
        if grants:
            lines.append(gift_lines(grants))
        card.add_field(name="Born with", value="\n".join(lines), inline=False)

    if body["body_path"]:
        card.add_field(
            name=f"{body['path_emoji']} {body['path_name']}",
            value=f"*{body['path_description']}*\n{trade_line(body)}",
            inline=False,
        )

    if body["path_still_open"]:
        if body["body_path"] is None and body["body_rank"] > 1:
            card.set_footer(
                text="Your body is past Rank 1 — whichever path you choose now "
                "is the one you keep."
            )
        else:
            card.set_footer(
                text="A body sets at Rank 2. Until then you may change your mind."
            )
    else:
        card.set_footer(text="This body has set. It is what you are now.")

    return card


class PathButton(discord.ui.Button):
    def __init__(self, screen: "BodyView", path: dict) -> None:
        self.screen = screen
        self.path = path
        super().__init__(
            label=f"{path['name']} — {path['temperament']}"[:80],
            emoji=path["emoji"][:1] if path["emoji"] else None,
            style=(
                discord.ButtonStyle.success
                if screen.body["body_path"] == path["code"]
                else discord.ButtonStyle.secondary
            ),
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        try:
            await db.execute(
                "UPDATE player_physique SET body_path = %s WHERE player_id = %s",
                (self.path["code"], self.screen.player_id),
            )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0].capitalize()) from exc

        # Every stat is a function of the path, so the body is re-derived the
        # same way /gu re-derives it: grant nothing and let it recompute.
        await db.execute("SELECT apply_physique_xp(%s, 0)", (self.screen.player_id,))

        self.screen.body = await fetch_body(self.screen.player_id)
        self.screen.build()
        await interaction.response.edit_message(
            embed=await render_body(
                self.screen.body, self.screen.user.display_name,
                self.screen.player_id,
            ),
            view=self.screen,
        )


class BodyView(AnsweringView):
    def __init__(
        self, player_id: int, user: discord.abc.User, body: dict, paths: list[dict]
    ) -> None:
        super().__init__(timeout=300)
        self.player_id = player_id
        self.user = user
        self.body = body
        self.paths = paths
        self.build()

    def build(self) -> None:
        self.clear_items()
        if not self.body["path_still_open"]:
            return
        for path in self.paths:
            self.add_item(PathButton(self, path))

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message("Not your body.", ephemeral=True)
            return False
        return True

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True

    async def on_error(
        self, interaction: discord.Interaction, error: Exception, item
    ) -> None:
        if not isinstance(error, GameError):
            await super().on_error(interaction, error, item)
            return
        from bot.formatting import error_embed

        if interaction.response.is_done():
            await interaction.followup.send(embed=error_embed(str(error)), ephemeral=True)
        else:
            await interaction.response.send_message(
                embed=error_embed(str(error)), ephemeral=True
            )


# ---------------------------------------------------------------------------
# Tempering
# ---------------------------------------------------------------------------
# A rank is crossed rather than drifted into, and the crossing is paid for in
# what you killed. Two gates: the training, and the material. The screen shows
# both whether or not either is met, because "what am I short of" is the only
# question worth answering here.


async def fetch_crossing(player_id: int) -> dict:
    return await db.fetch_one(
        """
        SELECT pp.body_rank, pp.body_level, pp.physique_xp,
               body_level_ceiling(pp.body_rank) AS ceiling,
               nxt.rank AS next_rank, nxt.xp_required,
               cur.xp_required AS rank_floor,
               body_rank_cost(nxt.rank) AS cost,
               player_beast_weight(%s) AS carries,
               ready_to_temper(%s) AS ready,
               mine.name AS rank_name, ahead.name AS next_name
        FROM player_physique pp
        JOIN body_rank_requirements cur ON cur.rank = pp.body_rank
        LEFT JOIN body_rank_requirements nxt ON nxt.rank = pp.body_rank + 1
        LEFT JOIN body_ranks mine
               ON mine.path_code = pp.body_path AND mine.rank = pp.body_rank
        LEFT JOIN body_ranks ahead
               ON ahead.path_code = pp.body_path AND ahead.rank = pp.body_rank + 1
        WHERE pp.player_id = %s
        """,
        (player_id, player_id, player_id),
    )


async def fetch_offering(player_id: int, cost: int) -> list[dict]:
    """What the crossing would actually take, commonest first.

    The same order `temper_body` spends in, so the screen is a promise rather
    than an estimate - a player must never press a button and watch it eat the
    dragon scale it did not mention.
    """
    return await db.fetch_all(
        """
        WITH held AS (
            SELECT pm.material_code, pm.quantity,
                   material_grade(m.rarity) AS grade,
                   material_name(pm.material_code) AS name,
                   m.rarity, m.emoji
            FROM player_materials pm
            JOIN beast_parts bp ON bp.material_code = pm.material_code
            JOIN materials m ON m.code = pm.material_code
            WHERE pm.player_id = %s AND pm.quantity > 0
        ),
        running AS (
            SELECT h.*,
                   COALESCE(sum(h.quantity * h.grade) OVER (
                       ORDER BY h.grade, h.material_code
                       ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS before
            FROM held h
        )
        SELECT r.name, r.emoji, r.rarity, r.grade, r.quantity,
               LEAST(r.quantity,
                     ceil((%s - r.before)::numeric / r.grade))::bigint AS takes
        FROM running r
        WHERE r.before < %s
        ORDER BY r.grade, r.material_code
        """,
        (player_id, cost, cost),
    )


async def render_crossing(player_id: int, display_name: str) -> discord.Embed:
    row = await fetch_crossing(player_id)

    if row["next_rank"] is None:
        return embed(
            "\N{SNOW CAPPED MOUNTAIN} The top of the body",
            f"**{row['rank_name'] or 'Your body'}** is the last rank. There is "
            "nothing above it to cross into \N{EM DASH} but the levels you temper "
            "past it are no longer held back, and every one of them still "
            "pays. **/physique** shows how far past the end you have got.",
            colour=COLOUR_INFO,
        )

    into = row["physique_xp"] - row["rank_floor"]
    span = row["xp_required"] - row["rank_floor"]
    trained = row["physique_xp"] >= row["xp_required"]

    card = embed(
        f"\N{SNOW CAPPED MOUNTAIN} {display_name} tempers the body",
        f"**{row['rank_name'] or 'Rank ' + str(row['body_rank'])}** "
        f"\N{RIGHTWARDS ARROW} **{row['next_name'] or 'rank ' + str(row['next_rank'])}**",
        colour=COLOUR_GOOD if row["ready"] else COLOUR_DEFAULT,
    )
    card.add_field(
        name="Tempering",
        value=f"{bar(min(into, span), span, width=18)}  "
        f"{percent(min(into, span) / span if span else 1, signed=False)}\n"
        f"{thousands(into)} / {thousands(span)}"
        + ("  \N{WHITE HEAVY CHECK MARK}" if trained else ""),
        inline=False,
    )
    card.add_field(
        name="Beast material",
        value=f"**{thousands(row['carries'])}** of "
        f"**{thousands(row['cost'])}** weight"
        + ("  \N{WHITE HEAVY CHECK MARK}" if row["carries"] >= row["cost"] else "")
        + "\n*Weight is grade \N{MULTIPLICATION SIGN} quantity \N{EM DASH} a "
        "mythic fang is worth six common ones.*",
        inline=False,
    )

    if row["ready"]:
        offering = await fetch_offering(player_id, row["cost"])
        card.add_field(
            name="What it will take",
            value="\n".join(
                f"{o['emoji']} **{o['name']}** \N{MULTIPLICATION SIGN}{o['takes']} "
                f"\N{BULLET} {o['rarity']}"
                for o in offering[:12]
            )
            + "\n*Commonest first \N{EM DASH} what the forge wants is left alone.*",
            inline=False,
        )
        card.add_field(
            name="What it is worth",
            value=f"The ceiling on your body rises from level "
            f"**{row['ceiling']}**, and every level you have already trained "
            "past it arrives at once.",
            inline=False,
        )
    else:
        short = []
        if not trained:
            short.append(
                f"**{thousands(row['xp_required'] - row['physique_xp'])}** more "
                "physique XP \N{EM DASH} it accrues while you are away"
            )
        if row["carries"] < row["cost"]:
            short.append(
                f"**{thousands(row['cost'] - row['carries'])}** more weight of "
                "beast material \N{EM DASH} **/hunt**"
            )
        card.add_field(name="Short of", value="\n".join(short), inline=False)

    card.set_footer(
        text="A body stops at the rank it has crossed. The training is never "
        "lost - it waits behind the door."
    )
    return card


class TemperView(AnsweringView):
    def __init__(self, player_id: int, user: discord.abc.User) -> None:
        super().__init__(timeout=180)
        self.player_id = player_id
        self.user = user

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "Not your body.", ephemeral=True
            )
            return False
        return True

    @discord.ui.button(label="Temper", style=discord.ButtonStyle.success)
    async def go(self, interaction: discord.Interaction, button) -> None:
        try:
            done = await db.fetch_one(
                "SELECT * FROM temper_body(%s)", (self.player_id,)
            )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0].capitalize()) from exc

        card = embed(
            f"\N{SNOW CAPPED MOUNTAIN} {done['name_after'] or 'Rank ' + str(done['rank_after'])}",
            f"The body crosses out of **{done['name_before']}**.",
            colour=COLOUR_GOOD,
        )
        card.add_field(
            name="What it bought",
            value=f"Body level **{done['level_before']}** \N{RIGHTWARDS ARROW} "
            f"**{done['level_after']}**\n"
            f"\N{HEAVY BLACK HEART} **+{thousands(done['hp_gained'])}** maximum HP",
            inline=False,
        )
        card.add_field(
            name="What it cost",
            value=", ".join(
                f"{item['name']} \N{MULTIPLICATION SIGN}{item['quantity']}"
                for item in done["spent"]
            )
            + f"\n*{thousands(done['weight_spent'])} weight in all.*",
            inline=False,
        )
        card.set_footer(text="/physique to see what the body became.")

        for item in self.children:
            item.disabled = True
        await interaction.response.edit_message(embed=card, view=self)
        self.stop()


class Physique(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @app_commands.command(description="Your body: what it is, and what you are building it into.")
    async def physique(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])

        body = await fetch_body(player["player_id"])
        if body is None:
            raise GameError("You have no body yet. **/register** first.")

        view = BodyView(
            player["player_id"], interaction.user, body, await fetch_paths()
        )
        # MISSING, not None. discord.py treats None as a view it was handed
        # and calls `is_finished()` on it; MISSING is the sentinel that means
        # "no view". A body whose Path has set has no buttons, so this line is
        # reached by exactly the characters furthest along.
        await interaction.response.send_message(
            embed=await render_body(
                body, interaction.user.display_name, player["player_id"]
            ),
            view=view if view.children else discord.utils.MISSING,
        )

    # -----------------------------------------------------------------------

    @app_commands.command(
        description="Cross into the next body rank, paid for in beast material."
    )
    async def temper(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])

        card = await render_crossing(
            player["player_id"], interaction.user.display_name
        )
        ready = await db.fetch_value(
            "SELECT ready_to_temper(%s)", (player["player_id"],)
        )
        await interaction.response.send_message(
            embed=card,
            view=TemperView(player["player_id"], interaction.user)
            if ready
            else discord.utils.MISSING,
        )

    # -----------------------------------------------------------------------

    @app_commands.command(description="The three bodies, and what each one costs.")
    async def bodies(self, interaction: discord.Interaction) -> None:
        card = embed(
            "\N{FLEXED BICEPS} The three bodies",
            "Eighteen ranks each, one for every realm. The climb is the same; "
            "what you become on the way is not.",
            colour=COLOUR_GOOD,
        )
        for path in await fetch_paths():
            ladder = await db.fetch_all(
                "SELECT rank, name FROM body_ranks WHERE path_code = %s ORDER BY rank",
                (path["code"],),
            )
            card.add_field(
                name=f"{path['emoji']} {path['name']} — {path['temperament']}",
                value=(
                    f"*{path['description']}*\n{trade_line(path)}\n"
                    + "\n".join(f"`{r['rank']}` {r['name']}" for r in ladder)
                ),
                inline=False,
            )
        card.set_footer(
            text="A body sets at Rank 2. /physique to choose, and to see how far along yours is."
        )
        await interaction.response.send_message(embed=card)


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Physique(bot))
