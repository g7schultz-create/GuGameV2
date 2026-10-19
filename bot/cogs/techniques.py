"""Techniques and the loadout: /techniques, /technique, /learn, /loadout,
/equip, /unequip, /damage.

There is no switching mid-battle, so the loadout committed here is the whole
answer to whatever gets met. That is what makes /damage worth having as a
command rather than a debug script: checking coverage before committing is the
decision the combat model is built around.

/techniques is a shop rather than a catalogue since 0126. It draws
`technique_shelf`, which prices every technique against the cultivator asking
and names which of the three gates - realm, Path attainment, Spirit Stones - is
the one in the way. /learn calls `learn_technique`, which reads that same
function, so the screen cannot offer something the command then refuses.
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
    fit_field,
    interaction_label,
    percent,
    thousands,
)
from bot.lookups import (
    known_technique_autocomplete,
    resolve_species,
    resolve_technique,
    species_autocomplete,
    technique_autocomplete,
)
from bot.picking import add_page_buttons, page_note
from bot.players import (
    GameError,
    fetch_player,
    require_player,
    settle_passive,
)
from bot.views import AnsweringView

LOADOUT_SLOTS = 8

# Spirit Stones, the fee. Named because three screens below quote it.
STONE = "\N{LARGE BLUE DIAMOND}"

# An advanced technique. Drawn with a scroll rather than a lock because it is
# not gated - it is simply somewhere else, and the line says where.
SCROLL = "\N{SCROLL}"

# A shelf entry is three lines tall, so a page of 25 would overrun an embed's
# 4096 characters. Eight fits, with room for the longest name in 0125.
SHELF_PER_PAGE = 8


_TIERS: dict[int, str] | None = None


async def tier_names() -> dict[int, str]:
    """Tier number to its name. Eleven static rows, fetched once a process.

    The shelf reports the tier a cultivator HAS as a number and the one a
    technique WANTS by name, because only the second was worth a join per row
    inside the function. This is the other half of that trade.
    """
    global _TIERS
    if _TIERS is None:
        rows = await db.fetch_all("SELECT tier, name FROM attainment_tiers")
        _TIERS = {row["tier"]: row["name"] for row in rows}
    return _TIERS


def shelf_standing(row: dict, tiers: dict[int, str]) -> tuple[str, str]:
    """Why a technique is shut - the first reason that is true, and only it.

    Ordered by what a player can do about it. Realm first, because it is the
    gate that opens on its own and cannot be hurried. Attainment second,
    because /focus is the answer and it takes days. Money last, because it is
    the one that is never a wall - it is an afternoon.

    An advanced technique short-circuits all three: it has no price, so the
    only useful thing to say is where the manual carrying it is - in your hand,
    in your bag, or still out in the world.
    """
    if row["known"]:
        return "\N{OPEN BOOK}", "already yours"
    if not row["realm_ok"]:
        return (
            "\N{LOCK}",
            f"a rank {row['tech_rank']} technique \N{EM DASH} cultivate further",
        )
    if row["grade"] == "advanced":
        book = row["manual_name"] or "a manual"
        # 0172. Studying is the only thing here a player can DO rather than
        # wait for, so it is said before the two states that are just facts
        # about where the book is.
        if row["study_ready"]:
            return (
                "\N{OPEN BOOK}",
                f"**/read** \N{EM DASH} {thousands(row['study_cost'])} {STONE} "
                f"and **{book}** is spent, but the slot comes back",
            )
        if row["manual_held"] and not row["tier_ok"]:
            return (
                "\N{COMPASS}",
                f"reading it wants **{row['need_tier_name']}** in the "
                f"{row['path_name']} and you are "
                f"{tiers.get(row['have_tier'], 'Uninitiated')} \N{EM DASH} "
                f"carry **{book}** equipped until then",
            )
        if row["on_loan"]:
            return SCROLL, f"carried \N{EM DASH} **{book}** is lending it to you"
        if row["manual_held"]:
            return SCROLL, f"**{book}** is in your bag \N{EM DASH} **/equipment**"
        return SCROLL, f"only from **{book}**"
    if not row["tier_ok"]:
        return (
            "\N{COMPASS}",
            f"wants **{row['need_tier_name']}** in the {row['path_name']}, and "
            f"you are {tiers.get(row['have_tier'], 'Uninitiated')} "
            f"\N{EM DASH} **/focus**",
        )
    if not row["stones_ok"]:
        short = row["stone_cost"] - row["stones_held"]
        return "\N{MONEY BAG}", f"{thousands(short)} {STONE} short"
    return "\N{WHITE HEAVY CHECK MARK}", "**/learn** it"


def shelf_line(row: dict, tiers: dict[int, str]) -> str:
    glyph, standing = shelf_standing(row, tiers)
    # A technique that mends or wards has no power to print, and printing
    # the bare word "support" told nobody anything. Since 0308 there are
    # thirty-two of these and the effect IS the technique.
    weight = (
        f"{thousands(row['base_power'])} power"
        if row["base_power"]
        else (row.get("does") or row["category"])
    )
    advanced = row["grade"] == "advanced"
    # A price for what has one; the word "advanced" for what has none. Printing
    # "0 stones" over something that cannot be bought at any figure would read
    # as free, which is the opposite of true.
    price = (
        f"**advanced** \N{BULLET} not for sale"
        if advanced
        else f"{thousands(row['stone_cost'])} {STONE}"
    )
    # Worth saying out loud on a basic technique: a manual is lending you this
    # one, and unequipping it takes the technique back. On an advanced one the
    # standing line below already says exactly that.
    loan = (
        "  \N{BOOKMARK} *on loan from a manual*"
        if row["on_loan"] and not advanced
        else ""
    )
    pad = "\N{IDEOGRAPHIC SPACE}"
    return (
        f"{glyph} **{row['name']}** \N{BULLET} rank {row['tech_rank']} "
        f"\N{BULLET} {weight}{loan}\n"
        f"{pad}{row['typing'] or 'Untyped'} \N{BULLET} {price}\n"
        f"{pad}{standing}"
    )


# How the catalogue can be ordered. The Path grouping is the one that makes a
# hundred rows readable: a technique's Path is its type here, and somebody
# reading this shelf is nearly always asking "what is there on MY Path".
SHELF_SORTS = (
    ("rank", "By rank", "\N{CHART WITH UPWARDS TREND}",
     lambda r: (r["tech_rank"], r["grade"] != "advanced", -r["base_power"])),
    ("path", "By Path", "\N{DIRECT HIT}",
     lambda r: (r["path_name"] or "", r["tech_rank"], -r["base_power"])),
    ("power", "By power", "\N{HIGH VOLTAGE SIGN}",
     lambda r: (-r["base_power"], r["tech_rank"])),
    ("price", "Cheapest", "\N{LARGE BLUE DIAMOND}",
     lambda r: (r["known"], r["stone_cost"] or 0, r["tech_rank"])),
)

# What to leave on it. `ready` is the one a player wants most of the time and
# the one the old screen could only reach by typing an argument.
SHELF_FILTERS = (
    ("all", "All", lambda r: True),
    ("ready", "Can learn now", lambda r: r["ready"]),
    ("unknown", "Not yours yet", lambda r: not r["known"]),
    # The party screen tells you "no one here can pull a blow". This is how a
    # player acts on that: nine rows in a catalogue of two hundred and forty,
    # and no other filter finds them. The mapping lives in SQL - see 0460 -
    # so the shelf and the Trial cannot drift apart about what a pull is.
    ("answers", "Trial answers", lambda r: bool(r.get("answers"))),
    ("advanced", "Advanced", lambda r: r["grade"] == "advanced"),
)


class SortSelect(discord.ui.Select):
    def __init__(self, screen: "Shelf") -> None:
        self.screen = screen
        super().__init__(
            placeholder="Order\N{HORIZONTAL ELLIPSIS}",
            row=0,
            options=[
                discord.SelectOption(
                    label=label, value=code, emoji=glyph,
                    default=code == screen.sort,
                )
                for code, label, glyph, _ in SHELF_SORTS
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        self.screen.sort = self.values[0]
        self.screen.page = 0
        await self.screen.redraw(interaction)


class RankSelect(discord.ui.Select):
    """Rank is the tier here, and it is the axis that actually cuts a hundred
    rows into something a page can hold."""

    def __init__(self, screen: "Shelf") -> None:
        self.screen = screen
        counts: dict[int, int] = {}
        for row in screen.rows:
            counts[row["tech_rank"]] = counts.get(row["tech_rank"], 0) + 1

        options = [
            discord.SelectOption(
                label=f"Every rank ({len(screen.rows)})", value="all",
                default=screen.rank is None,
            )
        ]
        options += [
            discord.SelectOption(
                label=f"Rank {rank} ({counts[rank]})", value=str(rank),
                default=screen.rank == rank,
            )
            for rank in sorted(counts)
        ]
        super().__init__(
            placeholder="Rank\N{HORIZONTAL ELLIPSIS}", row=1, options=options[:25]
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        picked = self.values[0]
        self.screen.rank = None if picked == "all" else int(picked)
        self.screen.page = 0
        await self.screen.redraw(interaction)


class FilterButton(discord.ui.Button):
    def __init__(self, screen: "Shelf", code: str, label: str, held: int) -> None:
        self.screen = screen
        self.code = code
        super().__init__(
            label=f"{label} ({held})",
            row=2,
            style=(
                discord.ButtonStyle.success
                if code == screen.narrow
                else discord.ButtonStyle.secondary
            ),
            disabled=held == 0 and code != screen.narrow,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        self.screen.narrow = self.code
        self.screen.page = 0
        await self.screen.redraw(interaction)


class Shelf(AnsweringView):
    """The catalogue, priced against whoever asked for it.

    A hundred rows at eight to a page is thirteen pages, and the only way to
    narrow it used to be a command argument you had to know existed - and
    could not change without running the command again. The order and the
    filter live on the screen now.
    """

    def __init__(
        self,
        rows: list[dict],
        heading: str,
        stones: int,
        tiers: dict[int, str],
        *,
        rank: int | None = None,
        narrow: str = "all",
    ) -> None:
        super().__init__(timeout=300)
        self.rows = rows
        self.heading = heading
        self.stones = stones
        self.tiers = tiers
        self.rank = rank
        self.narrow = narrow
        self.sort = "rank"
        self.page = 0
        self.build()

    def matching(self, narrow: str | None = None) -> list[dict]:
        keep = next(f for c, _, f in SHELF_FILTERS if c == (narrow or self.narrow))
        rows = [r for r in self.rows if keep(r)]
        if self.rank is not None:
            rows = [r for r in rows if r["tech_rank"] == self.rank]
        order = next(k for c, _, _, k in SHELF_SORTS if c == self.sort)
        return sorted(rows, key=order)

    def page_count(self) -> int:
        return max(1, -(-len(self.matching()) // SHELF_PER_PAGE))

    def build(self) -> None:
        self.clear_items()
        self.add_item(SortSelect(self))
        self.add_item(RankSelect(self))
        for code, label, _ in SHELF_FILTERS:
            self.add_item(FilterButton(self, code, label, len(self.matching(code))))
        add_page_buttons(self, row=3)

    async def redraw(self, interaction: discord.Interaction) -> None:
        self.build()
        await interaction.response.edit_message(embed=self.card(), view=self)

    def card(self) -> discord.Embed:
        shown = self.matching()
        page = self.page % self.page_count()
        here = shown[page * SHELF_PER_PAGE:(page + 1) * SHELF_PER_PAGE]

        title = self.heading
        if self.rank is not None:
            title += f" \N{EM DASH} rank {self.rank}"
        if self.narrow != "all":
            title += " \N{EM DASH} " + next(
                lab for c, lab, _ in SHELF_FILTERS if c == self.narrow
            ).lower()

        card = embed(
            title,
            "\n\n".join(shelf_line(row, self.tiers) for row in here)
            or "*Nothing on this shelf.*",
            colour=COLOUR_DEFAULT,
        )
        note = page_note(shown, self.page, "techniques", SHELF_PER_PAGE)
        ready = sum(1 for row in shown if row["ready"])
        carried = sum(
            1 for row in shown if row["grade"] == "advanced" and row["on_loan"]
        )
        card.set_footer(
            text=(f"{note}  \N{BULLET}  " if note else "")
            + f"{thousands(self.stones)} Spirit Stones  \N{BULLET}  "
            + (
                f"{ready} you can learn right now"
                if ready
                else "nothing you can learn right now"
            )
            + (f"  \N{BULLET}  {carried} advanced carried" if carried else "")
        )
        return card


class StudySelect(discord.ui.Select):
    def __init__(self, screen: "StudyPicker", ready: list[dict]) -> None:
        self.screen = screen
        super().__init__(
            placeholder="Read one to pieces\N{HORIZONTAL ELLIPSIS}",
            options=[
                discord.SelectOption(
                    label=(row["manual_name"] or "a manual")[:100],
                    value=str(row["manual_id"]),
                    description=(
                        f"{row['name']} \N{BULLET} rank {row['tech_rank']} "
                        f"\N{BULLET} {thousands(row['study_cost'])} stones"
                    )[:100],
                )
                # Discord takes twenty-five options. The card above lists the
                # whole bag, so a bag past that still SAYS what is in it - it
                # is only the dropdown that has to stop somewhere.
                for row in ready[:25]
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        await self.screen.study(interaction, int(self.values[0]))


class StudyPicker(AnsweringView):
    """Which advanced manual to read to pieces.

    The listing is built by /read; this only takes the answer. `study_manual`
    re-checks every gate itself - realm, attainment, stones, and that the book
    is still in the bag - so a stale screen refuses rather than half-acts.
    """

    def __init__(
        self, player_id: int, user: discord.abc.User, ready: list[dict]
    ) -> None:
        super().__init__(timeout=300)
        self.player_id = player_id
        self.user = user
        if ready:
            self.add_item(StudySelect(self, ready))

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "Your own books are your own \N{EM DASH} **/read**.", ephemeral=True
            )
            return False
        return True

    async def study(self, interaction: discord.Interaction, manual_id: int) -> None:
        try:
            got = await db.fetch_one(
                "SELECT * FROM study_manual(%s, %s)", (self.player_id, manual_id)
            )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0].capitalize()) from exc

        self.clear_items()
        card = embed(
            f"\N{OPEN BOOK} {got['technique_name']}",
            f"**{got['manual_name']}** is read to pieces. The move is yours "
            "for good.",
            colour=COLOUR_GOOD,
        )
        card.add_field(
            name="Learned",
            value=f"rank {got['technique_rank']} \N{BULLET} {got['path_name']}",
        )
        card.add_field(
            name="Cost",
            value=f"{thousands(got['stones_spent'])} {STONE}\n"
            f"{thousands(got['stones_left'])} left",
        )
        if got["slot_freed"]:
            card.add_field(
                name="Slot",
                value="The manual slot it was holding is yours again.",
                inline=False,
            )
        card.set_footer(text="**/loadout** to take it into a fight.")
        await interaction.response.edit_message(
            embed=card, view=discord.utils.MISSING
        )


class Techniques(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    # -----------------------------------------------------------------------

    @app_commands.command(
        description="Every technique, priced against what you can do."
    )
    @app_commands.describe(
        rank="Only techniques of this rank.",
        show="Narrow the shelf. Defaults to everything.",
    )
    @app_commands.choices(
        show=[
            app_commands.Choice(name="Everything", value="all"),
            app_commands.Choice(name="Learnable right now", value="ready"),
            app_commands.Choice(name="At or below my realm", value="realm"),
            app_commands.Choice(name="Ones I do not know", value="unknown"),
            app_commands.Choice(name="Answers a Peer Trial threat", value="answers"),
            app_commands.Choice(name="Advanced (manuals only)", value="advanced"),
        ]
    )
    async def techniques(
        self,
        interaction: discord.Interaction,
        rank: app_commands.Range[int, 1, 9] | None = None,
        show: app_commands.Choice[str] | None = None,
    ) -> None:
        """The shelf, filtered but never truncated.

        The old screen listed everything in one embed with nothing to say
        which of it was for you, and would have overrun Discord's 4096
        characters the moment 0125 landed. This pages, and every line carries
        its price and the one gate standing in the way of it.
        """
        player = await require_player(interaction.user)
        rows = await db.fetch_all(
            "SELECT s.*, technique_effect_summary(s.technique_id) AS does, "
            "       technique_trial_answers(s.technique_id) AS answers "
            "FROM technique_shelf(%s) s",
            (player["player_id"],),
        )

        if not rows:
            raise GameError("There is no catalogue to read yet.")

        # The arguments open the screen somewhere useful rather than deciding
        # what it may ever show. Narrowing is the view's business now, so a
        # reader can widen it again without running the command twice.
        narrow = show.value if show else "all"
        if narrow == "realm":
            narrow = "unknown"

        screen = Shelf(
            rows, "Techniques", rows[0]["stones_held"], await tier_names(),
            rank=rank, narrow=narrow,
        )
        await interaction.response.send_message(embed=screen.card(), view=screen)

    # -----------------------------------------------------------------------

    @app_commands.command(
        description="Read an advanced manual to pieces and keep the technique."
    )
    async def read(self, interaction: discord.Interaction) -> None:
        """The other way to hold an advanced move.

        Equipping one rents it: the manual pays half the stat budget of its
        tier and holds one of your two slots for as long as you want the
        technique. Studying buys it - the book is spent and the slot comes
        back - and asks the attainment `/learn` asks of a basic move at that
        rank, which wearing it does not.

        Every gate here comes off `technique_shelf`, the same row `/learn`
        reads. Two screens deciding separately whether somebody may read a
        book is how they end up disagreeing.
        """
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])

        rows = await db.fetch_all(
            "SELECT * FROM technique_shelf(%s) s "
            "WHERE s.grade = 'advanced' AND s.manual_held AND NOT s.known "
            "ORDER BY s.study_ready DESC, s.tech_rank DESC",
            (player["player_id"],),
        )
        if not rows:
            raise GameError(
                "You are carrying no advanced manual to read. They come off "
                "world beasts and out of a refinement at high harmony "
                "— **/boss**, **/refine**."
            )

        tiers = await tier_names()
        ready = [r for r in rows if r["study_ready"]]

        card = embed(
            "\N{OPEN BOOK} Reading",
            "A manual read to pieces gives up its technique for good. You keep "
            "the move, the book is gone, and the slot it was holding comes "
            "back \N{EM DASH} which is the whole difference between reading "
            "one and carrying it.",
            colour=COLOUR_INFO if ready else COLOUR_DEFAULT,
        )
        card.add_field(
            name=f"In your bag ({len(rows)})",
            value=fit_field(
                [shelf_line(row, tiers) for row in rows], sep="\n", noun="more"
            ),
            inline=False,
        )
        card.set_footer(
            text="Carrying it costs a slot and half a tier's bonus, forever. "
            "Reading it costs the book once."
        )

        view = StudyPicker(player["player_id"], interaction.user, ready) if ready else None
        await interaction.response.send_message(
            embed=card, view=view or discord.utils.MISSING
        )

    @app_commands.command(description="One technique in full.")
    @app_commands.describe(technique="The technique to read.")
    @app_commands.autocomplete(technique=technique_autocomplete)
    async def technique(self, interaction: discord.Interaction, technique: str) -> None:
        """One technique in full - including, for anyone who has a character,
        what it would cost them and which gate is shut."""
        row = await resolve_technique(technique)
        typing = await _technique_paths(row["technique_id"])
        player = await fetch_player(interaction.user.id)
        mine = None
        if player is not None:
            mine = await db.fetch_one(
                "SELECT * FROM technique_shelf(%s) s WHERE s.technique_id = %s",
                (player["player_id"], row["technique_id"]),
            )

        card = embed(row["name"], row["description"], colour=COLOUR_DEFAULT)
        card.add_field(name="Rank", value=str(row["rank"]))
        card.add_field(name="Category", value=row["category"].title())
        card.add_field(name="Base power", value=thousands(row["base_power"]))
        does = await db.fetch_value(
            "SELECT technique_effect_summary(%s)", (row["technique_id"],)
        )
        if does:
            card.add_field(
                name="What it leaves behind",
                value=does.replace(" * ", "\n"),
                inline=False,
            )
        card.add_field(
            name="Typing",
            value="\n".join(
                f"{t['name']} — {percent(t['weight'], signed=False)} of the typing"
                for t in typing
            )
            or "Untyped.",
            inline=False,
        )
        card.add_field(
            name="Cost",
            value=(
                f"{percent(row['qi_cost_pct'], signed=False)} of max qi  ·  "
                f"{percent(row['accuracy'], signed=False)} accuracy  ·  "
                f"{row['cooldown_turns']} turn cooldown"
            ),
            inline=False,
        )
        if mine is not None:
            glyph, standing = shelf_standing(mine, await tier_names())
            advanced = mine["grade"] == "advanced"
            card.add_field(
                name="Where it comes from" if advanced else "To learn it",
                value=(
                    f"{glyph} {standing}"
                    if advanced
                    else f"{thousands(mine['stone_cost'])} {STONE} \N{EM DASH} "
                    f"{glyph} {standing}"
                ),
                inline=False,
            )

        card.set_footer(text=row["code"])
        await interaction.response.send_message(embed=card)

    # -----------------------------------------------------------------------

    @app_commands.command(
        description="Buy a technique, if your realm, Path and purse allow it."
    )
    @app_commands.describe(technique="The technique to learn.")
    @app_commands.autocomplete(technique=technique_autocomplete)
    async def learn(self, interaction: discord.Interaction, technique: str) -> None:
        """One call, because one function decides.

        Every gate lives in `learn_technique`, which reads the same
        `technique_shelf` that /techniques draws. Re-checking the realm here -
        which is what this command used to do - is how a screen and a command
        end up disagreeing about what is allowed.
        """
        player = await require_player(interaction.user)
        row = await resolve_technique(technique)

        try:
            bought = await db.fetch_one(
                "SELECT * FROM learn_technique(%s, %s)",
                (player["player_id"], row["technique_id"]),
            )
        except psycopg.errors.CheckViolation as exc:
            # Not .capitalize(), which lowercases everything after the first
            # letter - and every one of these refusals names a technique, a
            # Path or a realm.
            said = str(exc).splitlines()[0]
            raise GameError(said[:1].upper() + said[1:]) from exc

        card = embed(
            "Learned",
            f"**{bought['learned_name']}** is yours, and stays yours.\n\n"
            f"{thousands(bought['stones_spent'])} {STONE} spent \N{BULLET} "
            f"{thousands(bought['stones_left'])} {STONE} left",
            colour=COLOUR_GOOD,
        )
        if bought["was_on_loan"]:
            card.add_field(
                name="No longer borrowed",
                value="A manual was lending you this one. You can unequip that "
                "manual now without losing it.",
                inline=False,
            )
        card.set_footer(
            text=f"Your {bought['dominant_path']} attainment is what makes it "
            f"hit harder from here. /equip to carry it."
        )
        await interaction.response.send_message(embed=card)

    # -----------------------------------------------------------------------

    @app_commands.command(
        description="Put a technique down, for half the Spirit Stones back."
    )
    @app_commands.describe(technique="The technique to forget.")
    @app_commands.autocomplete(technique=known_technique_autocomplete)
    async def unlearn(self, interaction: discord.Interaction, technique: str) -> None:
        """The other end of /learn.

        Worth having because a tournament takes a technique at RANDOM out of
        the snapshot you entered with - so every weak move you own is a chance
        to swing with it, and fourteen rank 1 techniques against one rank 4
        means most swings are the wrong swing. Everywhere else picks your best
        for you, which is why this did not matter until 0151.
        """
        player = await require_player(interaction.user)
        row = await resolve_technique(technique)

        try:
            gone = await db.fetch_one(
                "SELECT * FROM unlearn_technique(%s, %s)",
                (player["player_id"], row["technique_id"]),
            )
        except psycopg.errors.CheckViolation as exc:
            said = str(exc).splitlines()[0]
            raise GameError(said[:1].upper() + said[1:]) from exc

        card = embed(
            "Put down",
            f"**{gone['forgotten']}** is no longer yours.\n\n"
            f"{thousands(gone['refunded'])} {STONE} back \N{BULLET} "
            f"{thousands(gone['stones_left'])} {STONE} held",
            colour=COLOUR_DEFAULT,
        )
        if gone["slot_freed"]:
            card.add_field(
                name="A slot opened",
                value="It was in your loadout, so that slot is empty now.",
                inline=False,
            )
        if gone["still_lent"]:
            # Learned AND lent is the case 0143 exists for. Forgetting the
            # learned half leaves the borrowed one, and a player who is not
            # told that will think the refund did nothing.
            card.add_field(
                name="You can still throw it",
                value="An equipped manual is teaching it. Unequip that manual "
                "and it goes with it.",
                inline=False,
            )
        card.set_footer(
            text=f"{gone['left_known']} technique(s) learned \N{BULLET} "
            "/learn to take one back on."
        )
        await interaction.response.send_message(embed=card)

    # -----------------------------------------------------------------------

    @app_commands.command(description="What you know and what you have equipped.")
    async def loadout(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)

        known = await db.fetch_all(
            """
            SELECT t.code, t.name, t.rank, pt.times_used,
                   l.slot_index,
                   -- Live rather than filed. See 0395.
                   technique_power_for(pt.player_id, t.technique_id)
                       AS base_power
            FROM player_techniques pt
            JOIN techniques t ON t.technique_id = pt.technique_id
            LEFT JOIN player_loadout l
                ON l.player_id = pt.player_id AND l.technique_id = pt.technique_id
            WHERE pt.player_id = %s
            ORDER BY t.rank, t.name
            """,
            (player["player_id"],),
        )

        card = embed("Loadout", colour=COLOUR_DEFAULT)

        equipped = {r["slot_index"]: r for r in known if r["slot_index"] is not None}
        slots = []
        for index in range(LOADOUT_SLOTS):
            row = equipped.get(index)
            slots.append(
                f"`{index + 1}` " + (f"**{row['name']}**" if row else "*empty*")
            )
        card.add_field(name="Equipped", value="\n".join(slots), inline=False)

        unequipped = [r for r in known if r["slot_index"] is None]
        card.add_field(
            name=f"Known but not equipped ({len(unequipped)})",
            value="\n".join(f"**{r['name']}** — `{r['code']}`" for r in unequipped)
            or "Nothing. **/learn** something.",
            inline=False,
        )
        card.set_footer(
            text="No switching mid-battle — what is in these slots is your whole answer."
        )
        await interaction.response.send_message(embed=card)

    # -----------------------------------------------------------------------

    @app_commands.command(description="Put a technique you know into a loadout slot.")
    @app_commands.describe(slot="Which slot to fill.", technique="A technique you have learned.")
    @app_commands.autocomplete(technique=known_technique_autocomplete)
    async def equip(
        self,
        interaction: discord.Interaction,
        slot: app_commands.Range[int, 1, LOADOUT_SLOTS],
        technique: str,
    ) -> None:
        player = await require_player(interaction.user)
        row = await resolve_technique(technique)

        # The composite FK into player_techniques already makes equipping an
        # unknown technique impossible; this only exists to say so in English
        # rather than surfacing a constraint violation.
        known = await db.fetch_value(
            "SELECT 1 FROM player_techniques WHERE player_id = %s AND technique_id = %s",
            (player["player_id"], row["technique_id"]),
        )
        if not known:
            raise GameError(f"You have not learned **{row['name']}**. Try **/learn**.")

        await db.execute(
            """
            INSERT INTO player_loadout (player_id, slot_index, technique_id)
            VALUES (%s, %s, %s)
            ON CONFLICT (player_id, slot_index)
            DO UPDATE SET technique_id = EXCLUDED.technique_id, equipped_at = now()
            """,
            (player["player_id"], slot - 1, row["technique_id"]),
        )
        await interaction.response.send_message(
            embed=embed(
                "Equipped",
                f"Slot {slot}: **{row['name']}**.",
                colour=COLOUR_GOOD,
            )
        )

    # -----------------------------------------------------------------------

    @app_commands.command(description="Clear a loadout slot.")
    @app_commands.describe(slot="Which slot to clear.")
    async def unequip(
        self,
        interaction: discord.Interaction,
        slot: app_commands.Range[int, 1, LOADOUT_SLOTS],
    ) -> None:
        player = await require_player(interaction.user)
        cleared = await db.fetch_one(
            "DELETE FROM player_loadout WHERE player_id = %s AND slot_index = %s "
            "RETURNING slot_index",
            (player["player_id"], slot - 1),
        )
        if cleared is None:
            raise GameError(f"Slot {slot} is already empty.")
        await interaction.response.send_message(
            embed=embed("Cleared", f"Slot {slot} is empty.", colour=COLOUR_DEFAULT)
        )

    # -----------------------------------------------------------------------

    @app_commands.command(
        description="Work out what one technique would do to one creature, stage by stage."
    )
    @app_commands.describe(
        technique="The technique to throw.",
        creature="The species to throw it at.",
        defense="Defense to resolve against. Defaults to the species' own.",
    )
    @app_commands.autocomplete(
        technique=technique_autocomplete, creature=species_autocomplete
    )
    async def damage(
        self,
        interaction: discord.Interaction,
        technique: str,
        creature: str,
        defense: app_commands.Range[int, 0, 1_000_000] | None = None,
    ) -> None:
        """Reads the pipeline straight out of the database.

        Every number below comes from `compute_technique_damage`, the same
        function combat will call — so this is a genuine dry run, not a second
        implementation that agrees with the first until it stops agreeing.
        """
        player = await require_player(interaction.user)
        tech = await resolve_technique(technique)
        species = await resolve_species(creature)
        against = species["base_defense"] if defense is None else defense

        # The external hook is no longer 1: Race, Root and Physique damage
        # bonuses arrive through it, weighted by the technique's own typing.
        external = await db.fetch_value(
            "SELECT player_external_multiplier(%s, %s)",
            (player["player_id"], tech["technique_id"]),
        )
        result = await db.fetch_one(
            "SELECT * FROM compute_technique_damage(%s, %s, %s, %s, %s)",
            (
                player["player_id"],
                tech["technique_id"],
                species["species_id"],
                external,
                against,
            ),
        )

        # The per-Path breakdown behind the single matchup number, so a
        # surprising total can be read rather than argued with.
        components = await db.fetch_all(
            """
            SELECT p.name, tp.weight,
                   COALESCE(cip.interaction, 'neutral') AS interaction,
                   COALESCE(mi.damage_modifier, 0) AS modifier,
                   cip.is_override
            FROM technique_paths tp
            JOIN paths p ON p.code = tp.path_code
            LEFT JOIN creature_incoming_paths cip
                ON cip.species_id = %s AND cip.path_code = tp.path_code
            LEFT JOIN matchup_interactions mi ON mi.code = cip.interaction
            WHERE tp.technique_id = %s
            ORDER BY tp.weight DESC, p.sort_order
            """,
            (species["species_id"], tech["technique_id"]),
        )

        immune = result["matchup_modifier"] == -1
        card = embed(
            f"{tech['name']} \N{RIGHTWARDS ARROW} {species['name']}",
            colour=COLOUR_BAD if immune else COLOUR_DEFAULT,
        )

        card.add_field(
            name="Matchup",
            value="\n".join(
                f"{p['name'].replace(' Path', '')} "
                f"({percent(p['weight'], signed=False)} of it) — {interaction_label(p['interaction'])} "
                f"{percent(p['modifier'])}"
                + ("  *species override*" if p["is_override"] else "")
                for p in components
            )
            or "Untyped — neutral into everything.",
            inline=False,
        )

        card.add_field(
            name="Pipeline",
            value=(
                f"Base power **{thousands(result['base_power'])}**\n"
                # Its own stage, not folded into the technique's printed
                # power - a screen whose whole job is showing every stage
                # must not hide one inside another.
                + (
                    f"Body **+{thousands(result['body_power'])}**\n"
                    if result.get("body_power")
                    else ""
                )
                + f"Attainment **{percent(result['attainment_bonus'])}**\n"
                f"Matchup **{percent(result['matchup_modifier'])}**"
                + (" — immune\n" if immune else "\n")
                + f"Traits **{percent(external - 1)}**\n"
                f"Before defense **{thousands(round(result['pre_defense']))}**\n"
                f"Defense **{thousands(against)}**"
            ),
            inline=False,
        )

        card.add_field(
            name="Damage",
            value=f"# {thousands(result['final_damage'])}",
            inline=False,
        )
        card.set_footer(
            text="Matchup is clamped to the configured cap and floor. "
            "Traits are your Race, Root and Physique; Dao Marks and equipment "
            "will arrive through the same hook."
        )
        await interaction.response.send_message(embed=card)


async def _technique_paths(technique_id: int) -> list[dict]:
    return await db.fetch_all(
        """
        SELECT p.name, p.code, tp.weight
        FROM technique_paths tp
        JOIN paths p ON p.code = tp.path_code
        WHERE tp.technique_id = %s
        ORDER BY tp.weight DESC, p.sort_order
        """,
        (technique_id,),
    )


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Techniques(bot))
