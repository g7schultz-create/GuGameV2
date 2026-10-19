"""Gu: /gu.

A build is a knapsack, not a list of slots. Your realm gives you an aperture;
every Gu costs some of it; what fits is what you are. That is the whole design
of this screen - the capacity line is the first thing on it, because it is the
constraint every choice below is made against.

What the Gu are worth is summed by `player_gu_stats`, already capped, so this
never adds anything up itself.
"""

import discord
import psycopg
from discord import app_commands
from discord.ext import commands

from bot import database as db
from bot.formatting import (
    COLOUR_DEFAULT,
    COLOUR_INFO,
    bar,
    embed,
    fit_field,
)
from bot.picking import (
    add_page_buttons,
    by_type_and_strength,
    page_count,
    page_note,
    page_of,
)
from bot.views import AnsweringView
from bot.players import GameError, require_player, settle_passive

STARS = "\N{BLACK STAR}"


async def fetch_gu(player_id: int) -> list[dict]:
    return await db.fetch_all(
        """
        SELECT g.gu_id, g.stars, g.harmony,
               t.code, t.name, t.size, t.emoji, t.rank, t.rarity, t.category,
               t.description,
               p.name AS path_name,
               e.gu_id IS NOT NULL AS equipped,
               -- `effect_amount` decides the unit, because Body, Hide and
               -- Sinew are POINTS and everything else is a fraction. Printing
               -- fifteen points of Body as fifteen hundred per cent is not a
               -- rounding problem, it is a different quantity.
               --
               -- The words rather than the sign, deliberately: psycopg reads a
               -- lone per cent as a placeholder marker even inside a comment,
               -- and writing it here is what broke this query first time.
               string_agg(
                   ef.emoji || ' ' || ef.name || ' ' ||
                   effect_amount(ef.code, te.magnitude
                         * (1 + game_config_value('gu_star_step') * (g.stars - 1)))
                   || CASE WHEN ef.is_live THEN '' ELSE '*' END,
                   ', ' ORDER BY ef.sort_order
               ) AS effects
        FROM player_gu g
        JOIN gu_types t ON t.gu_type_id = g.gu_type_id
        JOIN paths p ON p.code = t.path_code
        LEFT JOIN player_gu_equipped e ON e.gu_id = g.gu_id
        LEFT JOIN gu_type_effects te ON te.gu_type_id = t.gu_type_id
        LEFT JOIN gu_effects ef ON ef.code = te.effect_code
        WHERE g.owner_id = %s
        GROUP BY g.gu_id, t.gu_type_id, p.name, e.gu_id
        ORDER BY e.gu_id IS NULL, t.rank DESC, t.name
        """,
        (player_id,),
    )


async def fetch_aperture(player_id: int) -> dict:
    return await db.fetch_one(
        "SELECT gu_capacity_of(%s) AS capacity, gu_used_by(%s) AS used",
        (player_id, player_id),
    )


def stack(gu: list[dict]) -> list[dict]:
    """One entry per KIND, carrying the best copy and a count of them all.

    A Gu is an individual row because stars and harmony are rolled per
    worm, but nobody reads a jar that way: the question is "what have I
    got", and 253 rows of 130 kinds answers it 123 times too often.

    The representative is the BEST copy - most stars, then most harmony -
    so equipping off a stack takes the one you would have picked. That is
    also the opposite end of the pile from the one `nurture_gu` eats,
    which feeds the weakest spares first.
    """
    piles: dict[str, dict] = {}
    for g in gu:
        best = piles.get(g["code"])
        if best is None:
            piles[g["code"]] = dict(g, copies=1)
            continue
        best["copies"] += 1
        if (g["stars"], g["harmony"]) > (best["stars"], best["harmony"]):
            # A better copy takes over the entry and keeps the tally.
            piles[g["code"]] = dict(g, copies=best["copies"])
    return list(piles.values())


def sorted_spare(held: list[dict]) -> list[dict]:
    # STACKED, because the jar is the half that duplicates. What is worn is
    # one row per occupied slot and each of those is a distinct thing you
    # are carrying, so it stays individual below.
    return by_type_and_strength(
        stack([g for g in held if not g["equipped"]]),
        kind=lambda g: g["path_name"],
        # Rank is what it is; stars are how well it was made.
        strength=lambda g: (g["rank"], g["stars"]),
    )


def sorted_equipped(held: list[dict]) -> list[dict]:
    return by_type_and_strength(
        [g for g in held if g["equipped"]],
        kind=lambda g: g["path_name"],
        strength=lambda g: (g["rank"], g["stars"]),
    )


async def render_gu(
    player_id: int, display_name: str, *, page: int = 0
) -> discord.Embed:
    held = await fetch_gu(player_id)
    aperture = await fetch_aperture(player_id)
    stats = await db.fetch_all(
        """
        SELECT s.effect_code, s.total, s.capped, e.name, e.emoji, e.is_live,
               -- The same `effect_amount` the per-Gu lines above use, and for
               -- the same reason. This field was the one copy of the five that
               -- 0367 did not reach: it multiplied by a hundred regardless, so
               -- fifteen POINTS of Body read as fifteen hundred per cent.
               --
               -- Spelled out in words, like the comment above it: a lone per
               -- cent sign here is a placeholder marker to psycopg even inside
               -- a comment, and writing the bad output literally is what broke
               -- this query the second time as well.
               effect_amount(s.effect_code, s.total) AS amount
        FROM player_gu_stats s
        JOIN gu_effects e ON e.code = s.effect_code
        WHERE s.player_id = %s
        ORDER BY e.sort_order
        """,
        (player_id,),
    )

    card = embed(
        "\N{BUG} Gu",
        f"{display_name} \N{BULLET} aperture "
        f"**{aperture['used']} / {aperture['capacity']}**\n"
        f"{bar(aperture['used'], aperture['capacity'], width=18)}",
        colour=COLOUR_DEFAULT,
    )

    # Paged and measured, for two separate reasons that both bit here.
    #
    # PAGED because this function took a `page` and never once used it: the
    # view paged its dropdowns while the card underneath went on printing
    # everything, so the arrows moved the menu and not the list it was
    # describing. Sorted through the same helpers the view uses, so the two
    # cannot drift apart again.
    #
    # MEASURED because an embed field holds 1024 characters and an aperture no
    # longer holds a handful of worms. 0352 made capacity `rank * 3` and an
    # immortal carries thirty-odd, at roughly a hundred characters each once
    # the effects line is under it - which is what took /gu down. The jar below
    # has been using `fit_field` for exactly this reason; the aperture never
    # got the same treatment.
    equipped_all = sorted_equipped(held)
    equipped = page_of(equipped_all, page)
    card.add_field(
        name="Held in the aperture",
        value=fit_field(
            [
                f"{g['emoji']} **{g['name']} \N{MIDDLE DOT} rank {g['rank']}** "
                f"{STARS * g['stars']} \N{BULLET} size {g['size']}\n"
                f"     {g['effects'] or 'nothing'}"
                for g in equipped
            ],
            empty="*Nothing. A Gu does nothing in a jar.*",
            noun="more worn",
        ),
        inline=False,
    )

    if stats:
        lines = []
        for row in stats:
            line = f"{row['emoji']} {row['name']}: {row['amount']}"
            if row["capped"]:
                line += "  \N{WARNING SIGN} *at the cap*"
            if not row["is_live"]:
                line = f"*{line}*"
            lines.append(line)
        # Measured too. There are thirty-five live effects now - 0353 added
        # nine abilities and 0355 three base stats - and a build that touches
        # most of them would have walked this field past 1024 the same way the
        # aperture did.
        card.add_field(
            name="What they are worth",
            value=fit_field(lines, noun="more stats"),
            inline=False,
        )

    # Kept apart on purpose: the field shows one page, and `page_note` counts
    # the WHOLE jar to say which page that is. Handing it the slice would make
    # every footer claim the jar fits on one screen.
    all_spare = sorted_spare(held)
    spare = page_of(all_spare, page)
    # The jar is where you compare, so it carries the rank too - and a count of
    # twenty stopped being a safe cap the moment each line grew. `fit_field`
    # measures instead of counting, which is what the longest Gu name needs.
    card.add_field(
        name="In the jar",
        value=fit_field(
            [
                f"{g['emoji']} {g['name']} \N{MIDDLE DOT} rank {g['rank']}"
                + (f" **\N{MULTIPLICATION X}{g['copies']}**" if g['copies'] > 1 else "")
                for g in spare
            ],
            sep=", ",
            empty="*empty*",
            noun="more",
        ),
        inline=False,
    )
    note = page_note(all_spare, page, "jar")
    card.set_footer(
        text=(note + " • " if note else "")
        + f"{len(held)} Gu in {len(all_spare) + len(equipped_all)} kinds. "
        "Duplicates stack; the best copy is the one shown. Italic bonuses "
        "have no system behind them yet — and a Gu at its cap is a "
        "Gu doing nothing."
    )
    return card


class EquipSelect(discord.ui.Select):
    def __init__(self, view: "GuView", spare: list[dict]) -> None:
        self.screen = view
        super().__init__(
            placeholder="Take one into the aperture…",
            row=0,
            options=[
                discord.SelectOption(
                    label=f"{g['name']} {STARS * g['stars']}"[:100],
                    value=str(g["gu_id"]),
                    description=(
                        (f"{g['copies']} spare · " if g.get('copies', 1) > 1 else "")
                        + f"size {g['size']} · {g['path_name']} · {g['effects'] or 'nothing'}"
                    )[:100],
                    emoji=g["emoji"][:1] if g["emoji"] else None,
                )
                for g in spare
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        try:
            await db.execute(
                "INSERT INTO player_gu_equipped (gu_id, player_id) VALUES (%s, %s)",
                (int(self.values[0]), self.screen.player_id),
            )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0].capitalize()) from exc

        await self.screen.refresh(interaction)


class RemoveSelect(discord.ui.Select):
    def __init__(self, view: "GuView", equipped: list[dict]) -> None:
        self.screen = view
        super().__init__(
            placeholder="Put one back in the jar…",
            row=1,
            options=[
                discord.SelectOption(
                    label=f"{g['name']} {STARS * g['stars']}"[:100],
                    value=str(g["gu_id"]),
                    description=f"frees {g['size']} of the aperture"[:100],
                    emoji=g["emoji"][:1] if g["emoji"] else None,
                )
                for g in equipped
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        await db.execute(
            "DELETE FROM player_gu_equipped WHERE gu_id = %s AND player_id = %s",
            (int(self.values[0]), self.screen.player_id),
        )
        await self.screen.refresh(interaction)


class GuView(AnsweringView):
    """Both halves page, and both page together.

    The jar always did: it is every Gu ever refined or found. What is equipped
    used to be bounded by an aperture of twelve and was drawn with a bare
    `[:25]` on the reasoning that it "will not reach 25 for a long time" -
    which 0352 ended, by taking the aperture to 57 at the top of the immortal
    ladder. A silent truncation there is a worm a cultivator is wearing and
    cannot take off.

    One page index drives both lists, so the arrows move the whole screen
    rather than half of it. Both are sorted the same way - by Path, then the
    strongest first - because "where is my good Fire Gu" is the question being
    asked of both.
    """

    def __init__(self, player_id: int, user: discord.abc.User, held: list[dict]) -> None:
        super().__init__(timeout=300)
        self.player_id = player_id
        self.user = user
        self.held = held
        self.page = 0
        self.build()

    # Both halves come from the module-level sorters that `render_gu` uses, so
    # the dropdown and the card it sits under are ordered and paged by the same
    # code rather than by two copies of it.
    def sorted_spare(self) -> list[dict]:
        return sorted_spare(self.held)

    def sorted_equipped(self) -> list[dict]:
        return sorted_equipped(self.held)

    def page_count(self) -> int:
        # Whichever half is longer decides how far the arrows go, or the tail
        # of the other one is unreachable.
        return max(page_count(self.sorted_spare()),
                   page_count(self.sorted_equipped()))

    async def card(self) -> discord.Embed:
        return await render_gu(self.player_id, self.user.display_name, page=self.page)

    def build(self) -> None:
        self.clear_items()
        spare = self.sorted_spare()
        equipped = self.sorted_equipped()
        if spare:
            self.add_item(EquipSelect(self, page_of(spare, self.page)))
        if equipped:
            self.add_item(RemoveSelect(self, page_of(equipped, self.page)))
        add_page_buttons(self, row=2)

    async def refresh(self, interaction: discord.Interaction) -> None:
        # Max HP is a function of what is equipped, so changing the build has
        # to re-derive the body. Granting 0 XP is how everything else says
        # "recompute".
        await db.execute("SELECT apply_physique_xp(%s, 0)", (self.player_id,))

        self.held = await fetch_gu(self.player_id)
        # Equipping shortens the jar and lengthens what is worn, either of
        # which can delete the page being read.
        self.page = max(0, min(self.page, self.page_count() - 1))
        self.build()
        await interaction.response.edit_message(embed=await self.card(), view=self)

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message("Not your Gu.", ephemeral=True)
            return False
        return True

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True


class Gu(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    # A GROUP, because the bot sits at Discord's hundred-command ceiling
    # and the farm needed a slot. Two commands become one group carrying
    # three subcommands: a slot freed and a feature added.
    gu = app_commands.Group(
        name="gu", description="Your Gu, the jar, and the book."
    )

    @gu.command(name="look", description="Your Gu, and what fits in your aperture.")
    async def gu_look(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])

        held = await fetch_gu(player["player_id"])
        if not held:
            raise GameError(
                "You hold no Gu. They come off the things you kill — rarely. "
                "**/hunt**."
            )

        view = GuView(player["player_id"], interaction.user, held)
        await interaction.response.send_message(
            embed=await render_gu(player["player_id"], interaction.user.display_name),
            view=view,
        )

    # -----------------------------------------------------------------------

    @gu.command(name="book", description="Look up a Gu.")
    @app_commands.describe(name="Which Gu to read.")
    async def gu_book(self, interaction: discord.Interaction, name: str) -> None:
        row = await db.fetch_one(
            """
            SELECT t.*, p.name AS path_name, p.emoji AS path_emoji,
                   string_agg(ef.emoji || ' ' || ef.name || ' ' ||
                              effect_amount(ef.code, te.magnitude),
                              '\n' ORDER BY ef.sort_order) AS effects,
                   string_agg(DISTINCT r.name, ', ') AS regions,
                   game_config_value('gu_max_droppable_rank') AS drop_ceiling
            FROM gu_types t
            JOIN paths p ON p.code = t.path_code
            LEFT JOIN gu_type_effects te ON te.gu_type_id = t.gu_type_id
            LEFT JOIN gu_effects ef ON ef.code = te.effect_code
            LEFT JOIN gu_region_drops d ON d.gu_type_id = t.gu_type_id
            LEFT JOIN regions r ON r.code = d.region_code
            WHERE t.code = %s
            GROUP BY t.gu_type_id, p.name, p.emoji
            """,
            (name,),
        )
        if row is None:
            raise GameError(f"There is no Gu called `{name}`.")

        card = embed(
            f"{row['emoji']} {row['name']}", row["description"], colour=COLOUR_INFO
        )
        card.add_field(name="Path", value=f"{row['path_emoji']} {row['path_name']}")
        card.add_field(name="Rank", value=str(row["rank"]))
        card.add_field(name="Aperture", value=f"{row['size']}")
        card.add_field(
            name="At one star", value=row["effects"] or "Nothing.", inline=False
        )
        # "Not yet dropped anywhere" covers two very different Gu: one the
        # world has simply not been given a home for, and one the world is not
        # handing out at all yet. The second has a reason, so say the reason.
        if row["regions"]:
            where = f"Found in: {row['regions']}."
        elif row["rank"] > row["drop_ceiling"]:
            where = (
                f"Rank {row['rank']} is above what the world hands out "
                f"(rank {row['drop_ceiling']}). Refine it or do without."
            )
        else:
            where = "Not yet dropped anywhere."
        card.set_footer(text=where + " Each star adds a quarter again.")
        await interaction.response.send_message(embed=card)

    @gu_book.autocomplete("name")
    async def gu_autocomplete(
        self, interaction: discord.Interaction, current: str
    ) -> list[app_commands.Choice[str]]:
        rows = await db.fetch_all(
            "SELECT code, name || ' (R' || rank || ', size ' || size || ')' AS label "
            "FROM gu_types WHERE name ILIKE %s ORDER BY rank, name LIMIT 25",
            (f"%{current}%",),
        )
        return [app_commands.Choice(name=r["label"], value=r["code"]) for r in rows]


    @gu.command(
        name="dissolve", description="Break a spare Gu down for materials."
    )
    @app_commands.describe(spare="Which Gu to break down. It is not coming back.")
    async def gu_dissolve(
        self, interaction: discord.Interaction, spare: str
    ) -> None:
        """A Gu out of the jar, back into the materials it was refined from.

        `nurture_gu` was the only way out and it eats SAME-KIND copies only, so
        a lone spare had nowhere to go at all - 19 of one cultivator's kinds sat
        at exactly two copies, one short of the three a 2-star feeding wants.
        """
        player = await require_player(interaction.user)
        await interaction.response.defer()
        try:
            got = await db.fetch_one(
                "SELECT * FROM break_down_gu(%s, %s)",
                (player["player_id"], int(spare)),
            )
        except (ValueError, TypeError):
            raise GameError("Pick the Gu from the list.") from None
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0].capitalize() + ".") from exc

        back = got["got"] or {}
        card = embed(
            f"\N{WASTEBASKET} {got['gu_name']} comes apart",
            (f"{STARS * got['stars']} " if got["stars"] > 1 else "")
            + "Back into what it was refined from.",
            colour=COLOUR_INFO,
        )
        card.add_field(
            name="Recovered",
            value="\n".join(
                f"**{what}** \N{MULTIPLICATION X}{amount:,}"
                for what, amount in back.items()
            )
            or "*nothing*",
            inline=False,
        )
        card.set_footer(
            text="A share of the recipe, and more for every star it was fed "
            "\N{EM DASH} less than a failed refinement returns, because that "
            "one leaves you no Gu at all."
        )
        await interaction.followup.send(embed=card)

    @gu_dissolve.autocomplete("spare")
    async def dissolve_autocomplete(
        self, interaction: discord.Interaction, current: str
    ) -> list[app_commands.Choice[str]]:
        """Spares first, with what each would give back on the line.

        The Gu worth breaking is the fourth copy and not the only one, so the
        count of the kind is what the list is ordered by.
        """
        player = await db.fetch_one(
            "SELECT player_id FROM players WHERE discord_id = %s",
            (interaction.user.id,),
        )
        if player is None:
            return []
        rows = await db.fetch_all(
            """
            SELECT g.gu_id, g.stars, t.name, t.rank,
                   (SELECT count(*) FROM player_gu k
                    WHERE k.owner_id = g.owner_id
                      AND k.gu_type_id = g.gu_type_id) AS copies,
                   (SELECT string_agg(y.material_name || ' x' || y.quantity, ', ')
                    FROM gu_breakdown_yield(g.gu_id) y) AS back
            FROM player_gu g
            JOIN gu_types t ON t.gu_type_id = g.gu_type_id
            WHERE g.owner_id = %s AND t.name ILIKE %s
              -- Never something being worn: `break_down_gu` refuses it anyway,
              -- and offering it would be offering a refusal.
              AND NOT EXISTS (SELECT 1 FROM player_gu_equipped e
                              WHERE e.gu_id = g.gu_id)
            ORDER BY copies DESC, t.rank DESC, g.stars
            LIMIT 25
            """,
            (player["player_id"], f"%{current}%"),
        )
        out = []
        for r in rows:
            stars = f"{STARS * r['stars']} " if r["stars"] > 1 else ""
            out.append(
                app_commands.Choice(
                    name=(
                        f"{r['name']} R{r['rank']} {stars}\N{BULLET} "
                        f"{r['copies']} held \N{BULLET} "
                        f"{r['back'] or 'nothing'}"
                    )[:100],
                    value=str(r["gu_id"]),
                )
            )
        return out


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Gu(bot))
