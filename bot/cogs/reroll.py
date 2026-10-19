"""Buying more chances: /reroll.

Pick the trait, pick the band you would stop at, then roll one, ten or a
hundred times. A batch stops the instant it meets the target — or when the
purse runs dry — and hands back an OFFER. Nothing changes until you take it.

Refusing costs the Jade anyway: it bought the look, and the look happened.
That is what you are buying, and it is why a roll is not a purchase.

The odds are published on the screen because they are real. `reroll_odds` is a
view over the same `rarities.roll_weight` the roll itself uses, so the chance
shown and the chance taken cannot drift apart.

Race is not here as a gamble. 0011 settled that a race is chosen rather than
received, so changing one is a flat fee for a service.
"""

import discord
import psycopg
from discord import app_commands
from discord.ext import commands

from bot import database as db
from bot.character import RARITY_MARK
from bot.formatting import (
    COLOUR_BAD,
    COLOUR_GOOD,
    COLOUR_INFO,
    embed,
    error_embed,
    percent,
    thousands,
)
from bot.views import AnsweringView, answer_error
from bot.players import GameError, require_player, settle_passive

JADE = "\N{GREEN HEART}"
BATCHES = (1, 10, 100)


async def fetch_odds(trait: str) -> list[dict]:
    return await db.fetch_all(
        """
        SELECT o.*, ra.name AS band_name,
               o.expected_rolls * game_config_value('reroll_jade_cost') AS jade
        FROM reroll_odds o
        JOIN rarities ra ON ra.code = o.rarity
        WHERE o.trait = %s
        ORDER BY o.sort_order
        """,
        (trait,),
    )


async def fetch_offer(player_id: int, trait: str) -> dict | None:
    """The standing offer, if there is one.

    Read every time the screen draws rather than carried on the view: it is a
    row precisely so that a restart cannot lose it, and reading it from
    anywhere else would give that back.
    """
    return await db.fetch_one(
        """
        SELECT o.trait, o.rolls_made, o.jade_spent,
               o.root_code AS code, o.physique_id,
               COALESCE(r.name, p.name)  AS name,
               COALESCE(r.rarity, p.tier) AS rarity,
               COALESCE(r.description, p.description) AS text
        FROM player_reroll_offers o
        LEFT JOIN roots r ON r.code = o.root_code
        LEFT JOIN physiques p ON p.physique_id = o.physique_id
        WHERE o.player_id = %s AND o.trait = %s
        """,
        (player_id, trait),
    )


async def fetch_current(player_id: int) -> dict:
    return await db.fetch_one(
        """
        SELECT ro.code AS root_code, ro.name AS root_name, ro.rarity AS root_rarity,
               ro.description AS root_text,
               p.physique_id, p.name AS physique_name, p.tier AS physique_rarity,
               p.description AS physique_text,
               ra.name AS race_name, pc.race_code,
               pc.root_rolls, pc.physique_rolls,
               jade_held(pc.player_id) AS jade
        FROM player_character pc
        JOIN roots ro ON ro.code = pc.root_code
        JOIN races ra ON ra.code = pc.race_code
        LEFT JOIN player_physique pp ON pp.player_id = pc.player_id
        LEFT JOIN physiques p ON p.physique_id = pp.physique_id
        WHERE pc.player_id = %s
        """,
        (player_id,),
    )


async def fetch_grants(trait: str, key) -> list[dict]:
    """What one root or one body is worth.

    Keyed by the trait rather than by who holds it, which is the whole reason
    0144 exists: an offer is a candidate nobody holds yet, so the character
    sheet's player-keyed query had nothing to ask about it.
    """
    if key is None:
        return []
    if trait == "root":
        return await db.fetch_all("SELECT * FROM root_grants(%s)", (key,))
    return await db.fetch_all("SELECT * FROM physique_grants(%s)", (key,))


def grant_lines(rows: list[dict]) -> str:
    """One line each, and the tempering ceiling written as a count rather than
    a percentage - "Tempers to body rank 4" is not four per cent of anything.
    """
    if not rows:
        return "*Grants nothing.*"
    return "\n".join(
        f"{row['emoji']} {row['name']}"
        + ("" if row["kind"] == "ceiling" else f": {percent(row['magnitude'])}")
        for row in rows
    )


def compare(now: list[dict], offer: list[dict]) -> str:
    """What the swap would actually cost and buy, effect by effect.

    A rarer band is not the same as a better trait for what a player is
    building - an Epic root full of Water is a downgrade for a Fire cultivator,
    and the rarity line on its own would never say so.
    """
    held = {row["name"]: row["magnitude"] for row in now}
    take = {row["name"]: row["magnitude"] for row in offer}

    gains, losses = [], []
    for name in sorted(set(held) | set(take)):
        before, after = held.get(name, 0), take.get(name, 0)
        if after == before:
            continue
        row = next(r for r in (offer + now) if r["name"] == name)
        moved = f"{row['emoji']} {name}"
        if row["kind"] != "ceiling":
            moved += f": {percent(before)} \N{RIGHTWARDS ARROW} {percent(after)}"
        (gains if after > before else losses).append(moved)

    if not gains and not losses:
        return "*The same, effect for effect.*"
    out = []
    if gains:
        out.append("**Gains**\n" + "\n".join(gains))
    if losses:
        out.append("**Loses**\n" + "\n".join(losses))
    return "\n\n".join(out)


async def render(screen: "RerollView") -> discord.Embed:
    now = await fetch_current(screen.player_id)
    cost = await db.fetch_value("SELECT game_config_value('reroll_jade_cost')")
    fee = await db.fetch_value("SELECT game_config_value('race_change_jade_cost')")

    card = embed(
        "\N{GEM STONE} Rerolling",
        "Pick a trait and the band you would stop at, then roll. A batch stops "
        "the moment it meets your target **or anything rarer** — and stops if "
        "the purse runs dry.\n\n"
        "**Nothing changes until you accept it.** A batch keeps the best it "
        "saw and offers it — you decide. Refusing still costs the Jade: it "
        "bought the look.",
        colour=COLOUR_INFO,
    )
    card.add_field(
        name=f"{JADE} Spirit Jade",
        value=f"**{thousands(now['jade'])}** \N{BULLET} {int(cost)} a roll",
        inline=False,
    )

    if screen.trait == "race":
        card.add_field(
            name="\N{BUST IN SILHOUETTE} Race",
            value=f"**{now['race_name']}**\n"
            f"A race is chosen, not rolled — so this is a flat "
            f"{JADE} **{int(fee)}** to change, not a gamble.",
            inline=False,
        )
        return card

    holding = await fetch_grants(
        screen.trait,
        now["root_code"] if screen.trait == "root" else now["physique_id"],
    )
    if screen.trait == "root":
        card.add_field(
            name="\N{SEEDLING} Current Root",
            value=f"{RARITY_MARK.get(now['root_rarity'], '')} **{now['root_name']}** "
            f"({now['root_rarity'].title()})\n*{now['root_text']}*\n"
            f"Rolled {now['root_rolls']} time(s).\n\n"
            + grant_lines(holding),
            inline=False,
        )
    else:
        card.add_field(
            name="\N{FLEXED BICEPS} Current Physique",
            value=f"{RARITY_MARK.get(now['physique_rarity'], '')} "
            f"**{now['physique_name']}** ({now['physique_rarity'].title()})\n"
            f"*{now['physique_text']}*\nRolled {now['physique_rolls']} time(s).\n\n"
            + grant_lines(holding),
            inline=False,
        )

    odds = await fetch_odds(screen.trait)
    target = next((o for o in odds if o["rarity"] == screen.target), None)
    if target is not None:
        card.add_field(
            name=f"Stopping at {target['band_name']} or rarer",
            value=(
                f"{percent(target['or_better'], signed=False)} a roll \N{BULLET} "
                f"about **{target['expected_rolls']}** rolls \N{BULLET} "
                f"{JADE} **{thousands(target['jade'])}** on average"
            ),
            inline=False,
        )
    card.add_field(
        name="The whole ladder",
        value="\n".join(
            f"{RARITY_MARK.get(o['rarity'], '')} {o['band_name']} or rarer "
            f"\N{BULLET} {percent(o['or_better'], signed=False)} "
            f"\N{BULLET} {JADE} {thousands(o['jade'])}"
            for o in odds
            if o["or_better"] < 1
        ),
        inline=False,
    )
    offer = await fetch_offer(screen.player_id, screen.trait)
    if offer is not None:
        held = (
            now["root_rarity"] if screen.trait == "root" else now["physique_rarity"]
        )
        better = await db.fetch_value(
            """
            SELECT (SELECT sort_order FROM rarities WHERE code = %s)
                 > (SELECT sort_order FROM rarities WHERE code = %s)
            """,
            (offer["rarity"], held),
        )
        offered = await fetch_grants(
            screen.trait,
            offer["code"] if screen.trait == "root" else offer["physique_id"],
        )
        card.add_field(
            name="💎 On offer",
            value=(
                f"{RARITY_MARK.get(offer['rarity'], '')} **{offer['name']}** "
                f"({offer['rarity'].title()})\n*{offer['text']}*\n"
                + ("**Rarer than what you hold.**" if better
                   else "*Not rarer than what you hold.*")
                + f"\n{offer['rolls_made']} roll(s), {JADE} "
                f"{thousands(offer['jade_spent'])} spent looking.\n\n"
                + grant_lines(offered)
            ),
            inline=False,
        )
        # The rarity line says which band it came out of. This says whether it
        # is the trait you want, which is a different question and the one the
        # Jade is actually buying an answer to.
        card.add_field(
            name="\N{LEFT RIGHT ARROW} If you take it",
            value=compare(holding, offered),
            inline=False,
        )

    card.set_footer(
        text="These are the same weights the roll uses — not an estimate. "
        "An average is not a promise."
    )
    return card


class TraitSelect(discord.ui.Select):
    def __init__(self, screen: "RerollView") -> None:
        self.screen = screen
        super().__init__(
            placeholder="Root",
            options=[
                discord.SelectOption(
                    label="Root", value="root", emoji="\N{SEEDLING}",
                    description="Rolled. Path packages and craft effects.",
                    default=screen.trait == "root",
                ),
                discord.SelectOption(
                    label="Physique", value="physique", emoji="\N{FLEXED BICEPS}",
                    description="Rolled. Body multipliers and effects.",
                    default=screen.trait == "physique",
                ),
                discord.SelectOption(
                    label="Race", value="race", emoji="\N{BUST IN SILHOUETTE}",
                    description="Chosen, not rolled — a flat fee.",
                    default=screen.trait == "race",
                ),
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        self.screen.trait = self.values[0]
        # A physique can roll Extreme and a root cannot, so a target carried
        # across from the other trait may not exist in this one's ladder.
        await self.screen.retarget()
        await self.screen.refresh(interaction)


class TargetSelect(discord.ui.Select):
    def __init__(self, screen: "RerollView", odds: list[dict]) -> None:
        self.screen = screen
        super().__init__(
            placeholder="Stop at…",
            options=[
                discord.SelectOption(
                    label=o["band_name"],
                    value=o["rarity"],
                    description=(
                        f"{float(o['or_better']) * 100:.2f}% a roll "
                        f"\N{BULLET} about {o['expected_rolls']} rolls"
                    )[:100],
                    emoji=RARITY_MARK.get(o["rarity"]),
                    default=o["rarity"] == screen.target,
                )
                for o in odds if o["or_better"] < 1
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        self.screen.target = self.values[0]
        await self.screen.refresh(interaction)


class RaceSelect(discord.ui.Select):
    def __init__(self, screen: "RerollView", races: list[dict]) -> None:
        self.screen = screen
        super().__init__(
            placeholder="Become…",
            options=[
                discord.SelectOption(
                    label=r["name"], value=r["code"],
                    description=str(r["specialty"])[:100],
                )
                for r in races[:25]
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        try:
            done = await db.fetch_one(
                "SELECT * FROM change_race(%s, %s)",
                (self.screen.player_id, self.values[0]),
            )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0].capitalize()) from exc

        card = embed(
            f"\N{BUST IN SILHOUETTE} {done['race_name']}",
            f"Changed for {JADE} **{thousands(done['spent'])}** Spirit Jade.",
            colour=COLOUR_GOOD,
        )
        card.add_field(name="Left", value=f"{JADE} {thousands(done['jade_left'])}")
        await interaction.response.edit_message(embed=card, view=self.screen)


class RollButton(discord.ui.Button):
    def __init__(self, screen: "RerollView", count: int) -> None:
        self.screen = screen
        self.count = count
        super().__init__(
            label=f"Roll {count}",
            style=discord.ButtonStyle.primary if count == 1 else discord.ButtonStyle.secondary,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        screen = self.screen
        function = "reroll_root" if screen.trait == "root" else "reroll_physique"
        try:
            done = await db.fetch_one(
                f"SELECT * FROM {function}(%s, %s, %s)",
                (screen.player_id, screen.target, self.count),
            )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0].capitalize()) from exc

        if done["rolls_made"] == 0:
            raise GameError(
                "Not enough Spirit Jade for even one roll. It comes from "
                "breaking through a realm, killing something new, and trade."
            )
        await screen.refresh(interaction)


class DecideButton(discord.ui.Button):
    """Take the offer, or refuse it. Nothing has changed until this is pressed."""

    def __init__(self, screen: "RerollView", take: bool) -> None:
        self.screen = screen
        self.take = take
        super().__init__(
            label="Take the new one" if take else "Keep what I have",
            style=discord.ButtonStyle.success if take else discord.ButtonStyle.secondary,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        screen = self.screen
        try:
            if self.take:
                done = await db.fetch_one(
                    "SELECT * FROM reroll_take(%s, %s)", (screen.player_id, screen.trait)
                )
                card = embed(
                    f"{RARITY_MARK.get(done['rarity'], '')} {done['name']}",
                    f"Taken. **{done['rarity'].title()}** — it is yours now.",
                    colour=COLOUR_GOOD,
                )
            else:
                await db.execute(
                    "SELECT reroll_discard(%s, %s)", (screen.player_id, screen.trait)
                )
                card = embed(
                    "Refused",
                    "You keep what you had. The Jade is not returned — it bought "
                    "the look, and the look happened.",
                    colour=COLOUR_INFO,
                )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0].capitalize()) from exc

        await screen.refresh(interaction, card)


class RerollView(AnsweringView):
    def __init__(self, player_id: int, user: discord.abc.User,
                 odds: list[dict], races: list[dict]) -> None:
        super().__init__(timeout=600)
        self.player_id = player_id
        self.user = user
        self.odds = odds
        self.races = races
        self.trait = "root"
        self.target = "legendary"
        self.offer: dict | None = None
        self.build()

    def build(self) -> None:
        self.clear_items()
        self.add_item(TraitSelect(self))
        if self.trait == "race":
            self.add_item(RaceSelect(self, self.races))
            return
        self.add_item(TargetSelect(self, self.odds))
        for count in BATCHES:
            self.add_item(RollButton(self, count))
        # Rolling again can only improve a standing offer, so the roll buttons
        # stay live beside the decision rather than being taken away.
        if self.offer is not None:
            self.add_item(DecideButton(self, take=True))
            self.add_item(DecideButton(self, take=False))

    async def retarget(self) -> None:
        self.odds = await fetch_odds(self.trait if self.trait != "race" else "root")
        if not any(o["rarity"] == self.target for o in self.odds):
            self.target = "legendary"

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "Roll your own dice.", ephemeral=True
            )
            return False
        return True

    async def refresh(self, interaction: discord.Interaction,
                      card: discord.Embed | None = None) -> None:
        # The offer is re-read rather than remembered: it is a row so that a
        # restart cannot lose it, and caching it here would give that back.
        self.offer = await fetch_offer(self.player_id, self.trait)
        drawn = card if card is not None else await render(self)
        self.build()
        await interaction.response.edit_message(embed=drawn, view=self)

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True


class Reroll(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @app_commands.command(description="Spend Spirit Jade on more chances at a root or physique.")
    async def reroll(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])

        confirmed = await db.fetch_value(
            "SELECT confirmed_at IS NOT NULL FROM player_character WHERE player_id = %s",
            (player["player_id"],),
        )
        if not confirmed:
            raise GameError(
                "Finish creating your character first — **/register** still has "
                "free rerolls in it, and they cost nothing."
            )

        odds = await fetch_odds("root")
        races = await db.fetch_all(
            "SELECT code, name, specialty FROM races ORDER BY name"
        )
        view = RerollView(player["player_id"], interaction.user, odds, races)
        # An offer left standing from a previous session is picked straight up.
        view.offer = await fetch_offer(player["player_id"], view.trait)
        view.build()
        await interaction.response.send_message(embed=await render(view), view=view)


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Reroll(bot))
