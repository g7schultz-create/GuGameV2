"""Character creation: /register, and the screen it opens.

Three traits, two of them rolled. The interesting design constraint is that a
bad first roll must not be a dead character, so the Root and the Physique each
come with a configured number of rerolls and the Race is chosen outright.

All of the in-progress state lives in `player_character` with `confirmed_at`
NULL, not in this view's memory. A Discord view dies on timeout and on every
restart; a half-made character surviving either of those is the difference
between "run /register again" and "your roll is gone".
"""

import discord
from discord import app_commands
from discord.ext import commands

from bot import database as db
from bot.character import (
    fetch_character,
    fetch_foundation,
    fetch_path_bonuses,
    fetch_trait_effects,
    mark,
    render_character,
)
from bot.formatting import COLOUR_GOOD, embed, thousands
from bot.views import AnsweringModal, AnsweringView
from bot.players import GameError, create_player, require_player

VIEW_TIMEOUT = 600


async def build_sheet(
    player_id: int, user: discord.abc.User
) -> tuple[discord.Embed, dict]:
    char = await fetch_character(player_id)
    if char is None:
        raise GameError("You have no character. Use **/register**.")
    bonuses = await fetch_path_bonuses(player_id)
    foundation = await fetch_foundation(player_id)
    effects = await fetch_trait_effects(player_id)
    card = render_character(
        char,
        bonuses,
        foundation,
        effects,
        display_name=user.display_name,
        avatar_url=user.display_avatar.url,
    )
    return card, char


class NameModal(AnsweringModal, title="Name your character"):
    character_name = discord.ui.TextInput(
        label="Name",
        placeholder="The name you will be known by",
        max_length=32,
        required=True,
    )

    def __init__(self, sheet: "CharacterSetup") -> None:
        super().__init__()
        self.sheet = sheet

    async def on_submit(self, interaction: discord.Interaction) -> None:
        await db.execute(
            "UPDATE player_character SET character_name = %s WHERE player_id = %s",
            (str(self.character_name).strip(), self.sheet.player_id),
        )
        await self.sheet.refresh(interaction)


class RaceSelect(discord.ui.Select):
    """Race is chosen rather than rolled - the one trait a player states about
    their character instead of receiving."""

    def __init__(self, sheet: "CharacterSetup", races: list[dict], current: str) -> None:
        self.sheet = sheet
        super().__init__(
            placeholder="Choose your race",
            row=1,
            options=[
                discord.SelectOption(
                    label=race["name"],
                    value=race["code"],
                    description=f"{race['specialty']} — {race['description'][:80]}",
                    default=race["code"] == current,
                )
                for race in races
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        await db.execute(
            "UPDATE player_character SET race_code = %s WHERE player_id = %s",
            (self.values[0], self.sheet.player_id),
        )
        await self.sheet.refresh(interaction)


class CharacterSetup(AnsweringView):
    def __init__(self, player_id: int, user: discord.abc.User, races: list[dict], race: str) -> None:
        super().__init__(timeout=VIEW_TIMEOUT)
        self.player_id = player_id
        self.user = user
        self.message: discord.Message | None = None
        self.add_item(RaceSelect(self, races, race))

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        """Somebody else's character setup is not yours to reroll."""
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "That is not your character.", ephemeral=True
            )
            return False
        return True

    async def on_timeout(self) -> None:
        # The character is safe in the database; only the buttons expire.
        for item in self.children:
            item.disabled = True
        if self.message:
            try:
                await self.message.edit(view=self)
            except discord.HTTPException:
                pass

    async def refresh(self, interaction: discord.Interaction) -> None:
        card, char = await build_sheet(self.player_id, self.user)
        self.sync_labels(char)
        await interaction.response.edit_message(embed=card, view=self)

    def sync_labels(self, char: dict) -> None:
        """Keep the reroll counts on the buttons honest."""
        for item in self.children:
            if getattr(item, "custom_id", None) == "reroll_root":
                left = char["root_rerolls_left"]
                item.label = f"Reroll Root ({left} left)"
                item.disabled = left <= 0
            elif getattr(item, "custom_id", None) == "reroll_physique":
                left = char["physique_rerolls_left"]
                item.label = f"Reroll Physique ({left} left)"
                item.disabled = left <= 0

    # -----------------------------------------------------------------------

    @discord.ui.button(label="Set Name", style=discord.ButtonStyle.secondary, row=0)
    async def set_name(self, interaction: discord.Interaction, button: discord.ui.Button) -> None:
        await interaction.response.send_modal(NameModal(self))

    @discord.ui.button(
        label="Reroll Root",
        style=discord.ButtonStyle.secondary,
        row=0,
        custom_id="reroll_root",
    )
    async def reroll_root(self, interaction: discord.Interaction, button: discord.ui.Button) -> None:
        # The decrement and the reroll are one statement, so a double-click
        # cannot spend one reroll and take two rolls.
        rolled = await db.fetch_one(
            """
            UPDATE player_character
            SET root_code         = roll_root(),
                root_rerolls_left = root_rerolls_left - 1,
                root_rolls        = root_rolls + 1
            WHERE player_id = %s AND root_rerolls_left > 0
            RETURNING root_code
            """,
            (self.player_id,),
        )
        if rolled is None:
            raise GameError("You have no rerolls left for your Root.")
        await self.refresh(interaction)

    @discord.ui.button(
        label="Reroll Physique",
        style=discord.ButtonStyle.secondary,
        row=0,
        custom_id="reroll_physique",
    )
    async def reroll_physique(self, interaction: discord.Interaction, button: discord.ui.Button) -> None:
        async with db.pool().connection() as conn:
            spent = await (
                await conn.execute(
                    """
                    UPDATE player_character
                    SET physique_rerolls_left = physique_rerolls_left - 1,
                        physique_rolls        = physique_rolls + 1
                    WHERE player_id = %s AND physique_rerolls_left > 0
                    RETURNING physique_rolls
                    """,
                    (self.player_id,),
                )
            ).fetchone()
            if spent is None:
                raise GameError("You have no rerolls left for your Physique.")
            # The body lives on player_physique, so the roll lands there.
            await conn.execute(
                "UPDATE player_physique SET physique_id = roll_physique() WHERE player_id = %s",
                (self.player_id,),
            )
            # Stats are a function of body level and physique, so they have to
            # be recomputed the moment the physique changes.
            await conn.execute("SELECT apply_physique_xp(%s, 0)", (self.player_id,))

        await self.refresh(interaction)

    @discord.ui.button(label="Confirm", style=discord.ButtonStyle.success, row=0)
    async def confirm(self, interaction: discord.Interaction, button: discord.ui.Button) -> None:
        confirmed = await db.fetch_one(
            """
            UPDATE player_character
            SET confirmed_at = now()
            WHERE player_id = %s AND confirmed_at IS NULL
            RETURNING root_code
            """,
            (self.player_id,),
        )
        if confirmed is None:
            raise GameError("This character is already confirmed.")

        # Cultivation starts at the moment of commitment, not at the moment
        # the row was created - otherwise a long deliberation pays out.
        await db.execute(
            "UPDATE player_cultivation SET last_tick_at = now() WHERE player_id = %s",
            (self.player_id,),
        )

        for item in self.children:
            item.disabled = True
        card, _ = await build_sheet(self.player_id, self.user)
        await interaction.response.edit_message(embed=card, view=self)
        self.stop()

        # Confirming is what grants the starter manual - a trigger on
        # `confirmed_at` - so it has already happened by the time this reads it.
        opening = embed(
            "Your cultivation has begun",
            "It accrues on its own from here — **/profile** to watch the bar fill. "
            "Set a **/focus** Path to trade a little speed for insight.",
            colour=COLOUR_GOOD,
        )
        starter = await db.fetch_one(
            """
            SELECT m.name, string_agg(DISTINCT p.name, ' / ') AS paths,
                   string_agg(DISTINCT t.name, ', ') AS teaches
            FROM player_manual_slots s
            JOIN manuals m ON m.manual_id = s.manual_id
            LEFT JOIN manual_paths mp ON mp.manual_id = m.manual_id
            LEFT JOIN paths p ON p.code = mp.path_code
            LEFT JOIN manual_techniques mt ON mt.manual_id = m.manual_id
            LEFT JOIN techniques t ON t.technique_id = mt.technique_id
            WHERE s.player_id = %s AND m.created_by = %s AND m.harmony IS NULL
            GROUP BY m.manual_id, m.name
            """,
            (self.player_id, self.player_id),
        )
        if starter:
            opening.add_field(
                name="\N{GRADUATION CAP} You were handed a manual",
                value=f"**{starter['name']}** — Tier 1, {starter['paths']}\n"
                f"It teaches **{starter['teaches']}**, which is enough to kill "
                "something small. **/hunt** to try it; **/equipment** to see "
                "what carrying it is worth.",
                inline=False,
            )

        # The same trigger hands over the purse, and a purse nobody is told
        # about buys nothing. Read rather than hardcoded: the amount is a
        # config dial, and a number written twice is a number that drifts.
        purse = await db.fetch_one(
            """
            SELECT pm.quantity,
                   (SELECT s.stone_cost FROM technique_shelf(%s) s
                    WHERE NOT s.known AND s.realm_ok AND s.tier_ok
                      AND s.grade <> 'advanced'
                    ORDER BY s.stone_cost LIMIT 1) AS cheapest
            FROM player_materials pm
            WHERE pm.player_id = %s AND pm.material_code = 'spirit_stone'
            """,
            (self.player_id, self.player_id),
        )
        if purse and purse["quantity"]:
            opening.add_field(
                name="\N{MONEY BAG} And a purse to choose with",
                value=f"**{thousands(purse['quantity'])}** spirit stones. "
                "**/techniques** is the shelf and **/learn** buys from it — "
                f"the cheapest move you can take today runs "
                f"**{thousands(purse['cheapest'] or 0)}**, so your second "
                "technique is a decision today rather than a week from now.",
                inline=False,
            )
        await interaction.followup.send(embed=opening, ephemeral=True)


class Character(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @app_commands.command(description="Begin cultivating. Rolls your Root and Physique.")
    async def register(self, interaction: discord.Interaction) -> None:
        player = await create_player(interaction.user)
        races = await db.fetch_all(
            "SELECT code, name, specialty, description FROM races "
            "WHERE playable ORDER BY sort_order"
        )
        card, char = await build_sheet(player["player_id"], interaction.user)

        view = CharacterSetup(
            player["player_id"], interaction.user, races, char["race_code"]
        )
        view.sync_labels(char)
        await interaction.response.send_message(embed=card, view=view)
        view.message = await interaction.original_response()

    # -----------------------------------------------------------------------

    @app_commands.command(description="Look up a Race, Root or Physique.")
    @app_commands.describe(kind="Which list to read.")
    @app_commands.choices(
        kind=[
            app_commands.Choice(name="Races", value="races"),
            app_commands.Choice(name="Roots", value="roots"),
            app_commands.Choice(name="Physiques", value="physiques"),
        ]
    )
    async def traits(
        self, interaction: discord.Interaction, kind: app_commands.Choice[str]
    ) -> None:
        """What can be rolled, and how likely each band is.

        Publishing the odds is deliberate. A roll nobody can check is a roll
        players assume is rigged.
        """
        if kind.value == "races":
            rows = await db.fetch_all(
                "SELECT name, specialty, description FROM races WHERE playable "
                "ORDER BY sort_order"
            )
            body = "\n".join(
                f"**{r['name']}** ({r['specialty']}) — {r['description']}" for r in rows
            )
            card = embed("Races", body)
            card.set_footer(text="Race is chosen at creation, not rolled.")
        elif kind.value == "roots":
            rows = await db.fetch_all(
                """
                SELECT ra.code AS rarity, ra.name AS rarity_name, ra.roll_weight,
                       string_agg(ro.name, ', ' ORDER BY ro.sort_order) AS members
                FROM roots ro
                JOIN rarities ra ON ra.code = ro.rarity
                WHERE NOT EXISTS (SELECT 1 FROM roots e WHERE e.evolves_into = ro.code)
                GROUP BY ra.code, ra.name, ra.roll_weight, ra.sort_order
                ORDER BY ra.sort_order
                """
            )
            card = embed("Roots", "Rolled at creation. Rerollable twice.")
            for row in rows:
                card.add_field(
                    name=f"{mark(row['rarity'])} {row['rarity_name']} — {row['roll_weight']}%",
                    value=row["members"],
                    inline=False,
                )
        else:
            rows = await db.fetch_all(
                """
                SELECT ra.code AS rarity, ra.name AS rarity_name, ra.roll_weight,
                       string_agg(p.name, ', ' ORDER BY p.name) AS members
                FROM physiques p
                JOIN rarities ra ON ra.code = p.tier
                WHERE p.rollable
                GROUP BY ra.code, ra.name, ra.roll_weight, ra.sort_order
                ORDER BY ra.sort_order
                """
            )
            card = embed("Physiques", "Rolled at creation. Rerollable twice.")
            for row in rows:
                card.add_field(
                    name=f"{mark(row['rarity'])} {row['rarity_name']} — {row['roll_weight']}%",
                    value=row["members"],
                    inline=False,
                )
            card.set_footer(
                text="Bands with no members redistribute — the listed weights are "
                "relative, and the effective odds follow what exists."
            )

        await interaction.response.send_message(embed=card)

    # -----------------------------------------------------------------------

    @app_commands.command(description="Rename your character.")
    @app_commands.describe(name="The name you will be known by.")
    async def rename(
        self, interaction: discord.Interaction, name: app_commands.Range[str, 1, 32]
    ) -> None:
        player = await require_player(interaction.user)
        await db.execute(
            "UPDATE player_character SET character_name = %s WHERE player_id = %s",
            (name.strip(), player["player_id"]),
        )
        await interaction.response.send_message(
            embed=embed("Renamed", f"You are known as **{name.strip()}**.", colour=COLOUR_GOOD)
        )


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Character(bot))
