"""Page fusion: /fuse.

Three pages of one tier, one Path and one kind become a single page a rung
higher. The strictness is the point - a fusion that took anything would make
Paths and page types stop meaning what they mean everywhere else - so this
screen's whole job is finding the stacks that already qualify and letting a
cultivator spend them without hunting through sixteen hundred pages by hand.

`page_fusion_shelf` is what qualifies; nothing here works it out.
"""

import discord
import psycopg
from discord import app_commands
from discord.ext import commands

from bot import database as db
from bot.formatting import COLOUR_GOOD, COLOUR_INFO, embed, thousands
from bot.picking import page_count, page_note, page_of
from bot.players import GameError, require_player
from bot.views import AnsweringView

PAGE = "\N{SCROLL}"
UP = "\N{UPWARDS BLACK ARROW}"


def refuse(exc: psycopg.errors.CheckViolation) -> GameError:
    return GameError(str(exc).splitlines()[0].capitalize())


async def shelf_of(player_id: int) -> list[dict]:
    return await db.fetch_all(
        "SELECT * FROM page_fusion_shelf WHERE player_id = %s "
        "ORDER BY tier DESC, fusions DESC, avg_quality DESC",
        (player_id,),
    )


def stack_line(row: dict) -> str:
    """One stack, as the shelf names it."""
    told = (
        f"**T{row['tier']}** {row['path_name']} {row['type_name'].lower()}"
        f" \N{BULLET} {row['held']} held"
        f" \N{BULLET} avg quality {row['avg_quality']}"
    )
    if row["fusions"] > 1:
        told += f" \N{BULLET} {row['fusions']} fusions"
    return told


async def shelf_card(
    player_id: int, stacks: list[dict], page: int = 0, tier: int | None = None
) -> discord.Embed:
    held = await db.fetch_one(
        "SELECT count(*) FILTER (WHERE consumed_at IS NULL) AS loose, "
        "       count(*) FILTER (WHERE consumed_at IS NULL AND tier <= 3) AS low "
        "FROM manual_pages WHERE owner_id = %s",
        (player_id,),
    )
    take = await db.fetch_value("SELECT game_config_value('page_fusion_count')")

    card = embed(
        f"{PAGE} Page fusion",
        f"**{int(take)}** pages of one tier, one Path and one kind become a "
        "single page a rung higher. Quality carries through, so feed the good "
        "ones.",
        colour=COLOUR_INFO,
    )
    card.add_field(
        name="On your shelf",
        value=f"**{thousands(held['loose'])}** pages \N{BULLET} "
        f"{thousands(held['low'])} of them tier 3 or under",
        inline=False,
    )

    if not stacks:
        card.add_field(
            name="Nothing to fuse",
            value=f"*You need {int(take)} pages sharing a tier, a Path and a "
            "kind. Keep gathering.*",
            inline=False,
        )
        return card

    shown = page_of(stacks, page)
    card.add_field(
        name=f"Ready to fuse ({len(stacks)} stack(s))"
        + (f" \N{EM DASH} tier {tier}" if tier is not None else ""),
        value="\n".join(stack_line(r) for r in shown[:10]),
        inline=False,
    )
    note = page_note(stacks, page, "stacks")
    card.set_footer(
        text=(note + " \N{BULLET} " if note else "")
        + "The three highest quality of the stack are the ones spent."
    )
    return card


class StackSelect(discord.ui.Select):
    """Which stack to spend, named the way the shelf names it.

    Only ever the page the card is showing. Discord allows 25 options and a
    busy cultivator has closer to two hundred stacks, so taking the first 25
    of a tier-descending shelf put every tier 1 and 2 stack out of reach -
    which reads exactly like fusion not working on low tiers.
    """

    def __init__(self, screen: "FuseView", stacks: list[dict]) -> None:
        self.screen = screen
        super().__init__(
            placeholder="Fuse three from\N{HORIZONTAL ELLIPSIS}",
            options=[
                discord.SelectOption(
                    label=f"T{r['tier']} {r['path_name']} "
                    f"{r['type_name'].lower()}"[:100],
                    value=f"{r['tier']}:{r['path_code']}:{r['page_type']}",
                    description=f"{r['held']} held \N{BULLET} avg quality "
                    f"{r['avg_quality']} \N{BULLET} makes a T{r['tier'] + 1}"[:100],
                )
                for r in stacks
            ],
            row=0,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        tier, path, kind = self.values[0].split(":", 2)
        await self.screen.fuse(interaction, int(tier), path, kind)


class TierButton(discord.ui.Button):
    """One rung of the shelf, or all of it.

    A filter rather than more pages: somebody clearing tier 1 wants tier 1,
    and paging to it through eighty stacks of tier 3 is not a way to work.
    """

    def __init__(self, screen: "FuseView", tier: int | None, count: int, row: int) -> None:
        self.screen = screen
        self.tier = tier
        super().__init__(
            label=(f"All \N{BULLET} {count}" if tier is None else f"T{tier} \N{BULLET} {count}")[:80],
            style=discord.ButtonStyle.primary
            if screen.tier == tier
            else discord.ButtonStyle.secondary,
            row=row,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        self.screen.tier = self.tier
        self.screen.page = 0
        await self.screen.redraw(interaction)


class ClearButton(discord.ui.Button):
    """Every stack of one rung, in one press.

    Only ever offered for a chosen tier. Clearing every rung at once would
    cascade - the pages it just made would be fused again - and somebody
    refining a manual needs pages of a particular Path AND tier. Clearing the
    rung you asked for is a convenience; eating the rung above it is somebody's
    build.
    """

    def __init__(self, screen: "FuseView", tier: int, fusions: int) -> None:
        self.screen = screen
        self.tier = tier
        super().__init__(
            label=f"Fuse all T{tier} \N{BULLET} {fusions}"[:80],
            emoji=UP,
            style=discord.ButtonStyle.success,
            row=3,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        await self.screen.clear_rung(interaction, self.tier)


class TurnButton(discord.ui.Button):
    def __init__(self, screen: "FuseView", step: int, glyph: str) -> None:
        self.screen = screen
        self.step = step
        super().__init__(label=glyph, row=4, style=discord.ButtonStyle.secondary)

    async def callback(self, interaction: discord.Interaction) -> None:
        self.screen.page = max(0, self.screen.page + self.step)
        await self.screen.redraw(interaction)


class FuseView(AnsweringView):
    def __init__(self, player_id: int, user: discord.abc.User, stacks: list[dict]) -> None:
        super().__init__(timeout=300)
        self.player_id = player_id
        self.user = user
        self.stacks = stacks
        self.tier: int | None = None
        self.page = 0
        self.build()

    def showing(self) -> list[dict]:
        if self.tier is None:
            return self.stacks
        return [r for r in self.stacks if r["tier"] == self.tier]

    def build(self) -> None:
        self.clear_items()
        rows = self.showing()
        if not rows:
            return

        # The select gets exactly the page the card draws, so what is read and
        # what can be fused are the same stacks.
        self.add_item(StackSelect(self, page_of(rows, self.page)))

        tiers = sorted({r["tier"] for r in self.stacks}, reverse=True)
        self.add_item(TierButton(self, None, len(self.stacks), 1))
        for n, tier in enumerate(tiers[:8]):
            self.add_item(
                TierButton(
                    self,
                    tier,
                    sum(1 for r in self.stacks if r["tier"] == tier),
                    1 + (n + 1) // 4,
                )
            )

        # Only once a rung is chosen, and only when there is more than one
        # press in it - a single stack is what the select is already for.
        if self.tier is not None:
            fusions = sum(r["fusions"] for r in rows)
            if fusions > 1:
                self.add_item(ClearButton(self, self.tier, fusions))

        if page_count(rows) > 1:
            self.add_item(TurnButton(self, -1, "\N{LEFTWARDS BLACK ARROW}"))
            self.add_item(TurnButton(self, 1, "\N{BLACK RIGHTWARDS ARROW}"))

    async def redraw(self, interaction: discord.Interaction) -> None:
        self.build()
        await interaction.response.edit_message(
            embed=await shelf_card(
                self.player_id, self.showing(), self.page, self.tier
            ),
            view=self if self.children else discord.utils.MISSING,
        )

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "Fuse your own \N{EM DASH} **/fuse**.", ephemeral=True
            )
            return False
        return True

    async def clear_rung(self, interaction: discord.Interaction, tier: int) -> None:
        """One rung, however many presses it used to be.

        `fuse_all` does the whole loop in the database. miyuki is holding 202
        fusions; two hundred round trips would run past the interaction window
        long before they ran out of pages.
        """
        try:
            done = await db.fetch_one("SELECT * FROM fuse_all(%s, %s)", (self.player_id, tier))
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        card = embed(
            f"{UP} Tier {tier} is clear",
            f"**{done['fusions']}** fusions \N{BULLET} {done['spent']} pages "
            f"spent \N{BULLET} **{done['fusions']}** tier {done['made_tier']} "
            "pages made.",
            colour=COLOUR_GOOD,
        )
        card.add_field(
            name="Best of them",
            value=f"Quality **{done['best_quality']}**"
            + (
                f" \N{BULLET} {done['traits']} came out marked"
                if done["traits"]
                else ""
            ),
            inline=False,
        )
        card.set_footer(
            text=f"The tier {done['made_tier']} pages are left alone \N{EM DASH} "
            "clear that rung too if you want them fused."
        )

        self.stacks = await shelf_of(self.player_id)
        self.page = 0
        self.build()
        await interaction.response.edit_message(
            embed=await shelf_card(
                self.player_id, self.showing(), self.page, self.tier
            ),
            view=self if self.children else discord.utils.MISSING,
        )
        await interaction.followup.send(embed=card, ephemeral=True)

    async def fuse(
        self, interaction: discord.Interaction, tier: int, path: str, kind: str
    ) -> None:
        # The three best of that stack. Picking them here rather than making
        # the player choose is the whole point of the screen - the rule is
        # already strict enough that there is nothing to decide.
        ids = [
            r["page_id"]
            for r in await db.fetch_all(
                "SELECT page_id FROM manual_pages "
                "WHERE owner_id = %s AND consumed_at IS NULL "
                "  AND tier = %s AND path_code = %s AND page_type = %s "
                "ORDER BY quality DESC, power DESC "
                "LIMIT (SELECT game_config_value('page_fusion_count')::int)",
                (self.player_id, tier, path, kind),
            )
        ]

        try:
            born = await db.fetch_one("SELECT * FROM fuse_pages(%s, %s)", (self.player_id, ids))
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        card = embed(
            f"{UP} A tier {born['tier']} page",
            f"Three tier {tier} pages went in.",
            colour=COLOUR_GOOD,
        )
        card.add_field(
            name=f"{PAGE} {born['path_code'].replace('_', ' ').title()} "
            f"{born['page_type']}",
            value=f"Power **{born['power']}** \N{BULLET} quality "
            f"**{born['quality']}**"
            + (
                f"\n\N{SPARKLES} {born['trait'].replace('_', ' ').title()}"
                if born["trait"]
                else ""
            ),
            inline=False,
        )

        self.stacks = await shelf_of(self.player_id)
        # The stack may have dropped below three; the filter and page stay so
        # somebody clearing tier 1 is not thrown back to the top each time.
        self.build()
        await interaction.response.edit_message(
            embed=await shelf_card(
                self.player_id, self.showing(), self.page, self.tier
            ),
            view=self if self.children else discord.utils.MISSING,
        )
        await interaction.followup.send(embed=card, ephemeral=True)


class Fusion(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @app_commands.command(
        description="Fuse three matching pages into one a tier higher."
    )
    async def fuse(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        stacks = await shelf_of(player["player_id"])
        view = FuseView(player["player_id"], interaction.user, stacks)
        await interaction.response.send_message(
            embed=await shelf_card(player["player_id"], stacks),
            view=view if view.children else discord.utils.MISSING,
        )


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Fusion(bot))
