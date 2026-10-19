"""Beast eggs and what comes out of them: /eggs and /pet.

The grade and the tier are separate on purpose and the screen keeps them
separate: the tier is where it was found and the rarity is the luck of the
finding, so a Dull tier 7 and a Goldshell tier 2 are different prizes and
neither is strictly better. Both carry through into the beast.

One beast walks at your heel and swings in every fight you take - the hunt,
a dungeon round, a gauntlet wave, a channel beast, the world boss. It is one
beast because `player_swing` is one function; the lanes never learned about
pets and did not have to.
"""

import discord
from discord import app_commands
from discord.ext import commands

from bot import database as db
import psycopg

from bot.formatting import COLOUR_GOOD, COLOUR_INFO, embed, fit_field, thousands
from bot.players import GameError, require_player
from bot.views import AnsweringModal, AnsweringView

PER_PAGE = 12


async def fetch_eggs(player_id: int) -> list[dict]:
    return await db.fetch_all(
        """
        SELECT s.egg_id, s.name, s.beast, s.beast_kind, s.tier, s.rarity,
               s.rarity_order, s.emoji, s.found_in_name
        FROM player_egg_shelf s
        WHERE s.owner_id = %s
        ORDER BY s.tier DESC, s.rarity_order DESC, s.name
        """,
        (player_id,),
    )


def line(row: dict) -> str:
    return (
        f"{row['emoji']} **{row['name']}**\n"
        f"     `T{row['tier']}` {row['rarity']}"
        + (f" \N{BULLET} {row['found_in_name']}" if row["found_in_name"] else "")
    )


class PageButton(discord.ui.Button):
    def __init__(self, shelf: "EggView", step: int, glyph: str) -> None:
        self.shelf = shelf
        self.step = step
        super().__init__(label=glyph, style=discord.ButtonStyle.primary)

    async def callback(self, interaction: discord.Interaction) -> None:
        self.shelf.page = (self.shelf.page + self.step) % self.shelf.pages()
        await interaction.response.edit_message(embed=self.shelf.card(), view=self.shelf)


class EggView(AnsweringView):
    def __init__(self, user: discord.abc.User, rows: list[dict], who: str) -> None:
        super().__init__(timeout=300)
        self.user = user
        self.rows = rows
        self.who = who
        self.page = 0
        # Paging appears only when there is a second page, so a cultivator
        # with three eggs is not looking at two dead buttons.
        if self.pages() > 1:
            self.add_item(PageButton(self, -1, "\N{LEFTWARDS BLACK ARROW}"))
            self.add_item(PageButton(self, 1, "\N{BLACK RIGHTWARDS ARROW}"))

    def pages(self) -> int:
        return max(1, -(-len(self.rows) // PER_PAGE))

    def card(self) -> discord.Embed:
        card = embed(
            f"\N{FRONT-FACING BABY CHICK} {self.who}'s Eggs",
            f"**{thousands(len(self.rows))}** unhatched.",
            colour=COLOUR_INFO,
        )

        if not self.rows:
            card.description = (
                "Nothing yet. Beasts leave them where beasts are thickest "
                "\N{EM DASH} the deeper the fight, the higher the tier."
            )
        else:
            page = self.rows[self.page * PER_PAGE:(self.page + 1) * PER_PAGE]
            card.add_field(
                name="Shelf",
                value="\n".join(line(r) for r in page)[:1024],
                inline=False,
            )

            # What the shelf is worth at a glance, which a list of twelve does
            # not answer on its own.
            grades: dict[str, int] = {}
            for row in self.rows:
                grades[row["rarity"]] = grades.get(row["rarity"], 0) + 1
            card.add_field(
                name="By grade",
                value=" \N{BULLET} ".join(
                    f"{n}x {rarity}"
                    for rarity, n in sorted(
                        grades.items(),
                        key=lambda kv: -max(
                            r["rarity_order"] for r in self.rows
                            if r["rarity"] == kv[0]
                        ),
                    )
                ),
                inline=False,
            )

        # The whole point of the screen, said where it cannot be missed.
        card.set_footer(
            text=(
                f"Page {self.page + 1} of {self.pages()} \N{BULLET} "
                if self.pages() > 1
                else ""
            )
            + "Hatch one and it walks at your heel \N{EM DASH} **/pet** is "
            "where it lives."
        )
        return card

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "Not your shelf.", ephemeral=True
            )
            return False
        return True

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True


class HatchPicker(discord.ui.Select):
    """Which egg to break. Deepest first, because that is the one worth it."""

    def __init__(self, shelf: "EggView", rows: list[dict]) -> None:
        self.shelf = shelf
        super().__init__(
            placeholder="Hatch which one?",
            options=[
                discord.SelectOption(
                    label=f"T{r['tier']} {r['name']}"[:100],
                    value=str(r["egg_id"]),
                    description=(
                        f"{r['rarity']} \N{BULLET} {r['beast']}"
                        + (f" \N{BULLET} {r['found_in_name']}"
                           if r["found_in_name"] else "")
                    )[:100],
                    emoji=r["emoji"][:1] if r["emoji"] else None,
                )
                for r in rows
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        try:
            beast = await db.fetch_value(
                "SELECT hatch_egg(%s, %s)",
                (player["player_id"], int(self.values[0])),
            )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0].capitalize()) from exc

        row = await db.fetch_one(
            "SELECT * FROM player_beast_shelf WHERE beast_id = %s", (beast,)
        )
        card = embed(
            f"{row['emoji'] or ''} {row['name']}",
            f"A **tier {row['tier']}** {row['species']} broke its shell.",
            colour=COLOUR_GOOD,
        )
        card.add_field(
            name="What it brings",
            value=f"{row['path_emoji'] or ''} {row['path_name'] or 'no Path'} "
            f"\N{BULLET} **{thousands(int(row['attack']))}** attack",
            inline=False,
        )
        card.set_footer(
            text="It swings after you in every fight you take. **/pet** to see it."
            if row["at_heel"]
            else "Another already walks at your heel. **/pet** to swap them."
        )
        await interaction.response.send_message(embed=card)


class PetPicker(discord.ui.Select):
    """Which one comes along. Only one may, so this is a swap."""

    def __init__(self, screen: "PetView", rows: list[dict]) -> None:
        self.screen = screen
        super().__init__(
            placeholder="Which one comes with you?",
            options=[
                discord.SelectOption(
                    label=f"T{r['tier']} {r['name']}"[:100],
                    value=str(r["beast_id"]),
                    description=(
                        f"{thousands(int(r['attack']))} attack \N{BULLET} "
                        f"{r['path_name'] or 'no Path'}"
                    )[:100],
                    emoji=r["emoji"][:1] if r["emoji"] else None,
                    default=r["at_heel"],
                )
                for r in rows
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        try:
            await db.execute(
                "SELECT pet_call(%s, %s)",
                (player["player_id"], int(self.values[0])),
            )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0].capitalize()) from exc

        self.screen.rows = await fetch_beasts(player["player_id"])
        self.screen.build()
        await interaction.response.edit_message(
            embed=self.screen.card(), view=self.screen
        )


async def fetch_beasts(player_id: int) -> list[dict]:
    return await db.fetch_all(
        """
        SELECT s.beast_id, s.name, s.tier, s.rarity, s.at_heel, s.species,
               s.emoji, s.shell, s.path_name, s.path_emoji, s.attack,
               s.found_in_name, s.stage, s.stage_name, s.stage_order,
               s.fed, s.wants, s.worth_as_food,
               s.hp, s.max_hp, s.is_down
        FROM player_beast_shelf s
        WHERE s.owner_id = %s
        ORDER BY s.at_heel DESC, s.stage_order DESC, s.attack DESC, s.name
        """,
        (player_id,),
    )


async def fetch_larder(player_id: int, beast_id: int | None = None) -> list[dict]:
    """Everything the cultivator is holding that THIS beast will eat.

    Ore and what comes off other beasts, worth the square of their grade, and
    Cultivation pills, worth more because somebody brewed them. Dearest first,
    because that is what raises a beast rather than merely feeding it.

    It has to ask which beast now. Past its elder years a beast eats immortal
    essence and nothing else, and below them it eats everything but. There was
    one answer to this before the immortal rungs existed, so the larder never
    had to know - and offering the whole cupboard to both would put Yellow
    Apricot Essence at the top of a baby's list, on worth, where it is the one
    thing that would be refused.
    """
    return await db.fetch_all(
        """
        SELECT pm.material_code AS ref, 'material' AS kind, m.name, m.emoji,
               pm.quantity, beast_food_value(m.code) AS worth
        FROM player_materials pm
        JOIN materials m ON m.code = pm.material_code
        WHERE pm.player_id = %(p)s AND pm.quantity > 0
          AND beast_food_value(m.code) > 0
          AND beast_food_is_essence(m.code)
              = COALESCE(beast_needs_essence(%(b)s), FALSE)
        UNION ALL
        SELECT pl.pill_id::text, 'pill', pl.name, k.emoji, pl.quantity,
               pl.tier::numeric ^ 2 * game_config_value('pet_pill_nourishment')
        FROM player_pills pl
        JOIN pill_kinds k ON k.code = pl.kind
        WHERE pl.owner_id = %(p)s AND pl.kind = 'cultivation'
          AND NOT COALESCE(beast_needs_essence(%(b)s), FALSE)
        ORDER BY worth DESC, name
        """,
        {"p": player_id, "b": beast_id},
    )


class FeedAmount(AnsweringModal):
    amount = discord.ui.TextInput(label="How many", max_length=12)

    def __init__(self, screen: "PetView", food: dict) -> None:
        super().__init__(title=f"Feed {food['name']}"[:45])
        self.screen = screen
        self.food = food
        self.amount.placeholder = (
            f"You hold {food['quantity']} \N{BULLET} "
            f"{int(food['worth'])} nourishment each"
        )[:100]

    async def on_submit(self, interaction: discord.Interaction) -> None:
        try:
            many = int(str(self.amount).strip())
        except ValueError as exc:
            raise GameError("That is not a number.") from exc
        if many < 1:
            raise GameError("Feed it something.")

        player = await require_player(interaction.user)
        beast = self.screen.at_heel()
        if beast is None:
            raise GameError("Nothing is at your heel to feed.")

        call = (
            "SELECT * FROM feed_beast_pill(%s, %s, %s, %s)"
            if self.food["kind"] == "pill"
            else "SELECT * FROM feed_beast(%s, %s, %s, %s)"
        )
        ref = int(self.food["ref"]) if self.food["kind"] == "pill" else self.food["ref"]

        try:
            got = await db.fetch_one(
                call, (player["player_id"], beast["beast_id"], ref, many)
            )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0].capitalize()) from exc

        self.screen.rows = await fetch_beasts(player["player_id"])
        still = self.screen.at_heel()
        self.screen.larder = await fetch_larder(
            player["player_id"], still["beast_id"] if still else None
        )
        self.screen.build()

        said = (
            f"**{beast['name']}** is a **{got['stage'].title()}** now."
            if got["grew_to"]
            else f"**{beast['name']}** takes it."
        )
        if got["still_wants"] is not None:
            said += (
                f"\n{int(got['fed'])} of **{int(got['still_wants'])}** "
                "toward the next stage."
            )
        else:
            said += "\nThere is nothing after Elder."

        await interaction.response.edit_message(
            embed=self.screen.card(), view=self.screen
        )
        await interaction.followup.send(said, ephemeral=True)


class RenderPicker(discord.ui.Select):
    """Which beast goes into the other one.

    The egg shelf is bottom-heavy and always will be, so a tier 3 hatchling
    that will never be anybody's companion is worth something as food.
    Cheapest first: the one you are least sorry to lose.
    """

    def __init__(self, screen: "PetView", rows: list[dict]) -> None:
        self.screen = screen
        self.rows = {str(r["beast_id"]): r for r in rows}
        super().__init__(
            placeholder="Render one down to raise it?",
            row=2,
            options=[
                discord.SelectOption(
                    label=f"T{r['tier']} {r['name']}"[:100],
                    value=str(r["beast_id"]),
                    description=(
                        f"{r['stage_name']} \N{BULLET} worth "
                        f"{int(r['worth_as_food'])} nourishment"
                    )[:100],
                    emoji=r["emoji"][:1] if r["emoji"] else None,
                )
                for r in rows
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        eater = self.screen.at_heel()
        if eater is None:
            raise GameError("Nothing is at your heel to raise.")

        eaten = self.rows[self.values[0]]
        try:
            got = await db.fetch_one(
                "SELECT * FROM feed_beast_beast(%s, %s, %s)",
                (player["player_id"], eater["beast_id"], eaten["beast_id"]),
            )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0].capitalize()) from exc

        self.screen.rows = await fetch_beasts(player["player_id"])
        still = self.screen.at_heel()
        self.screen.larder = await fetch_larder(
            player["player_id"], still["beast_id"] if still else None
        )
        self.screen.build()

        said = (
            f"**{got['eaten_name']}** goes into **{eater['name']}** "
            f"\N{EM DASH} {int(got['worth'])} nourishment."
        )
        if got["grew_to"]:
            said += f"\nIt is a **{got['stage'].title()}** now."
        if got["still_wants"] is not None:
            said += (
                f"\n{int(got['fed'])} of **{int(got['still_wants'])}** "
                "toward the next stage."
            )

        await interaction.response.edit_message(
            embed=self.screen.card(), view=self.screen
        )
        await interaction.followup.send(said, ephemeral=True)


class FeedPicker(discord.ui.Select):
    def __init__(self, screen: "PetView", rows: list[dict]) -> None:
        self.screen = screen
        self.rows = {r["ref"]: r for r in rows}
        super().__init__(
            placeholder="Feed it what?",
            row=1,
            options=[
                discord.SelectOption(
                    label=f"{r['name']} \N{MULTIPLICATION SIGN}{thousands(r['quantity'])}"[:100],
                    value=r["ref"],
                    description=f"{int(r['worth'])} nourishment each"[:100],
                    emoji=r["emoji"][:1] if r["emoji"] else None,
                )
                for r in rows
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        await interaction.response.send_modal(
            FeedAmount(self.screen, self.rows[self.values[0]])
        )


class PetView(AnsweringView):
    def __init__(self, user: discord.abc.User, rows: list[dict], who: str,
                 larder: list[dict] | None = None) -> None:
        super().__init__(timeout=300)
        self.user = user
        self.rows = rows
        self.who = who
        self.larder = larder or []
        self.build()

    def at_heel(self) -> dict | None:
        return next((r for r in self.rows if r["at_heel"]), None)

    def build(self) -> None:
        self.clear_items()
        # Discord holds 25 options; a menagerie past that picks from the
        # strongest, which is the end anybody is choosing from.
        if len(self.rows) > 1:
            self.add_item(PetPicker(self, self.rows[:25]))

        # Only for the one at heel, and only while it has somewhere left to
        # grow - an Elder is finished and the screen should say so rather than
        # offering a control that refuses.
        standing = self.at_heel()
        if standing is not None and standing["wants"] is not None:
            if self.larder:
                self.add_item(FeedPicker(self, self.larder[:25]))

            # Anything but the one doing the eating. Cheapest first, so the
            # list opens on what you are least sorry to lose.
            spare = sorted(
                (r for r in self.rows if not r["at_heel"]),
                key=lambda r: r["worth_as_food"],
            )
            if spare:
                self.add_item(RenderPicker(self, spare[:25]))

    def card(self) -> discord.Embed:
        at_heel = next((r for r in self.rows if r["at_heel"]), None)

        card = embed(
            f"\N{PAW PRINTS} {self.who}'s Beasts",
            f"**{len(self.rows)}** hatched.",
            colour=COLOUR_INFO,
        )

        if not self.rows:
            card.description = (
                "None yet. **/eggs** \N{EM DASH} anything you are holding can "
                "be hatched, and what comes out fights beside you."
            )
            return card

        if at_heel:
            grown = (
                f"\n     Fed **{int(at_heel['fed'])}** of "
                f"**{int(at_heel['wants'])}** toward the next stage"
                if at_heel["wants"] is not None
                else "\n     *Fully grown. There is nothing after Elder.*"
            )
            card.add_field(
                name="At your heel",
                value=(
                    f"{at_heel['emoji'] or ''} **{at_heel['name']}** "
                    f"\N{EM DASH} {at_heel['stage_name']}\n"
                    f"     `T{at_heel['tier']}` {at_heel['shell']} "
                    f"\N{BULLET} {at_heel['path_emoji'] or ''} "
                    f"{at_heel['path_name'] or 'no Path'} "
                    f"\N{BULLET} **{thousands(int(at_heel['attack']))}** attack\n"
                    f"     \N{BULLET} **{thousands(int(at_heel['hp']))}**/"
                    f"**{thousands(int(at_heel['max_hp']))}** health"
                    + ("\n     \N{SKULL} **Down** \N{EM DASH} it will not swing "
                       "or cover until you **/rest**."
                       if at_heel["is_down"] else "")
                    + grown
                ),
                inline=False,
            )
        else:
            card.add_field(
                name="At your heel",
                value="*Nothing. Pick one below \N{EM DASH} a beast in a pen "
                "fights nobody.*",
                inline=False,
            )

        rest = [r for r in self.rows if not r["at_heel"]]
        if rest:
            card.add_field(
                name="In the pen",
                # `fit_field` rather than a fixed slice: adding health to each
                # line pushed twelve of them past the 1024 a field holds, and
                # /pet answered 400 Invalid Form Body for anybody with a full
                # pen. A count chosen from a typical line is a guess; this
                # measures.
                value=fit_field([
                    f"{r['emoji'] or ''} **{r['name']}** `T{r['tier']}` "
                    f"{r['stage_name']} "
                    f"\N{BULLET} {thousands(int(r['attack']))} attack "
                    f"\N{BULLET} {thousands(int(r['hp']))}/{thousands(int(r['max_hp']))} hp "
                    f"• {int(r['worth_as_food'])} as food"
                    for r in rest
                ], noun="more in the pen"),
                inline=False,
            )

        card.set_footer(
            text="It swings after you in every fight \N{EM DASH} hunts, "
            "dungeons, the horde and the world boss alike, never more than a "
            "quarter of the blow it joins. Ore, beast materials, Cultivation "
            "pills and lesser beasts raise it."
        )
        return card

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message("Not your pen.", ephemeral=True)
            return False
        return True

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True


class Eggs(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @app_commands.command(description="The beast eggs you are holding.")
    async def eggs(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        rows = await fetch_eggs(player["player_id"])

        view = EggView(interaction.user, rows, interaction.user.display_name)
        if rows:
            # Deepest first: Discord holds 25 options and the deep end is what
            # anybody is choosing from.
            view.add_item(HatchPicker(view, rows[:25]))
        await interaction.response.send_message(embed=view.card(), view=view)
        view.message = await interaction.original_response()

    @app_commands.command(description="The beasts you have hatched.")
    async def pet(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        rows = await fetch_beasts(player["player_id"])

        heel = next((r for r in rows if r["at_heel"]), None)
        view = PetView(
            interaction.user, rows, interaction.user.display_name,
            await fetch_larder(
                player["player_id"], heel["beast_id"] if heel else None
            ),
        )
        await interaction.response.send_message(embed=view.card(), view=view)
        view.message = await interaction.original_response()


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Eggs(bot))
