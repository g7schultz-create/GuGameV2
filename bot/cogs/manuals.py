"""Manuals and the equipment page: /equipment, /manuals, /manual.

A manual does two things: it speeds cultivation while carried, and it unlocks
the combat moves written in it. Two may be equipped at once, which is the whole
decision - a Tier 4 cultivation scripture or the book that teaches the move you
actually need.

Every character is handed one at creation, so the equipment page is never
empty and /hunt works the moment a cultivator exists. Better ones are refined
from pages - see /refine - and a refined manual is an ordinary row with
`created_by` set, exactly as a player-made killer move is an ordinary
`techniques` row.
"""

import discord
import psycopg
from discord import app_commands
from discord.ext import commands

from bot import database as db
from bot.formatting import (
    COLOUR_DEFAULT,
    COLOUR_GOOD,
    COLOUR_INFO,
    embed,
    fit_field,
    percent,
    thousands,
)
from bot.picking import add_page_buttons, page_count, page_note, page_of
from bot.players import GameError, require_player, settle_passive
from bot.views import AnsweringView

MANUAL_SLOTS = 2

# There is no list of slots here on purpose.
#
# There used to be: seven hardcoded names under the heading "Not implemented
# yet", written when a manual was the only thing anybody could wear. Then 0036
# shipped the aperture and 0065 shipped the forge, and this page went on
# telling players that the armour they were wearing did not exist. Three of
# the seven names were live features and three were slots this game may never
# have.
#
# So the slots come from `equipment_slots`, the Gu line comes from the
# aperture, and a slot added by a future migration appears here on its own.

# Every bonus is an additive percentage. The last flag says whether anything
# actually consumes it yet - a bonus that reads as live and does nothing is
# worse than one that says so, which is the same call `unmodelled` makes on
# races and roots.
BONUS_LABELS = (
    ("cultivation_rate_bonus", "\N{HERB}", "Cultivation Speed", True),
    ("physique_rate_bonus", "\N{FLEXED BICEPS}", "Physique Training", True),
    ("attainment_rate_bonus", "\N{OPEN BOOK}", "All Path Attainment", True),
    ("attack_bonus", "\N{CROSSED SWORDS}", "Attack", True),
    ("hp_bonus", "\N{HEAVY BLACK HEART}", "Maximum HP", True),
    ("defense_bonus", "\N{SHIELD}", "Defense", True),
    ("strength_bonus", "\N{FLEXED BICEPS}", "Strength", True),
    ("gathering_bonus", "\N{SEEDLING}", "Gathering Yield", True),
    # These four were inert until 0193 wired them - through `player_stat` - to
    # effects that already existed and were already read. They are named for
    # what they now do rather than for the page type that fed them: "Speed"
    # described nothing, and there is no breakthrough roll in this game to
    # have a chance at.
    ("speed_bonus", "\N{DASH SYMBOL}", "Evasion", True),
    ("breakthrough_bonus", "\N{GLOWING STAR}", "Realm Tempering", True),
    ("essence_bonus", "\N{DROPLET}", "Qi Capacity", True),
    ("refinement_bonus", "\N{ALEMBIC}", "Refining Tolerance", True),
)


def top_bonuses(row, limit: int = 3) -> str:
    """The strongest few bonuses, iconed and no wider than they need to be.

    A select option description is capped at a hundred characters and an
    equipped line has one line to spare, so neither can carry the full twelve.
    Sorted by size rather than by the table's order, because "what is this
    manual FOR" is answered by its largest number and not by its first one.

    Inert bonuses are skipped here rather than italicised as `bonus_lines`
    does: this is the summary a player picks from, and a bonus that does
    nothing must not take the place of one that does.
    """
    have = [
        (row[column], icon)
        for column, icon, _, live in BONUS_LABELS
        if live and row.get(column)
    ]
    if not have:
        return ""
    have.sort(key=lambda pair: pair[0], reverse=True)
    return "  ".join(f"{icon} {percent(value)}" for value, icon in have[:limit])


def bonus_lines(row) -> tuple[list[str], bool]:
    """Rendered bonuses, and whether any of them is inert.

    Inert ones are italicised rather than hidden: they are part of what the
    manual is, and a player comparing two books should see the difference.
    """
    lines, inert = [], False
    for column, icon, label, live in BONUS_LABELS:
        value = row[column]
        if not value:
            continue
        if live:
            lines.append(f"{icon} {label}: {percent(value)}")
        else:
            inert = True
            lines.append(f"*{icon} {label}: {percent(value)}*")
    return lines, inert


async def fetch_equipped(player_id: int) -> list[dict]:
    return await db.fetch_all(
        """
        SELECT s.slot_index, m.manual_id, m.name, m.tier, m.archetype,
               m.cultivation_rate_bonus, m.physique_rate_bonus,
               m.attainment_rate_bonus, m.hp_bonus, m.defense_bonus,
               m.strength_bonus, m.attack_bonus, m.speed_bonus,
               m.breakthrough_bonus, m.essence_bonus, m.gathering_bonus,
               -- Through the curve, because the bench reads it that way
               -- since 0432 and a card that printed the raw 3.655 while
               -- the anvil used 0.440 would be lying by a factor of eight.
               refinement_effective(m.refinement_bonus) AS refinement_bonus,
               m.special_name, m.harmony,
               string_agg(p.name, ' / ' ORDER BY mp.weight DESC) AS paths,
               string_agg(DISTINCT t.name, ', ') AS unlocks
        FROM player_manual_slots s
        JOIN manuals m ON m.manual_id = s.manual_id
        LEFT JOIN manual_paths mp ON mp.manual_id = m.manual_id
        LEFT JOIN paths p ON p.code = mp.path_code
        LEFT JOIN manual_techniques mt ON mt.manual_id = m.manual_id
        LEFT JOIN techniques t ON t.technique_id = mt.technique_id
        WHERE s.player_id = %s
        GROUP BY s.slot_index, m.manual_id
        ORDER BY s.slot_index
        """,
        (player_id,),
    )


async def fetch_owned(player_id: int) -> list[dict]:
    return await db.fetch_all(
        """
        SELECT m.manual_id, m.name, m.tier, m.required_rank, m.archetype,
               m.cultivation_rate_bonus, m.physique_rate_bonus,
               m.attainment_rate_bonus, m.hp_bonus, m.defense_bonus,
               m.strength_bonus, m.attack_bonus, m.speed_bonus,
               m.breakthrough_bonus, m.essence_bonus, m.gathering_bonus,
               -- Through the curve, because the bench reads it that way
               -- since 0432 and a card that printed the raw 3.655 while
               -- the anvil used 0.440 would be lying by a factor of eight.
               refinement_effective(m.refinement_bonus) AS refinement_bonus,
               m.harmony,
               s.slot_index,
               -- STANDING, because this gates which manuals the equip
               -- select offers at all, and `load_preset` moved onto
               -- standing in 0537 - two readers of the same rule must not
               -- disagree. Latent while `manuals.required_rank` is CHECK
               -- 1..9, since both ladders clear 9; it stops being latent
               -- the day a book is written for the realm above the realms.
               player_standing(pm.player_id) AS player_rank,
               string_agg(DISTINCT p.name, ' / ') AS paths,
               -- The move it carries, if it is the sort of manual that does.
               -- Read here rather than inferred from the archetype, because
               -- a refined technique manual and a canonical one are the same
               -- thing to every screen and should stay that way.
               -- Ordered and reported by what the move is worth to the
               -- reader rather than what it was filed under, since a
               -- manual carrying a forged technique was off by 128x.
               (SELECT t.name FROM manual_techniques mt
                JOIN techniques t ON t.technique_id = mt.technique_id
                WHERE mt.manual_id = m.manual_id AND t.grade = 'advanced'
                ORDER BY technique_power_for(pm.player_id, t.technique_id)
                         DESC LIMIT 1) AS killer_move,
               (SELECT technique_power_for(pm.player_id, t.technique_id)
                FROM manual_techniques mt
                JOIN techniques t ON t.technique_id = mt.technique_id
                WHERE mt.manual_id = m.manual_id AND t.grade = 'advanced'
                ORDER BY technique_power_for(pm.player_id, t.technique_id)
                         DESC LIMIT 1) AS killer_power
        FROM player_manuals pm
        JOIN manuals m ON m.manual_id = pm.manual_id
        LEFT JOIN player_manual_slots s
            ON s.player_id = pm.player_id AND s.manual_id = pm.manual_id
        LEFT JOIN manual_paths mp ON mp.manual_id = m.manual_id
        LEFT JOIN paths p ON p.code = mp.path_code
        -- Both joins are now pure FILTERS - nothing selects from them since
        -- `player_rank` moved onto standing. They stay: an inner join to
        -- `player_cultivation` is what keeps a character still in creation out
        -- of this list, and dropping it to tidy up would quietly start showing
        -- them manuals. 0538 is the same lesson from the other direction.
        JOIN player_cultivation pc ON pc.player_id = pm.player_id
        JOIN realms r ON r.realm_id = pc.realm_id
        WHERE pm.player_id = %s
        -- pm.player_id joins the grouping because the killer-move
        -- subqueries now ask what the move is worth to THIS reader.
        -- It is constant across the whole query - the WHERE pins it -
        -- so grouping by it changes nothing but the legality.
        GROUP BY m.manual_id, pm.player_id, s.slot_index
        -- Equipped first, then whatever carries a move, then by tier. Once a
        -- cultivator owns a technique manual it is the row they came here for.
        ORDER BY s.slot_index NULLS LAST,
                 (m.archetype = 'technique') DESC,
                 m.tier DESC, m.name
        """,
        (player_id,),
    )


async def fetch_worn(player_id: int) -> list[dict]:
    """Every forge slot, and what is in it. LEFT JOIN because a bare slot is
    the interesting case - it is the one telling you what to go and make."""
    return await db.fetch_all(
        """
        SELECT s.code, s.name, s.emoji, s.description,
               e.name AS item_name, e.tier, e.quality, e.harmony
        FROM equipment_slots s
        LEFT JOIN player_equipped w ON w.player_id = %s AND w.slot = s.code
        LEFT JOIN player_equipment e ON e.equipment_id = w.equipment_id
        ORDER BY s.sort_order
        """,
        (player_id,),
    )


async def fetch_aperture(player_id: int) -> dict:
    return await db.fetch_one(
        """
        SELECT gu_capacity_of(%s) AS capacity,
               COALESCE(sum(t.size), 0) AS used,
               count(*) AS held
        FROM player_gu_equipped q
        JOIN player_gu g ON g.gu_id = q.gu_id
        JOIN gu_types t ON t.gu_type_id = g.gu_type_id
        WHERE q.player_id = %s
        """,
        (player_id, player_id),
    )


async def render_equipment(
    player_id: int, display_name: str, shelf: list[dict] | None = None
) -> discord.Embed:
    """The equipment card.

    `shelf` is the page of manuals the select is currently offering. Listing it
    here is the whole point of this change: a select option carries a hundred
    characters and a manual has twelve bonuses, so the dropdown can never be
    the place a player compares books. The dropdown picks; this reads.
    """
    equipped = await fetch_equipped(player_id)
    # Manuals held back because the realm is not there yet. The select is
    # right to leave them out - offering one would be offering a choice that
    # does nothing - but leaving them out SILENTLY is how somebody who has
    # just won the rarest drop in the game opens this screen, does not see
    # it, and concludes it was lost.
    locked = await db.fetch_all(
        """
        SELECT m.name, m.required_rank
        FROM player_manuals pm
        JOIN manuals m ON m.manual_id = pm.manual_id
        WHERE pm.player_id = %s
          -- Standing, matching the equip gate above it. Reading the realm
          -- here would list a rank-19 book as locked to the one cultivator
          -- it was written for.
          AND m.required_rank > COALESCE(player_standing(pm.player_id), 0)
        ORDER BY m.required_rank, m.name
        """,
        (player_id,),
    )
    owned = await db.fetch_value(
        "SELECT count(*) FROM player_manuals WHERE player_id = %s", (player_id,)
    )
    bonuses = await db.fetch_one(
        "SELECT * FROM player_manual_bonuses WHERE player_id = %s", (player_id,)
    )

    card = embed(
        "\N{SHIELD} Equipment",
        f"{display_name} \N{BULLET} {len(equipped)}/{MANUAL_SLOTS} manuals equipped",
        colour=COLOUR_DEFAULT,
    )

    lines = []
    by_slot = {row["slot_index"]: row for row in equipped}
    for index in range(MANUAL_SLOTS):
        row = by_slot.get(index)
        if row is None:
            lines.append(f"`{index + 1}` *empty*")
            continue
        # The summed field below says what the pair is worth together, which
        # is no help at all in working out which of the two to swap out.
        worth = top_bonuses(row)
        lines.append(
            f"`{index + 1}` **{row['name']}** — Tier {row['tier']}, "
            f"{row['archetype']}\n"
            f"     {row['paths'] or 'untyped'}"
            + (f"  \N{BULLET}  unlocks {row['unlocks']}" if row["unlocks"] else "")
            + (f"\n     {worth}" if worth else "")
        )
    card.add_field(name="\N{GRADUATION CAP} Manual", value="\n".join(lines), inline=False)

    if bonuses:
        granted, inert = bonus_lines(bonuses)
        if inert:
            granted.append("\n*Italic bonuses have no system behind them yet.*")
        if granted:
            card.add_field(name="What they are worth", value="\n".join(granted), inline=False)

    if shelf:
        card.add_field(
            name=f"\N{OPEN BOOK} On the shelf ({len(shelf)} of them here)",
            value=fit_field([
                f"`T{row['tier']}` **{row['name']}**"
                + ("  \N{BOOKMARK}" if row["slot_index"] is not None else "")
                + (
                    f"\n     📜 {row['killer_move']} "
                    f"({thousands(row['killer_power'])} power)"
                    if row["killer_move"]
                    else ""
                )
                + (f"\n     {top_bonuses(row)}" if top_bonuses(row) else "")
                for row in shelf
            ], noun="not listed"),
            inline=False,
        )

    worn = await fetch_worn(player_id)
    card.add_field(
        name="\N{HAMMER} Forged",
        value="\n".join(
            f"{row['emoji']} **{row['name']}** \N{BULLET} "
            + (
                f"{row['item_name']} \N{BULLET} tier {row['tier']} "
                f"{row['quality']}"
                if row["item_name"]
                else "*bare* \N{EM DASH} **/forge**"
            )
            for row in worn
        ),
        inline=False,
    )

    aperture = await fetch_aperture(player_id)
    card.add_field(
        name="\N{BUG} Aperture",
        value=(
            f"**{aperture['held']}** Gu \N{BULLET} "
            f"{aperture['used']}/{aperture['capacity']} of the aperture spent"
            if aperture["held"]
            else f"Empty \N{EM DASH} **{aperture['capacity']}** to spend. **/gu**"
        ),
        inline=False,
    )

    if locked:
        card.add_field(
            name=f"Not yet yours to carry ({len(locked)})",
            value="\n".join(
                f"\N{LOCK} **{row['name']}** \N{EM DASH} needs realm "
                f"{row['required_rank']}"
                for row in locked[:6]
            )
            + (f"\n*\N{HORIZONTAL ELLIPSIS} and {len(locked) - 6} more*"
               if len(locked) > 6 else "")
            + "\n*They are in your satchel and on **/manuals**. Cultivate and "
            "they open.*",
            inline=False,
        )

    card.set_footer(
        text=f"{owned} manual(s) in your possession. Manuals are refined from "
        "pages (/refine), gear is forged (/forge) and worn (/gear), Gu go in "
        "the aperture (/gu)."
    )
    return card


# ---------------------------------------------------------------------------
# The Binder
# ---------------------------------------------------------------------------
# Levelling Refinement means refining, and every refinement makes a manual
# whether or not it makes a good one - so a refiner accumulates a shelf of
# books they will never equip and had, until now, no way to be rid of.
#
# The bulk half is what the screen is for. Picking eleven Tier 1 manuals out
# of a select one at a time is not "bulk", it is the same chore with more
# presses, so there is a button per tier that takes the whole band at once.


async def fetch_unbindable(player_id: int) -> list[dict]:
    """Everything on the shelf that is not currently being read.

    Equipped manuals are excluded here as well as refused by `unbind_manuals`.
    The SQL is the rule; leaving them off the screen is so that "All Tier 1"
    never means "and the one you are using".
    """
    return await db.fetch_all(
        """
        SELECT m.manual_id, m.name, m.tier, m.archetype, m.quality,
               y.pages, y.page_tier,
               COALESCE(
                   (SELECT p.name FROM manual_paths mp
                    JOIN paths p ON p.code = mp.path_code
                    WHERE mp.manual_id = m.manual_id
                    ORDER BY mp.weight DESC, mp.path_code LIMIT 1),
                   'untyped') AS path_name
        FROM player_manuals pm
        JOIN manuals m ON m.manual_id = pm.manual_id
        CROSS JOIN LATERAL manual_unbind_yield(m.tier) y
        WHERE pm.player_id = %s
          AND NOT EXISTS (
              SELECT 1 FROM player_manual_slots s
              WHERE s.player_id = pm.player_id AND s.manual_id = m.manual_id)
        ORDER BY m.tier, m.name
        """,
        (player_id,),
    )


def render_binder(rows: list[dict], page: int) -> discord.Embed:
    card = embed(
        "\N{OPEN BOOK} The Binder",
        "*\"Bring me what you will not read. I cannot give you back what went "
        "into it \N{EM DASH} but I can give you back the paper.\"*",
        colour=COLOUR_INFO,
    )

    if not rows:
        card.add_field(
            name="Nothing to unbind",
            value="Every manual you hold is equipped. **/equipment** to take "
            "one off.",
            inline=False,
        )
        return card

    # By tier, because that is what the yield depends on and what the bulk
    # buttons act on.
    bands: dict[int, list[dict]] = {}
    for row in rows:
        bands.setdefault(row["tier"], []).append(row)

    card.add_field(
        name="What the shelf is worth",
        value="\n".join(
            f"**Tier {tier}** \N{MULTIPLICATION SIGN}{len(held)} \N{RIGHTWARDS ARROW} "
            f"{held[0]['pages']} \N{MULTIPLICATION SIGN} tier {held[0]['page_tier']} "
            f"page{'s' if held[0]['pages'] != 1 else ''} each"
            for tier, held in sorted(bands.items())
        ),
        inline=False,
    )
    card.add_field(
        name="What comes back",
        value="Pages of the manual's own leading Path, one tier below the "
        "book. Always less than went in \N{EM DASH} unbinding is a way to stop "
        "wasting a shelf, not a way to farm pages. No Refinement EXP either "
        "way.",
        inline=False,
    )

    note = page_note(rows, page, "manuals")
    card.set_footer(
        text=(note + " \N{BULLET} " if note else "")
        + "Equipped manuals are not listed and cannot be unbound."
    )
    return card


class UnbindSelect(discord.ui.Select):
    def __init__(self, screen: "BinderView", rows: list[dict]) -> None:
        self.screen = screen
        super().__init__(
            placeholder="Unbind particular manuals\N{HORIZONTAL ELLIPSIS}",
            row=0,
            min_values=1,
            max_values=len(rows),
            options=[
                discord.SelectOption(
                    label=f"T{r['tier']} {r['name']}"[:100],
                    value=str(r["manual_id"]),
                    description=(
                        f"{r['path_name']} \N{RIGHTWARDS ARROW} {r['pages']}x "
                        f"tier {r['page_tier']} page"
                        f"{'s' if r['pages'] != 1 else ''}"
                    )[:100],
                )
                for r in rows
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        chosen = [int(v) for v in self.values]
        await self.screen.confirm(interaction, chosen)


class BandButton(discord.ui.Button):
    """The bulk half: a whole tier in one press."""

    def __init__(self, screen: "BinderView", tier: int, count: int) -> None:
        self.screen = screen
        self.tier = tier
        super().__init__(
            label=f"All tier {tier} ({count})",
            row=1,
            style=discord.ButtonStyle.secondary,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        chosen = [r["manual_id"] for r in self.screen.rows if r["tier"] == self.tier]
        await self.screen.confirm(interaction, chosen)


class BinderView(AnsweringView):
    def __init__(self, player_id: int, user: discord.abc.User, rows: list[dict]) -> None:
        super().__init__(timeout=300)
        self.player_id = player_id
        self.user = user
        self.rows = rows
        self.page = 0
        self.build()

    def page_count(self) -> int:
        return page_count(self.rows)

    def card(self) -> discord.Embed:
        return render_binder(self.rows, self.page)

    def build(self) -> None:
        self.clear_items()
        shown = page_of(self.rows, self.page)
        if shown:
            self.add_item(UnbindSelect(self, shown))
        tiers: dict[int, int] = {}
        for row in self.rows:
            tiers[row["tier"]] = tiers.get(row["tier"], 0) + 1
        # Four bands at most on the row; beyond that the select is the way.
        for tier, count in sorted(tiers.items())[:4]:
            self.add_item(BandButton(self, tier, count))
        add_page_buttons(self, row=2)

    async def confirm(self, interaction: discord.Interaction, chosen: list[int]) -> None:
        picked = [r for r in self.rows if r["manual_id"] in set(chosen)]
        pages = sum(r["pages"] for r in picked)

        card = embed(
            f"\N{OPEN BOOK} Unbind {len(picked)} manual(s)?",
            "This destroys the books. It cannot be undone.",
            colour=COLOUR_DEFAULT,
        )
        card.add_field(
            name="Going",
            value="\n".join(
                f"T{r['tier']} **{r['name']}**" for r in picked[:12]
            )
            + (f"\n*\N{HORIZONTAL ELLIPSIS} and {len(picked) - 12} more*"
               if len(picked) > 12 else ""),
            inline=False,
        )
        card.add_field(
            name="Coming back",
            value=f"**{pages}** page(s), on the Paths those books were written "
            "on.",
            inline=False,
        )
        await interaction.response.send_message(
            embed=card,
            view=UnbindConfirm(self.player_id, self.user, chosen),
            ephemeral=True,
        )

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


class UnbindConfirm(AnsweringView):
    def __init__(
        self, player_id: int, user: discord.abc.User, manuals: list[int]
    ) -> None:
        super().__init__(timeout=180)
        self.player_id = player_id
        self.user = user
        self.manuals = manuals

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        return interaction.user.id == self.user.id

    @discord.ui.button(label="Unbind", style=discord.ButtonStyle.danger)
    async def go(self, interaction: discord.Interaction, button) -> None:
        try:
            done = await db.fetch_one(
                "SELECT * FROM unbind_manuals(%s, %s)",
                (self.player_id, self.manuals),
            )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0].capitalize()) from exc

        made = await db.fetch_all(
            """
            SELECT p.tier, p.power, p.quality, pa.name AS path_name,
                   ty.name AS type_name
            FROM manual_pages p
            JOIN paths pa ON pa.code = p.path_code
            JOIN page_types ty ON ty.code = p.page_type
            WHERE p.page_id = ANY(%s)
            ORDER BY p.tier DESC, p.power DESC
            """,
            (done["page_ids"],),
        )

        card = embed(
            f"\N{OPEN BOOK} {done['manuals_taken']} manual(s) unbound",
            f"**{done['pages_made']}** page(s) came back.",
            colour=COLOUR_GOOD,
        )
        card.add_field(
            name="On the bench",
            value="\n".join(
                f"T{r['tier']} **{r['path_name']}** {r['type_name']} "
                f"\N{BULLET} power {r['power']}, quality {r['quality']}%"
                for r in made[:15]
            )
            + (f"\n*\N{HORIZONTAL ELLIPSIS} and {len(made) - 15} more*"
               if len(made) > 15 else ""),
            inline=False,
        )
        card.set_footer(text="**/refine** puts them back together.")

        for item in self.children:
            item.disabled = True
        await interaction.response.edit_message(embed=card, view=self)
        self.stop()

    @discord.ui.button(label="Keep them", style=discord.ButtonStyle.secondary)
    async def stop_it(self, interaction: discord.Interaction, button) -> None:
        for item in self.children:
            item.disabled = True
        await interaction.response.edit_message(
            embed=embed("Kept", "The shelf is untouched.", colour=COLOUR_INFO),
            view=self,
        )
        self.stop()


class Manuals(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @app_commands.command(description="Your equipment, and what it is worth.")
    async def equipment(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])

        owned = await fetch_owned(player["player_id"])
        view = EquipmentView(player["player_id"], interaction.user, owned)
        await interaction.response.send_message(embed=await view.card(), view=view)

    # -----------------------------------------------------------------------

    @app_commands.command(
        description="Take old manuals apart into pages."
    )
    async def unbind(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])

        rows = await fetch_unbindable(player["player_id"])
        view = BinderView(player["player_id"], interaction.user, rows)
        await interaction.response.send_message(
            embed=view.card(), view=view if rows else discord.utils.MISSING
        )

    # -----------------------------------------------------------------------

    @app_commands.command(description="Every manual you are carrying.")
    async def manuals(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        owned = await fetch_owned(player["player_id"])
        if not owned:
            raise GameError(
                "You have no manuals. They turn up on the bodies of things you "
                "kill — **/hunt**."
            )

        screen = Shelf(interaction.user, owned)
        await interaction.response.send_message(embed=screen.card(), view=screen)

    # -----------------------------------------------------------------------

    @app_commands.command(description="The manual pages you are holding.")
    @app_commands.describe(path="Only pages of this Path.")
    async def pages(
        self, interaction: discord.Interaction, path: str | None = None
    ) -> None:
        """Refinement ingredients.

        Nothing drops pages yet - the drop specs exist and are empty - so this
        is here ahead of the content rather than after it.
        """
        player = await require_player(interaction.user)
        rows = await db.fetch_all(
            """
            SELECT p.page_id, p.tier, p.power, p.quality, p.trait,
                   pa.name AS path_name, pa.emoji AS path_emoji,
                   ty.code AS type_code, ty.name AS type_name,
                   ty.emoji AS type_emoji, ty.sort_order,
                   tr.name AS trait_name
            FROM manual_pages p
            JOIN paths pa ON pa.code = p.path_code
            JOIN page_types ty ON ty.code = p.page_type
            LEFT JOIN page_traits tr ON tr.code = p.trait
            WHERE p.owner_id = %s
              AND p.consumed_at IS NULL
              AND (%s::text IS NULL OR p.path_code = %s)
            -- By what a page FEEDS, then by what it is worth. A refiner
            -- picks a column to fill and then wants the strongest thing that
            -- fills it; tier is a consequence of power, not a thing to sort
            -- on. The limit is gone: clearwest holds nine hundred and
            -- thirty-four pages and forty of them were the whole screen.
            ORDER BY ty.sort_order, p.power DESC, p.quality DESC
            """,
            (player["player_id"], path, path),
        )
        if not rows:
            raise GameError(
                "You are holding no pages. They come off rogue cultivators, "
                "who turn up while you are gathering, hunting or exploring — "
                "nothing else in the world carries one."
            )

        screen = PageBinder(interaction.user, rows, path)
        await interaction.response.send_message(embed=screen.card(), view=screen)

    @pages.autocomplete("path")
    async def pages_path_autocomplete(
        self, interaction: discord.Interaction, current: str
    ) -> list[app_commands.Choice[str]]:
        rows = await db.fetch_all(
            "SELECT code, name FROM paths WHERE name ILIKE %s ORDER BY sort_order LIMIT 25",
            (f"%{current}%",),
        )
        return [app_commands.Choice(name=r["name"], value=r["code"]) for r in rows]

    # -----------------------------------------------------------------------

    @app_commands.command(description="Read one manual in full.")
    @app_commands.describe(manual="Which manual to read.")
    async def manual(self, interaction: discord.Interaction, manual: str) -> None:
        row = await db.fetch_one(
            """
            SELECT m.*, string_agg(DISTINCT p.name, ' / ') AS paths,
                   string_agg(DISTINCT t.name, ', ') AS unlocks,
                   creator.discord_name AS refiner
            FROM manuals m
            LEFT JOIN manual_paths mp ON mp.manual_id = m.manual_id
            LEFT JOIN paths p ON p.code = mp.path_code
            LEFT JOIN manual_techniques mt ON mt.manual_id = m.manual_id
            LEFT JOIN techniques t ON t.technique_id = mt.technique_id
            LEFT JOIN players creator ON creator.player_id = m.created_by
            WHERE m.code = %s
            GROUP BY m.manual_id, creator.discord_name
            """,
            (manual,),
        )
        if row is None:
            raise GameError(f"There is no manual called `{manual}`.")

        card = embed(row["name"], row["description"], colour=COLOUR_INFO)
        card.add_field(name="Tier", value=str(row["tier"]))
        card.add_field(name="Archetype", value=row["archetype"].title())
        card.add_field(name="Requires", value=f"rank {row['required_rank']}")
        card.add_field(name="Paths", value=row["paths"] or "Untyped.", inline=False)

        granted, inert = bonus_lines(row)
        card.add_field(
            name="While equipped",
            value="\n".join(granted) or "Nothing.",
            inline=False,
        )
        budget = await db.fetch_one(
            "SELECT mt.name, mt.bonus_budget, manual_total_bonus(%s) AS spent "
            "FROM manual_tiers mt WHERE mt.tier = %s",
            (row["manual_id"], row["tier"]),
        )
        card.add_field(
            name="Tier budget",
            value=f"A Tier {row['tier']} manual distributes "
            f"{percent(budget['bonus_budget'], signed=False)}; this one spends "
            f"{percent(budget['spent'], signed=False)}.\n*{budget['name']}*"
            + ("\n\nItalic bonuses have no system behind them yet." if inert else ""),
            inline=False,
        )

        if row["unlocks"]:
            card.add_field(name="Unlocks", value=row["unlocks"], inline=False)
        if row["special_name"]:
            card.add_field(
                name=f"\N{LARGE BLUE DIAMOND} {row['special_name']}",
                value=row["special_text"],
                inline=False,
            )
        if row["harmony"] is not None:
            card.set_footer(text=f"Refined by {row['refiner']} at {row['harmony']} harmony.")
        await interaction.response.send_message(embed=card)

    @manual.autocomplete("manual")
    async def manual_autocomplete(
        self, interaction: discord.Interaction, current: str
    ) -> list[app_commands.Choice[str]]:
        rows = await db.fetch_all(
            "SELECT code, name || ' (T' || tier || ')' AS label FROM manuals "
            "WHERE code IS NOT NULL AND name ILIKE %s ORDER BY tier, name LIMIT 25",
            (f"%{current}%",),
        )
        return [app_commands.Choice(name=r["label"], value=r["code"]) for r in rows]


# ---------------------------------------------------------------------------
# The equipment view
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# The manual shelf
# ---------------------------------------------------------------------------
# /manuals put every book in one embed description. That was survivable at
# twenty-four manuals and stops being survivable at about forty-five, where the
# description passes Discord's 4096 characters and the whole message is
# REFUSED - not truncated, refused, so the command simply errors and the player
# is told nothing. 0130 added eighteen more manuals to the game, which moved
# that from theoretical to scheduled.
#
# Paged, and split by the distinction that actually matters now: a technique
# manual is carrying a killer move and the rest are carrying rates.

MANUALS_PER_PAGE = 8


def manual_line(row: dict) -> str:
    where = (
        f"  \N{BULLET}  **equipped {row['slot_index'] + 1}**"
        if row["slot_index"] is not None
        else ""
    )
    gated = (
        f"  \N{BULLET}  *needs rank {row['required_rank']}*"
        if row["required_rank"] > row["player_rank"]
        else ""
    )
    # This quoted the cultivation rate and nothing else, which described one
    # manual in five: an offensive book spends its whole budget on attack and
    # was listed as "+0% cultivation", indistinguishable from a blank one. A
    # technique manual is the same case again, with the move being the point.
    # A technique manual leads with the move, because that is what the slot is
    # being spent on - but it also carries half a tier's stat budget, and
    # hiding that was the same omission in a new place.
    stats = top_bonuses(row, 3)
    worth = (
        f"📜 **{row['killer_move']}** ({thousands(row['killer_power'])} power)"
        + (f"  •  {stats}" if stats else "")
        if row["killer_move"]
        else top_bonuses(row, 4) or "*nothing yet*"
    )
    return (
        f"`T{row['tier']}` **{row['name']}** \N{BULLET} "
        f"{row['paths'] or 'untyped'}{where}{gated}\n"
        f"\N{IDEOGRAPHIC SPACE}{worth}"
    )


# Each filter is a predicate rather than a column test, so "equipped" and
# "technique" can live in the same row of buttons without one of them being a
# special case the other has to know about.
MANUAL_VIEWS = (
    ("all", "\N{BOOKS}", "All", lambda r: True),
    ("technique", "📜", "Killer moves", lambda r: r["killer_move"] is not None),
    ("equipped", "\N{BOOKMARK}", "Equipped", lambda r: r["slot_index"] is not None),
)


class ShelfButton(discord.ui.Button):
    def __init__(self, screen: "Shelf", code: str, glyph: str, label: str, held: int) -> None:
        self.screen = screen
        self.code = code
        super().__init__(
            label=f"{label} ({held})",
            emoji=glyph,
            row=0,
            style=(
                discord.ButtonStyle.primary
                if code == screen.kind
                else discord.ButtonStyle.secondary
            ),
            disabled=held == 0,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        self.screen.kind = self.code
        self.screen.page = 0
        self.screen.build()
        await interaction.response.edit_message(
            embed=self.screen.card(), view=self.screen
        )


class Shelf(AnsweringView):
    def __init__(self, user: discord.abc.User, owned: list[dict]) -> None:
        super().__init__(timeout=180)
        self.user = user
        self.owned = owned
        self.kind = "all"
        self.page = 0
        self.build()

    def matching(self, code: str) -> list[dict]:
        keep = next(f for c, _, _, f in MANUAL_VIEWS if c == code)
        return [row for row in self.owned if keep(row)]

    def page_count(self) -> int:
        return max(1, -(-len(self.matching(self.kind)) // MANUALS_PER_PAGE))

    def build(self) -> None:
        self.clear_items()
        for code, glyph, label, _ in MANUAL_VIEWS:
            self.add_item(
                ShelfButton(self, code, glyph, label, len(self.matching(code)))
            )
        add_page_buttons(self, row=1)

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "Those are not your manuals.", ephemeral=True
            )
            return False
        return True

    def card(self) -> discord.Embed:
        mine = self.matching(self.kind)
        page = self.page % self.page_count()
        here = mine[page * MANUALS_PER_PAGE:(page + 1) * MANUALS_PER_PAGE]
        label = next(lab for c, _, lab, _ in MANUAL_VIEWS if c == self.kind)

        card = embed(
            "Your manuals" if self.kind == "all" else f"Your manuals — {label}",
            "\n".join(manual_line(row) for row in here) or "*None of those.*",
            colour=COLOUR_DEFAULT,
        )
        note = page_note(mine, self.page, "manuals", MANUALS_PER_PAGE)
        card.set_footer(
            text=(f"{note}  \N{BULLET}  " if note else "")
            + "/equipment to equip two of them."
        )
        return card


# ---------------------------------------------------------------------------
# The page binder
# ---------------------------------------------------------------------------
# `/pages` sorted by tier and cut at forty. clearwest holds nine hundred and
# thirty-four, so eight hundred and ninety-four were invisible - and the footer
# read "40 page(s)", which is a screen stating its own truncation as though it
# were the total.
#
# Grouped by what a page FEEDS and ordered by power inside that, because a
# refiner picks a column to fill and then wants the strongest thing that fills
# it. Tier is a consequence of power rather than something to sort on, which is
# why it stops leading the line.

PAGES_PER_PAGE = 12


def page_line(row: dict) -> str:
    return (
        f"`T{row['tier']}` {row['path_emoji']} "
        f"**{row['path_name'].replace(' Path', '')}** — "
        f"power **{row['power']}**, {row['quality']}%"
        + (f"  •  *{row['trait_name']}*" if row["trait_name"] else "")
    )


class TypeButton(discord.ui.Button):
    def __init__(self, screen: "PageBinder", code: str, glyph: str,
                 label: str, held: int, row: int) -> None:
        self.screen = screen
        self.code = code
        super().__init__(
            label=f"{label} ({held})",
            emoji=glyph[:1] if glyph else None,
            row=row,
            style=(
                discord.ButtonStyle.primary
                if code == screen.kind
                else discord.ButtonStyle.secondary
            ),
            disabled=held == 0,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        self.screen.kind = self.code
        self.screen.page = 0
        self.screen.build()
        await interaction.response.edit_message(
            embed=self.screen.card(), view=self.screen
        )


class PageBinder(AnsweringView):
    def __init__(self, user: discord.abc.User, rows: list[dict],
                 path: str | None) -> None:
        super().__init__(timeout=300)
        self.user = user
        self.rows = rows
        self.path = path
        # The types actually held, in the order the table declares them - the
        # rows arrive already sorted by `sort_order`.
        self.kinds: list[tuple[str, str, str]] = []
        seen: set[str] = set()
        for row in rows:
            if row["type_code"] not in seen:
                seen.add(row["type_code"])
                self.kinds.append(
                    (row["type_code"], row["type_emoji"], row["type_name"])
                )
        self.kind = self.kinds[0][0] if self.kinds else None
        self.page = 0
        self.build()

    def held(self, code: str) -> int:
        return sum(1 for row in self.rows if row["type_code"] == code)

    def kind_rows(self) -> list[dict]:
        return [row for row in self.rows if row["type_code"] == self.kind]

    def page_count(self) -> int:
        return max(1, -(-len(self.kind_rows()) // PAGES_PER_PAGE))

    def build(self) -> None:
        self.clear_items()
        # Ten types is two rows of five, which is what Discord allows and what
        # a refiner is actually choosing between.
        for i, (code, glyph, label) in enumerate(self.kinds[:10]):
            self.add_item(
                TypeButton(self, code, glyph, label, self.held(code), i // 5)
            )
        add_page_buttons(self, row=2)

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "Those are not your pages.", ephemeral=True
            )
            return False
        return True

    def card(self) -> discord.Embed:
        mine = self.kind_rows()
        page = self.page % self.page_count()
        here = mine[page * PAGES_PER_PAGE:(page + 1) * PAGES_PER_PAGE]
        glyph, label = next(
            (g, lab) for code, g, lab in self.kinds if code == self.kind
        )

        card = embed(
            f"{glyph} {label} pages",
            "\n".join(page_line(row) for row in here) or "*None of those.*",
            colour=COLOUR_DEFAULT,
        )
        note = page_note(mine, self.page, "pages", PAGES_PER_PAGE)
        card.set_footer(
            text=(f"{note}  •  " if note else "")
            + f"{thousands(len(self.rows))} page(s) held"
            + (f" on the {self.path} Path" if self.path else "")
            + f", {thousands(sum(r['power'] for r in self.rows))} total power."
        )
        return card


class ManualSelect(discord.ui.Select):
    """One slot's picker, over one page of what this cultivator can use.

    It used to read `view.owned[:24]`, which is not a limit so much as a
    disappearance: somebody with twenty-five manuals could not equip the
    twenty-fifth and was never told it existed. 0130 put eighteen more manuals
    in the game, so that stopped being theoretical the day it landed.
    """

    def __init__(self, view: "EquipmentView", slot: int) -> None:
        self.equipment = view
        self.slot = slot

        options = [
            discord.SelectOption(
                label=f"T{row['tier']} {row['name']}"[:100],
                value=str(row["manual_id"]),
                description=(
                    f"T{row['tier']} {row['archetype']} · "
                    + (
                        f"{thousands(row['killer_power'])} power"
                        if row["killer_move"]
                        else top_bonuses(row, 2) or "no bonuses"
                    )
                )[:100],
                default=row["slot_index"] == slot,
            )
            for row in view.page_rows()
        ]
        options.append(
            discord.SelectOption(label="— empty this slot —", value="clear")
        )
        super().__init__(
            placeholder=f"Slot {slot + 1}",
            row=slot,
            options=options,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        choice = self.values[0]

        if choice == "clear":
            await db.execute(
                "DELETE FROM player_manual_slots WHERE player_id = %s AND slot_index = %s",
                (self.equipment.player_id, self.slot),
            )
        else:
            try:
                async with db.pool().connection() as conn:
                    # The same manual cannot sit in both slots; free the other
                    # one first rather than letting the UNIQUE reject the swap.
                    await conn.execute(
                        "DELETE FROM player_manual_slots "
                        "WHERE player_id = %s AND manual_id = %s",
                        (self.equipment.player_id, int(choice)),
                    )
                    await conn.execute(
                        """
                        INSERT INTO player_manual_slots (player_id, slot_index, manual_id)
                        VALUES (%s, %s, %s)
                        ON CONFLICT (player_id, slot_index)
                        DO UPDATE SET manual_id = EXCLUDED.manual_id, equipped_at = now()
                        """,
                        (self.equipment.player_id, self.slot, int(choice)),
                    )
            except psycopg.errors.ForeignKeyViolation as exc:
                raise GameError("You do not own that manual.") from exc

        # HP, defense and strength are derived from (level, traits, manuals),
        # so changing what is equipped has to re-derive them. Granting 0 XP is
        # the cheapest way to say "recompute".
        await db.execute("SELECT apply_physique_xp(%s, 0)", (self.equipment.player_id,))

        self.equipment.owned = await fetch_owned(self.equipment.player_id)
        self.equipment.usable = [
            row for row in self.equipment.owned
            if row["required_rank"] <= row["player_rank"]
        ]
        self.equipment.rebuild()
        await interaction.response.edit_message(
            embed=await self.equipment.card(), view=self.equipment
        )


class EquipmentView(AnsweringView):
    # A select holds 25 options, but the CARD lists the same page underneath
    # it and an embed field holds 1024 characters. A technique manual's entry
    # runs to three lines and about a hundred and ten characters, so
    # twenty-four of them measured 1,972 characters against a limit of 1,024 -
    # and Discord refuses the whole message rather than trimming it. Eight
    # measures 775, which fits with nothing dropped.
    PER_PAGE = 8

    def __init__(self, player_id: int, user: discord.abc.User, owned: list[dict]) -> None:
        super().__init__(timeout=180)
        self.player_id = player_id
        self.user = user
        self.owned = owned
        # Only what this cultivator can actually equip. The rest is listed by
        # /manuals with its required rank noted; offering it here would be
        # offering a choice that does nothing.
        self.usable = [
            row for row in owned if row["required_rank"] <= row["player_rank"]
        ]
        self.page = 0
        self.rebuild()

    def page_count(self) -> int:
        return max(1, -(-len(self.usable) // self.PER_PAGE))

    def page_rows(self) -> list[dict]:
        page = self.page % self.page_count()
        return self.usable[page * self.PER_PAGE:(page + 1) * self.PER_PAGE]

    def build(self) -> None:
        """What `PageButton` calls. This cog named the same job `rebuild`, and
        both have to work rather than one of them quietly doing nothing."""
        self.rebuild()

    async def card(self) -> discord.Embed:
        """`PageButton` calls this after turning the page and awaits it, so the
        listed stats and the dropdown are always the same page of manuals."""
        return await render_equipment(
            self.player_id, self.user.display_name, self.page_rows()
        )

    def rebuild(self) -> None:
        self.clear_items()
        if not self.usable:
            return
        for slot in range(MANUAL_SLOTS):
            self.add_item(ManualSelect(self, slot))
        add_page_buttons(self, row=2)

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "That is not your equipment.", ephemeral=True
            )
            return False
        return True

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Manuals(bot))
