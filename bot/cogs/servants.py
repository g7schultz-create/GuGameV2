"""Servants: /servants and /summon.

A servant is somebody who goes and picks what you no longer can. A cultivator
past the mortal realms cannot walk back into a Northern Plains meadow for
Centipede Venom, and 344 Gu recipes still want it - so the recipes closed
behind them. The roster is the answer to that, and everything else about it
follows from being a supply line first.

Three things a servant is at once, and they pull in different directions on
purpose:

  * ONE attends you, and only one. Their passive is felt in every fight. The
    table that records it is keyed on the player, so "only one" is a fact
    about the schema rather than a rule anybody has to keep.
  * SEVERAL work, up to `servant_farm_slots`, which grows with your realm.
    That is what makes a wide collection worth having.
  * ALL of them count toward the collection bonus, which pays into farming
    rather than into stats - a hundred servants must not quietly beat the one
    you chose to attend you.

Duplicates are not a consolation prize. A spare is what a star costs, and a
star raises both the passive and the haul.
"""

import discord
from discord import app_commands
from discord.ext import commands

import psycopg

from bot import database as db
from bot.character import RARITY_MARK
from bot.formatting import (
    COLOUR_BAD,
    COLOUR_GOOD,
    COLOUR_INFO,
    embed,
    percent,
    thousands,
)
from bot.picking import add_page_buttons, page_count, page_note, page_of
from bot.players import GameError, require_player
from bot.views import AnsweringModal, AnsweringView

PER_PAGE = 10
STAR = "\N{WHITE MEDIUM STAR}"
JADE = "\N{LARGE GREEN CIRCLE}"
BASKET = "\N{BASKET}"


def refuse(exc: psycopg.errors.CheckViolation) -> GameError:
    return GameError(str(exc).splitlines()[0].capitalize())


# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------


async def fetch_servants(player_id: int) -> list[dict]:
    """Everybody held, with what each is worth and what raising them takes.

    Ordered the way a collection is read rather than the way it is stored:
    the deepest first, because that is the one being decided about.
    """
    return await db.fetch_all(
        """
        SELECT ps.player_servant_id, ps.servant_code, ps.stars, ps.farming,
               s.name, s.bonus_kind, s.blurb, s.trait_name, s.trait_text,
               s.is_named, t.rarity, ps.ascension,
               -- What this COPY is read at, not what its kind was written
               -- at. Since 0478 five stars buys a tier and it lives on the
               -- row rather than on the template.
               servant_tier_of(ps.player_servant_id) AS tier,
               s.tier AS kind_tier,
               (SELECT max(t2.tier) FROM servant_tiers t2) AS top_tier,
               game_config_value('servant_max_stars')::int AS max_stars,
               b.name AS bonus_name, b.is_flat, b.is_strike,
               r.name AS realm_name, r.rank AS realm_rank,
               ps.cultivation,
               servant_realm_cost(r.realm_id + 1) AS next_realm_costs,
               round(servant_haul_per_hour(ps.player_servant_id), 1) AS per_hour,
               round(servant_immortal_per_hour(ps.player_servant_id), 2)
                   AS immortal_per_hour,
               servant_rarity_reach(r.rank) AS reaches,
               -- What rarer ground pays THIS servant, since 0465. Read off
               -- the same function servant_settle pays by, so the card and
               -- the hour cannot come to disagree.
               (SELECT string_agg(
                    rr.rarity || ' ' || round(
                        servant_haul_per_hour(ps.player_servant_id)
                        * servant_rarity_share(rr.rarity, r.rank), 1),
                    ', ' ORDER BY ra.sort_order)
                FROM servant_rarity_rates rr
                JOIN rarities ra ON ra.code = rr.rarity
                WHERE rr.min_rank <= r.rank AND rr.share < 1) AS rarer_rates,
               game_config_value('servant_immortal_realm')::int AS immortal_realm,
               n.spares, n.copies_needed, n.next_stars,
               (a.player_servant_id IS NOT NULL) AS attending,
               (SELECT string_agg(m.name, ', ' ORDER BY f.slot)
                FROM servant_focus f
                JOIN materials m ON m.code = f.material_code
                WHERE f.player_servant_id = ps.player_servant_id)
                   AS focus_names,
               -- What THIS one grants, read the way `servant_stat` reads it:
               -- Strength takes the flat column because Sinew is points.
               (CASE WHEN b.is_flat   THEN t.flat_bonus
                     WHEN b.is_strike THEN t.strike_bonus
                     ELSE t.pct_bonus END
                * servant_star_scale(ps.stars)) AS grants
        FROM player_servants ps
        JOIN servants s        ON s.servant_code = ps.servant_code
        JOIN servant_tiers t   ON t.tier = servant_tier_of(ps.player_servant_id)
        JOIN servant_bonuses b ON b.kind = s.bonus_kind
        JOIN realms r          ON r.realm_id = ps.realm_id
        JOIN servant_nursery n ON n.player_servant_id = ps.player_servant_id
        LEFT JOIN player_servant_attending a
               ON a.player_servant_id = ps.player_servant_id
        WHERE ps.player_id = %s
        ORDER BY servant_tier_of(ps.player_servant_id) DESC,
                 ps.stars DESC, s.name
        """,
        (player_id,),
    )


def grant_line(row: dict) -> str:
    """What one servant is worth, in the unit that bonus is measured in.

    Sinew is points and the rest are shares, and printing points as a
    percentage is the mistake 0418 had to go back and undo in the data. It
    would read just as wrongly here.
    """
    if row["is_flat"]:
        return f"+{row['grants']:.2f} {row['bonus_name']}"
    return f"{percent(row['grants'])} {row['bonus_name']}"


def servant_line(row: dict) -> str:
    marks = STAR * int(row["stars"])
    where = " \N{BASKET}" if row["farming"] else ""
    lead = "\N{GLOWING STAR} " if row["attending"] else ""
    return (
        f"{lead}{RARITY_MARK.get(row['rarity'], '')} **{row['name']}**{where}\n"
        f"     `T{row['tier']}` {marks} \N{BULLET} {grant_line(row)}"
        f" \N{BULLET} {row['per_hour']}/hr\n"
        f"     *{row['realm_name']}*"
    )


# ---------------------------------------------------------------------------
# The wheel
# ---------------------------------------------------------------------------


class SummonButton(discord.ui.Button):
    def __init__(self, screen: "ServantView", cost: int) -> None:
        self.screen = screen
        super().__init__(
            label=f"Summon ({cost} jade)",
            emoji="\N{CRYSTAL BALL}",
            style=discord.ButtonStyle.primary,
            row=0,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        try:
            got = await db.fetch_one(
                "SELECT * FROM servant_roll(%s)", (player["player_id"],)
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        card = embed(
            f"{RARITY_MARK.get(got['rarity'], '')} {got['name']}",
            f"**{got['rarity'].title()}** \N{BULLET} tier {got['tier']}"
            + ("  \N{SPARKLES} **new**" if got["is_new"]
               else f"  \N{BULLET} you now hold {got['copies_held']}"),
            colour=COLOUR_GOOD if got["tier"] >= 5 else COLOUR_INFO,
        )
        if got["blurb"]:
            card.add_field(name="Who", value=got["blurb"], inline=False)
        if got["trait_name"]:
            card.add_field(name=got["trait_name"], value="​", inline=False)
        card.set_footer(text=f"{got['jade_left']} jade left.")

        await self.screen.reload(player["player_id"])
        await interaction.response.edit_message(
            embed=await self.screen.card(), view=self.screen
        )
        await interaction.followup.send(embed=card)


# ---------------------------------------------------------------------------
# Collecting what they brought
# ---------------------------------------------------------------------------


class CollectButton(discord.ui.Button):
    def __init__(self, screen: "ServantView") -> None:
        self.screen = screen
        super().__init__(
            label="Collect", emoji=BASKET,
            style=discord.ButtonStyle.success, row=0,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        rows = await db.fetch_all(
            "SELECT * FROM servant_settle(%s)", (player["player_id"],)
        )

        if not rows:
            raise GameError(
                "Nobody has a whole hour's work to hand in yet."
            )

        card = embed(
            f"{BASKET} Brought home",
            f"{len(rows)} servant(s) reporting.",
            colour=COLOUR_GOOD,
        )
        for one in rows[:20]:
            card.add_field(
                name=f"{one['servant_name']} \N{BULLET} {int(one['hours'])}h",
                value=one["haul"] or "*nothing*",
                inline=False,
            )

        await self.screen.reload(player["player_id"])
        await interaction.response.edit_message(
            embed=await self.screen.card(), view=self.screen
        )
        await interaction.followup.send(embed=card)


# ---------------------------------------------------------------------------
# Choosing one to act on
# ---------------------------------------------------------------------------


class ServantFindModal(AnsweringModal):
    """Rank and name in one box, because they are one question.

    A collection of a hundred and forty is read by narrowing, not by paging to
    the end of it - and the two things anybody narrows by are "which tier" and
    "who". Both are optional and both clear by being left blank, so there is
    no separate way to undo a search.
    """

    def __init__(self, screen: "ServantView") -> None:
        super().__init__(title="Find a servant")
        self.screen = screen
        self.rank = discord.ui.TextInput(
            label="Rank",
            placeholder="1-7, or a word like mythic. Blank for any.",
            required=False,
            max_length=20,
            default=str(screen.tier) if screen.tier else "",
        )
        self.term = discord.ui.TextInput(
            label="Part of the name",
            placeholder="bai",
            required=False,
            max_length=60,
            default=screen.term,
        )
        self.add_item(self.rank)
        self.add_item(self.term)

    async def on_submit(self, interaction: discord.Interaction) -> None:
        self.screen.term = str(self.term.value).strip()
        self.screen.tier = read_rank(str(self.rank.value))
        # Back to the first page: the page somebody was on belonged to the
        # list they have just replaced.
        self.screen.page = 0
        self.screen.build()
        await interaction.response.edit_message(
            embed=await self.screen.card(), view=self.screen
        )


def read_rank(said: str) -> int | None:
    """A tier from whatever the player typed, or None for "any".

    Takes the number, the rarity word, or the "T6" the card itself prints -
    asking somebody to retype a rank in a different notation than the one they
    are looking at is how a search box gets abandoned.
    """
    said = said.strip().lower().lstrip("t").strip()
    if not said:
        return None
    if said.isdigit() and 1 <= int(said) <= len(RARITIES):
        return int(said)
    for tier, rarity in RARITIES.items():
        if rarity.startswith(said):
            return tier
    return None


# Tier to rarity, so the search box can be told either. Built once from the
# same table the cards read, rather than spelled out twice.
RARITIES: dict[int, str] = {}


class ServantFindButton(discord.ui.Button):
    def __init__(self, screen: "ServantView") -> None:
        self.screen = screen
        live = screen.filter_words()
        super().__init__(
            label=(f"{live} ×" if live
                   else "Find…")[:80],
            emoji=None if live else "🔍",
            style=(discord.ButtonStyle.primary if live
                   else discord.ButtonStyle.secondary),
            row=0,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        # A live search is cleared by pressing it; an empty one opens the box.
        # The same rule the refinery's Find button follows, so the two screens
        # do not answer the same press differently.
        if self.screen.filter_words():
            self.screen.term = ""
            self.screen.tier = None
            self.screen.page = 0
            self.screen.build()
            await interaction.response.edit_message(
                embed=await self.screen.card(), view=self.screen
            )
        else:
            await interaction.response.send_modal(ServantFindModal(self.screen))


class ServantPicker(discord.ui.Select):
    def __init__(self, screen: "ServantView", rows: list[dict]) -> None:
        self.screen = screen
        self.rows = {str(r["player_servant_id"]): r for r in rows}
        super().__init__(
            placeholder="Which servant?",
            row=1,
            options=[
                discord.SelectOption(
                    label=f"{r['name']} {STAR * int(r['stars'])}"[:100],
                    value=str(r["player_servant_id"]),
                    description=(
                        f"T{r['tier']} {r['rarity']} \N{BULLET} "
                        f"{grant_line(r)} \N{BULLET} "
                        + ("out working" if r["farming"] else "at home")
                    )[:100],
                )
                for r in rows
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        self.screen.chosen = self.rows[self.values[0]]
        self.screen.build()
        await interaction.response.edit_message(
            embed=await self.screen.card(), view=self.screen
        )


class AttendButton(discord.ui.Button):
    def __init__(self, screen: "ServantView") -> None:
        self.screen = screen
        super().__init__(
            label="Have them attend you", emoji="\N{GLOWING STAR}",
            style=discord.ButtonStyle.secondary, row=2,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        try:
            said = await db.fetch_value(
                "SELECT servant_attend(%s, %s)",
                (player["player_id"], self.screen.chosen["player_servant_id"]),
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        await self.screen.reload(player["player_id"])
        await interaction.response.edit_message(
            embed=await self.screen.card(), view=self.screen
        )
        await interaction.followup.send(said, ephemeral=True)


class DismissButton(discord.ui.Button):
    """Send an attending servant home.

    With one seat this was not needed - calling somebody new retired the old
    one on its own. With three, a full bench has to be emptied on purpose,
    so the button that used to sit here greyed out does something.
    """

    def __init__(self, screen: "ServantView") -> None:
        self.screen = screen
        super().__init__(
            label="Send them away",
            emoji="\N{GLOWING STAR}",
            style=discord.ButtonStyle.secondary,
            row=2,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        await db.fetch_value(
            "SELECT servant_dismiss(%s, %s)",
            (player["player_id"], self.screen.chosen["player_servant_id"]),
        )
        name = self.screen.chosen["name"]
        await self.screen.reload(player["player_id"])
        await interaction.response.edit_message(
            embed=await self.screen.card(), view=self.screen
        )
        await interaction.followup.send(
            f"**{name}** steps back.", ephemeral=True
        )


class WorkButton(discord.ui.Button):
    def __init__(self, screen: "ServantView", out: bool) -> None:
        self.screen = screen
        self.out = out
        super().__init__(
            label="Send them out" if out else "Call them home",
            emoji=BASKET,
            style=discord.ButtonStyle.primary if out
            else discord.ButtonStyle.secondary,
            row=2,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        try:
            said = await db.fetch_value(
                "SELECT servant_send(%s, %s, %s)",
                (player["player_id"],
                 self.screen.chosen["player_servant_id"], self.out),
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        await self.screen.reload(player["player_id"])
        await interaction.response.edit_message(
            embed=await self.screen.card(), view=self.screen
        )
        await interaction.followup.send(said, ephemeral=True)


class AscendButton(discord.ui.Button):
    """Spend five stars for a tier.

    Offered only at the star cap and only below the top tier, because those
    are the two things `servant_ascend` refuses - a button that is always
    there and usually refuses teaches people to stop pressing buttons.
    """

    def __init__(self, screen: "ServantView", row: dict) -> None:
        self.screen = screen
        super().__init__(
            label=f"Ascend to tier {int(row['tier']) + 1}",
            emoji="\N{UPWARDS BLACK ARROW}",
            style=discord.ButtonStyle.primary,
            row=3,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        try:
            got = await db.fetch_one(
                "SELECT * FROM servant_ascend(%s, %s)",
                (player["player_id"], self.screen.chosen["player_servant_id"]),
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        await self.screen.reload(player["player_id"])
        await interaction.response.edit_message(
            embed=await self.screen.card(), view=self.screen
        )
        await interaction.followup.send(
            f"\N{UPWARDS BLACK ARROW} **{got['name']}** ascends to tier "
            f"{got['now_tier']} (**{got['rarity']}**), back to "
            f"{STAR * int(got['stars'])} \N{EM DASH} "
            f"**{got['per_hour']}** an hour.",
            ephemeral=True,
        )


class RaiseButton(discord.ui.Button):
    def __init__(self, screen: "ServantView", row: dict) -> None:
        self.screen = screen
        super().__init__(
            label=f"Raise to {row['next_stars']} stars "
                  f"({row['copies_needed']} spare)",
            emoji=STAR,
            style=discord.ButtonStyle.success,
            row=3,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        try:
            got = await db.fetch_one(
                "SELECT * FROM servant_nurture(%s, %s)",
                (player["player_id"], self.screen.chosen["player_servant_id"]),
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        await self.screen.reload(player["player_id"])
        await interaction.response.edit_message(
            embed=await self.screen.card(), view=self.screen
        )
        await interaction.followup.send(
            f"{STAR} **{got['name']}** rises to {got['stars_after']} stars "
            f"on {got['eaten']} spare(s).",
            ephemeral=True,
        )


# ---------------------------------------------------------------------------
# Feeding
# ---------------------------------------------------------------------------


class HowMany(AnsweringModal):
    """How many to hand over.

    `servant_feed` and `servant_feed_essence` have both taken a quantity from
    the day they were written; the screen simply always passed 1. A handful is
    never worse than the same number one at a time, because the quantity goes
    inside the worth formula and so rounds once instead of N times.
    """

    amount = discord.ui.TextInput(label="How many", max_length=12)

    def __init__(self, screen: "ServantView", food: dict, kind: str) -> None:
        super().__init__(title=f"Feed {food['name']}"[:45])
        self.screen = screen
        self.food = food
        self.kind = kind
        self.amount.placeholder = f"You hold {thousands(food['quantity'])}"[:100]

    async def on_submit(self, interaction: discord.Interaction) -> None:
        try:
            many = int(str(self.amount).strip())
        except ValueError as exc:
            raise GameError("That is not a number.") from exc
        if many < 1:
            raise GameError("Feed them something.")

        player = await require_player(interaction.user)
        servant = self.screen.chosen
        if servant is None:
            raise GameError("Choose a servant first.")

        call = (
            "SELECT * FROM servant_feed_essence(%s, %s, %s, %s)"
            if self.kind == "essence"
            else "SELECT * FROM servant_feed(%s, %s, %s, %s)"
        )
        ref = self.food["ref"] if self.kind == "essence" else int(self.food["ref"])

        try:
            got = await db.fetch_one(
                call,
                (player["player_id"], servant["player_servant_id"], ref, many),
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        await self.screen.reload(player["player_id"])
        await interaction.response.edit_message(
            embed=await self.screen.card(), view=self.screen
        )
        await interaction.followup.send(
            f"**{got['servant_name']}** swallows {many}\N{MULTIPLICATION SIGN} "
            f"{got['fed']} \N{EM DASH} {thousands(got['gained'])} cultivation"
            + (f"\n\N{SPARKLES} **{got['realm_name']}**" if got["rose"]
               else f"\n*{got['realm_name']}* \N{BULLET} "
                    f"{thousands(got['wants'])} for the next"),
            ephemeral=True,
        )


class FeedPicker(discord.ui.Select):
    """Pills and essence in one menu, because there is no room for two.

    A view holds five component rows and this screen already uses all five.
    Rather than take a row back off the buttons, both foods share the one
    select and carry their kind in the option value - which also means a
    cultivator sees everything a servant can eat in a single list.
    """

    def __init__(self, screen: "ServantView", food: list[dict]) -> None:
        self.screen = screen
        self.food = {f"{f['kind']}:{f['ref']}": f for f in food}
        super().__init__(
            placeholder="Feed them what?",
            row=4,
            options=[
                discord.SelectOption(
                    label=f"{f['name']} \N{MULTIPLICATION SIGN}{thousands(f['quantity'])}"[:100],
                    value=f"{f['kind']}:{f['ref']}",
                    description=f["note"][:100],
                )
                for f in food
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        chosen = self.food[self.values[0]]
        await interaction.response.send_modal(
            HowMany(self.screen, chosen, chosen["kind"])
        )




# ---------------------------------------------------------------------------
# The screen
# ---------------------------------------------------------------------------


class FocusModal(AnsweringModal):
    """Told by name rather than picked from a list.

    There are 155 materials in the mortal band and a Discord select holds 25,
    so a picker would have to page or to guess which ones somebody wanted. A
    cultivator hunting Centipede Venom already knows the words; matching on
    what they type is both simpler and the only version that reaches all 155.
    """

    wanted = discord.ui.TextInput(
        label="What should they look for?",
        placeholder="Centipede Venom, Fish Scale Shard",
        required=False,
        max_length=200,
    )

    def __init__(self, screen: "ServantView", servant: dict, most: int) -> None:
        super().__init__(title=f"Orders for {servant['name']}"[:45])
        self.screen = screen
        # A Modal has no `row` property to collide with, unlike a Button - but
        # naming it the same way here keeps the pair readable together.
        self.servant = servant
        self.most = most
        current = servant.get("focus_names")
        if current:
            self.wanted.default = current

    async def on_submit(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        typed = [w.strip() for w in str(self.wanted).split(",") if w.strip()]

        if len(typed) > self.most:
            raise GameError(
                f"A servant can be told to look for {self.most} things at once."
            )

        codes: list[str] = []
        for word in typed:
            # Exact name first, then a contains match, so "venom" finds the
            # one thing and "scale" says which scales it could have meant.
            found = await db.fetch_all(
                """
                SELECT m.code, m.name FROM materials m
                -- Asked of THIS servant since 0447: one who has crossed into
                -- the Immortal Realm may be pointed at immortal ground, and
                -- one who has not may not. The screen has to ask the same
                -- question `servant_focus_set` will, or it offers something
                -- that is then refused.
                WHERE servant_may_gather(m.code, %(s)s)
                  AND (lower(m.name) = lower(%(w)s)
                       OR lower(m.name) LIKE '%%' || lower(%(w)s) || '%%')
                ORDER BY (lower(m.name) = lower(%(w)s)) DESC, m.name
                LIMIT 6
                """,
                {"w": word, "s": self.servant["player_servant_id"]},
            )
            if not found:
                raise GameError(
                    f"Nothing this servant can reach is called **{word}**. "
                    "They bring back what the mortal world grows up to "
                    "the rarity their own cultivation reaches — "
                    "and, once they have crossed into the Immortal Realm, "
                    "what grows beyond it."
                )
            if len(found) > 1 and found[0]["name"].lower() != word.lower():
                near = ", ".join(f["name"] for f in found)
                raise GameError(f"**{word}** could be any of: {near}")
            codes.append(found[0]["code"])

        try:
            got = await db.fetch_one(
                "SELECT * FROM servant_focus_set(%s, %s, %s)",
                (player["player_id"], self.servant["player_servant_id"], codes),
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        await self.screen.reload(player["player_id"])
        await interaction.response.edit_message(
            embed=await self.screen.card(), view=self.screen
        )
        await interaction.followup.send(
            f"**{got['servant_name']}** will look for {got['focused']}.",
            ephemeral=True,
        )


class FocusButton(discord.ui.Button):
    # NOT `self.row`. `discord.ui.Item` already owns that name for the layout
    # row and validates it as `5 > value >= 0`, so assigning a servant dict to
    # it raises TypeError inside the property setter - which happens during
    # `build()`, before the interaction has been answered, so Discord reports
    # it as the bot never responding rather than as the crash it is.
    def __init__(self, screen: "ServantView", servant: dict, most: int) -> None:
        self.screen = screen
        self.servant = servant
        self.most = most
        super().__init__(
            label="Tell them what to look for",
            emoji="🔍",
            style=discord.ButtonStyle.secondary,
            row=3,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        await interaction.response.send_modal(
            FocusModal(self.screen, self.servant, self.most)
        )


class ServantView(AnsweringView):
    def __init__(self, user: discord.abc.User, player_id: int) -> None:
        super().__init__(timeout=600)
        self.user = user
        self.player_id = player_id
        self.rows: list[dict] = []
        self.pills: list[dict] = []
        self.chosen: dict | None = None
        self.slots = 0
        self.working = 0
        self.collection = 0
        self.bonus = 0
        self.jade = 0
        self.cost = 0
        self.focus_max = 3
        self.attend_max = 3
        # Narrowing and paging. A collection runs to a hundred and forty and a
        # Discord select holds twenty-five, so without these the deep end of
        # somebody's own roster is not merely hard to reach, it is absent.
        self.term: str = ""
        self.tier: int | None = None
        self.page: int = 0

    async def reload(self, player_id: int) -> None:
        self.rows = await fetch_servants(player_id)
        # Keep the chosen one selected across a redraw, or every press throws
        # the player back to the top of their own collection.
        if self.chosen is not None:
            self.chosen = next(
                (r for r in self.rows
                 if r["player_servant_id"] == self.chosen["player_servant_id"]),
                None,
            )
        standing = await db.fetch_one(
            """
            SELECT servant_farm_slots(%(p)s) AS slots,
                   servant_collection(%(p)s) AS collection,
                   servant_collection_bonus(%(p)s) AS bonus,
                   jade_held(%(p)s) AS jade,
                   game_config_value('servant_roll_jade') AS cost,
                   game_config_value('servant_focus_max') AS focus_max,
                   game_config_value('servant_attend_max') AS attend_max
            """,
            {"p": player_id},
        )
        self.slots = standing["slots"]
        self.collection = standing["collection"]
        self.bonus = standing["bonus"]
        self.jade = standing["jade"]
        self.cost = int(standing["cost"])
        self.focus_max = int(standing["focus_max"])
        self.attend_max = int(standing["attend_max"])
        self.working = sum(1 for r in self.rows if r["farming"])

        if not RARITIES:
            for row in await db.fetch_all(
                "SELECT tier, rarity FROM servant_tiers ORDER BY tier"
            ):
                RARITIES[int(row["tier"])] = row["rarity"]

        # Everything a servant will eat, in one list: pills and essence.
        # Essence first and deepest first, because past the immortal door it
        # is the food that is worth anything - one of the servant's own rank
        # is a tenth of their stage, and a shallow one is a rounding error.
        self.pills = await db.fetch_all(
            """
            SELECT 'essence' AS kind, pm.material_code AS ref, m.name,
                   pm.quantity, ie.rank AS sort_rank,
                   'immortal essence, rank ' || ie.rank AS note
            FROM player_materials pm
            JOIN immortal_essences ie ON ie.material_code = pm.material_code
            JOIN materials m ON m.code = pm.material_code
            WHERE pm.player_id = %(p)s AND pm.quantity > 0
            UNION ALL
            SELECT 'pill', pl.pill_id::text, pl.name, pl.quantity, pl.tier,
                   'tier ' || pl.tier || ' ' || pl.kind || ' pill'
            FROM player_pills pl
            WHERE pl.owner_id = %(p)s AND pl.kind IN ('cultivation', 'insight')
            ORDER BY kind, sort_rank DESC, name
            LIMIT 25
            """,
            {"p": player_id},
        )
        self.build()

    def filter_words(self) -> str:
        """What the Find button says is currently on. Empty when nothing is."""
        said = []
        if self.tier:
            said.append(f"T{self.tier}")
        if self.term:
            said.append(f'"{self.term}"')
        return " ".join(said)

    def visible(self) -> list[dict]:
        """The collection the filters left, in the order it is always read.

        Both narrow at once and neither clears the other: somebody after a
        mythic called Bai has asked one question, not two.
        """
        shelf = self.rows
        if self.tier:
            shelf = [r for r in shelf if int(r["tier"]) == self.tier]
        if self.term:
            want = self.term.casefold()
            shelf = [r for r in shelf if want in str(r["name"]).casefold()]
        return shelf

    def page_count(self) -> int:
        return page_count(self.visible())

    def build(self) -> None:
        self.clear_items()
        self.add_item(SummonButton(self, self.cost))
        if any(r["farming"] for r in self.rows):
            self.add_item(CollectButton(self))

        if self.rows:
            self.add_item(ServantFindButton(self))
            # A page of them rather than the first 25. Before this, 95 of
            # pashu0's 140 servants could not be chosen at all - the select
            # took the top of a tier-ordered list and said nothing about the
            # rest, so the shallow half of a deep collection was unreachable
            # rather than merely inconvenient.
            shown = page_of(self.visible(), self.page)
            if shown:
                self.add_item(ServantPicker(self, shown))
                add_page_buttons(self, row=0)
            # A search that matches nobody leaves the Find button and nothing
            # else: a select with no options is one Discord refuses outright,
            # and the card says why the list is empty.

        if self.chosen is not None:
            # A button in the same place either way. One that simply is not
            # there reads as broken, which is exactly how the old screen was
            # reported - so the attending servant gets the opposite action
            # rather than a gap.
            if self.chosen["attending"]:
                self.add_item(DismissButton(self))
            else:
                self.add_item(AttendButton(self))
            self.add_item(WorkButton(self, not self.chosen["farming"]))
            if self.chosen["spares"] >= self.chosen["copies_needed"]:
                self.add_item(RaiseButton(self, self.chosen))
            # At the cap there is nothing left to raise, so the stars become
            # the price of a tier instead. See 0478.
            if (self.chosen["stars"] >= self.chosen["max_stars"]
                    and self.chosen["tier"] < self.chosen["top_tier"]):
                self.add_item(AscendButton(self, self.chosen))
            self.add_item(FocusButton(self, self.chosen, self.focus_max))
            if self.pills:
                self.add_item(FeedPicker(self, self.pills[:25]))

    async def card(self) -> discord.Embed:
        card = embed(
            "\N{BUSTS IN SILHOUETTE} Your servants",
            f"{self.collection} of "
            f"{await db.fetch_value('SELECT count(*) FROM servants')} collected"
            + (f" \N{BULLET} collection bonus {percent(self.bonus)} to every haul"
               if self.bonus else "")
            + f"\n{BASKET} {self.working} of {self.slots} out working"
            + f" \N{BULLET} {JADE} {thousands(self.jade)} jade",
            colour=COLOUR_INFO,
        )

        if not self.rows:
            card.add_field(
                name="Nobody yet",
                value="Summon one. They go where you no longer can \N{EM DASH} "
                      "the mortal meadows a Gu recipe still asks for.",
                inline=False,
            )
            return card

        seen = self.visible()
        if not seen:
            card.add_field(
                name="Nobody matches",
                value=f"No servant of yours answers to **{self.filter_words()}**."
                      "\nPress it again to clear the search.",
                inline=False,
            )
        elif self.filter_words():
            card.add_field(
                name=f"Showing {self.filter_words()}",
                value=f"{len(seen)} of {len(self.rows)} servants"
                      + (f" • {page_note(seen, self.page, 'servant')}"
                         if page_count(seen) > 1 else ""),
                inline=False,
            )
        elif page_count(seen) > 1:
            card.add_field(
                name="Your collection",
                value=page_note(seen, self.page, "servant"),
                inline=False,
            )

        # All of them now, not the first one found. `servant_stat` sums the
        # attending servants and `player_stat` clamps the total, so the card
        # has to show the same set the damage pipeline is adding up.
        attending = [r for r in self.rows if r["attending"]]
        card.add_field(
            name=f"Attending you ({len(attending)} of {self.attend_max})",
            value="\n".join(
                f"{RARITY_MARK.get(a['rarity'], '')} **{a['name']}** "
                f"{STAR * int(a['stars'])} \N{EM DASH} {grant_line(a)}"
                + (f"\n     *{a['trait_name']}*" if a["trait_name"] else "")
                for a in attending
            )
            or "*Nobody. Up to three may attend you, and their passives are "
               "felt in every fight.*",
            inline=False,
        )

        shown = self.rows[:PER_PAGE]
        card.add_field(
            name=f"Held ({len(self.rows)})",
            value="\n".join(servant_line(r) for r in shown)
            + (f"\n\N{HORIZONTAL ELLIPSIS} and {len(self.rows) - len(shown)} more"
               if len(self.rows) > len(shown) else ""),
            inline=False,
        )

        if self.chosen is not None:
            it = self.chosen
            told = [
                f"`T{it['tier']}` {it['rarity']} \N{BULLET} "
                f"{STAR * int(it['stars'])}"
                + (" \N{BULLET} **attending you**"
                   if it["attending"] else ""),
                f"Grants {grant_line(it)}",
                f"Brings home **{it['per_hour']}** an hour"
                + (f" • **{it['immortal_per_hour']}** of it from "
                   "the immortal regions"
                   if it["immortal_per_hour"] else ""),
                # Rarer ground gives less of itself, and how much less is
                # the whole of the decision when pointing one somewhere.
                *([f"Rarer ground an hour — {it['rarer_rates']}"]
                  if it["rarer_rates"] else []),
                # The door is worth naming for a servant who has not reached
                # it: feeding one past the Immortal Realm is the only way to
                # open it, and nothing else on this screen says so.
                (f"Reaches **{it['reaches']}** material"
                 + ("" if it["immortal_per_hour"] else
                    f" • immortal ground at realm "
                    f"{it['immortal_realm']}")),
                f"*{it['realm_name']}* \N{BULLET} "
                f"{thousands(it['cultivation'])} cultivation",
            ]
            if it["next_realm_costs"]:
                told.append(
                    f"{thousands(it['next_realm_costs'])} for the next realm"
                )
            told.append(
                "Looking for **" + (it["focus_names"] or "whatever they find")
                + "**"
            )
            told.append(
                f"{it['spares']} spare(s) held, "
                f"{it['copies_needed']} needed for {it['next_stars']} stars"
            )
            card.add_field(
                name=f"\N{BLACK RIGHTWARDS ARROW} {it['name']}",
                value="\n".join(told),
                inline=False,
            )

        card.set_footer(
            text="One attends you; several may work. Duplicates raise stars."
        )
        return card

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "Summon your own.", ephemeral=True
            )
            return False
        return True


class Servants(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @app_commands.command(
        description="The servants you hold, and what they bring home."
    )
    async def servants(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        view = ServantView(interaction.user, player["player_id"])
        await view.reload(player["player_id"])
        await interaction.response.send_message(
            embed=await view.card(), view=view
        )
        view.message = await interaction.original_response()


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Servants(bot))
