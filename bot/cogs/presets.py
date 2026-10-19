"""Named sets of equipment: /preset.

Four things a cultivator wears and every one is set one piece at a time - Gu
in the aperture, two manuals, four pieces of gear, the technique loadout.
Somebody who farms with Gathering Yield and fights a beast with Attack Power
rebuilds the whole set by hand twice a session across three screens.

A preset is a snapshot of all four under a name, and putting it back on is one
press. Nothing about what may be worn changes: `load_preset` empties the
aperture before it fills it, and `enforce_gu_capacity` still refuses a Gu that
will not fit - it just says which one instead of failing the whole change.

The screen shows how much of each set is still in hand, because a preset is a
list of specific items and items get sold.
"""

import discord
import psycopg
from discord import app_commands
from discord.ext import commands

from bot import database as db
from bot.formatting import COLOUR_BAD, COLOUR_DEFAULT, COLOUR_GOOD, COLOUR_INFO, embed
from bot.players import GameError, require_player
from bot.views import AnsweringView

GU = "\N{BUG}"
BOOK = "\N{OPEN BOOK}"
GEAR = "\N{CROSSED SWORDS}"
MOVE = "\N{HIGH VOLTAGE SIGN}"


def refuse(exc: psycopg.errors.CheckViolation) -> GameError:
    said = str(exc).splitlines()[0]
    return GameError(said[:1].upper() + said[1:])


async def fetch_presets(player_id: int) -> list[dict]:
    return await db.fetch_all(
        "SELECT * FROM preset_shelf WHERE player_id = %s "
        "ORDER BY updated_at DESC, name",
        (player_id,),
    )


def part(emoji: str, held: int, saved: int) -> str:
    """One quarter of a set, and whether all of it is still owned.

    A preset that has lost a piece says so on the line rather than at load
    time, so somebody choosing between two sets can see which one is whole.
    """
    if saved == 0:
        return f"{emoji} \N{EN DASH}"
    if held < saved:
        return f"{emoji} **{held}**/{saved}"
    return f"{emoji} {saved}"


def preset_line(row: dict) -> str:
    pieces = " \N{BULLET} ".join(
        (
            part(GU, row["gu_held"], row["gu_saved"]),
            part(BOOK, row["manuals_held"], row["manuals_saved"]),
            part(GEAR, row["gear_held"], row["gear_saved"]),
            part(MOVE, row["techniques_held"], row["techniques_saved"]),
        )
    )
    saved = (
        row["gu_saved"] + row["manuals_saved"]
        + row["gear_saved"] + row["techniques_saved"]
    )
    held = (
        row["gu_held"] + row["manuals_held"]
        + row["gear_held"] + row["techniques_held"]
    )
    gone = saved - held
    tail = f"\n\N{IDEOGRAPHIC SPACE}*{gone} piece(s) no longer yours*" if gone else ""
    return f"**{row['name']}**\n\N{IDEOGRAPHIC SPACE}{pieces}{tail}"


def render(rows: list[dict]) -> discord.Embed:
    card = embed(
        "\N{CLIPBOARD} Your sets",
        "A set is everything you are wearing at once \N{EM DASH} Gu, manuals, "
        "gear and techniques \N{EM DASH} saved under a name. Put one back on "
        "and all four change together.\n\n"
        "*Save over a name to keep that set current.*",
        colour=COLOUR_INFO if rows else COLOUR_DEFAULT,
    )
    if not rows:
        card.add_field(
            name="Nothing saved yet",
            value="Wear what you want to keep, then **/preset save** it under "
            "a name like `farming` or `bossing`.\n\n"
            f"{GU} Gu \N{BULLET} {BOOK} manuals \N{BULLET} {GEAR} gear "
            f"\N{BULLET} {MOVE} techniques",
            inline=False,
        )
        return card

    card.add_field(
        name=f"Saved ({len(rows)})",
        value="\n\n".join(preset_line(row) for row in rows),
        inline=False,
    )
    card.set_footer(text=f"{GU} Gu  {BOOK} manuals  {GEAR} gear  {MOVE} techniques")
    return card


def worn_card(done: dict) -> discord.Embed:
    """What actually went on. The refusals are the point of this screen."""
    card = embed(
        f"\N{CLIPBOARD} {done['name']}",
        "You are wearing it.",
        colour=COLOUR_GOOD if not done["missing"] else COLOUR_BAD,
    )
    card.add_field(
        name="On you now",
        value=(
            f"{GU} **{done['gu_worn']}** Gu \N{BULLET} "
            f"{BOOK} **{done['manuals_worn']}** manual(s) \N{BULLET} "
            f"{GEAR} **{done['gear_worn']}** piece(s) \N{BULLET} "
            f"{MOVE} **{done['techniques_set']}** technique(s)"
        ),
        inline=False,
    )
    if done["missing"]:
        why = done["refused"] or "sold, traded or no longer yours"
        card.add_field(
            name=f"Left out ({done['missing']})",
            value=f"{why}.\n\n*Save the set again to forget them.*",
            inline=False,
        )
    return card


class PresetSelect(discord.ui.Select):
    def __init__(self, screen: "Shelf", rows: list[dict], mode: str) -> None:
        self.screen = screen
        self.mode = mode
        self.rows = {str(r["preset_id"]): r for r in rows}
        super().__init__(
            placeholder="Wear one\N{HORIZONTAL ELLIPSIS}"
            if mode == "wear"
            else "Forget one\N{HORIZONTAL ELLIPSIS}",
            row=0 if mode == "wear" else 1,
            options=[
                discord.SelectOption(
                    label=r["name"][:100],
                    value=str(r["preset_id"]),
                    description=(
                        f"{r['gu_held']} Gu \N{BULLET} {r['manuals_held']} manual(s) "
                        f"\N{BULLET} {r['gear_held']} gear \N{BULLET} "
                        f"{r['techniques_held']} technique(s)"
                    )[:100],
                )
                for r in rows
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        row = self.rows[self.values[0]]

        if self.mode == "forget":
            try:
                await db.fetch_one(
                    "SELECT delete_preset(%s, %s) AS name",
                    (self.screen.player_id, row["preset_id"]),
                )
            except psycopg.errors.CheckViolation as exc:
                raise refuse(exc) from exc
            await self.screen.redraw(interaction)
            return

        # DEFER FIRST. Discord gives three seconds to make the FIRST response
        # to an interaction and then voids the token; `load_preset` takes four
        # to six seconds for a cultivator who has ascended, so the edit below
        # always arrived at a dead token. Error 10062, "Unknown interaction" -
        # the preset DID go on, because the database work had already
        # committed, and the screen never changed and the player was told the
        # interaction failed. Indistinguishable, from their side, from a preset
        # that does not work.
        #
        # `defer()` with no `thinking` acknowledges the component and leaves
        # the message alone, so `edit_original_response` below still edits the
        # screen in place the way `edit_message` did. `answer_error` already
        # branches on `is_done()`, so a refusal still reaches the player.
        await interaction.response.defer()

        try:
            done = await db.fetch_one(
                "SELECT * FROM load_preset(%s, %s)",
                (self.screen.player_id, row["preset_id"]),
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        for item in self.screen.children:
            item.disabled = True
        self.screen.stop()
        await interaction.edit_original_response(
            embed=worn_card(done), view=self.screen
        )


class Shelf(AnsweringView):
    def __init__(self, player_id: int, user: discord.abc.User, rows: list[dict]) -> None:
        super().__init__(timeout=300)
        self.player_id = player_id
        self.user = user
        self.rows = rows
        self.build()

    def card(self) -> discord.Embed:
        return render(self.rows)

    def build(self) -> None:
        self.clear_items()
        if self.rows:
            self.add_item(PresetSelect(self, self.rows[:25], "wear"))
            self.add_item(PresetSelect(self, self.rows[:25], "forget"))

    async def redraw(self, interaction: discord.Interaction) -> None:
        self.rows = await fetch_presets(self.player_id)
        self.build()
        await interaction.response.edit_message(embed=self.card(), view=self)

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "Those are not your sets.", ephemeral=True
            )
            return False
        return True

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True


class Presets(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    preset = app_commands.Group(
        name="preset",
        description="Save what you are wearing, and put it back on in one press.",
    )

    @preset.command(description="Your saved sets, to wear or to forget.")
    async def list(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        rows = await fetch_presets(player["player_id"])
        view = Shelf(player["player_id"], interaction.user, rows)
        await interaction.response.send_message(embed=view.card(), view=view)

    @preset.command(description="Save everything you are wearing under a name.")
    @app_commands.describe(name="What to call it - farming, bossing, cultivating.")
    async def save(self, interaction: discord.Interaction, name: str) -> None:
        player = await require_player(interaction.user)
        try:
            done = await db.fetch_one(
                "SELECT * FROM save_preset(%s, %s)", (player["player_id"], name)
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        total = done["gu"] + done["manuals"] + done["gear"] + done["techniques"]
        card = embed(
            f"\N{CLIPBOARD} {done['name']}",
            "Saved over what was there." if done["replaced"] else "Saved.",
            colour=COLOUR_GOOD if total else COLOUR_BAD,
        )
        if total:
            card.add_field(
                name="What is in it",
                value=(
                    f"{GU} **{done['gu']}** Gu \N{BULLET} "
                    f"{BOOK} **{done['manuals']}** manual(s) \N{BULLET} "
                    f"{GEAR} **{done['gear']}** piece(s) \N{BULLET} "
                    f"{MOVE} **{done['techniques']}** technique(s)"
                ),
                inline=False,
            )
            card.set_footer(text="/preset list to put it back on")
        else:
            card.add_field(
                name="You are wearing nothing",
                value="An empty set is saved, but it will strip you when you "
                "wear it. Equip something first and save over the name.",
                inline=False,
            )
        await interaction.response.send_message(embed=card)


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Presets(bot))
