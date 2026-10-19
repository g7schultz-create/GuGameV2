"""Forging a technique: /enlighten and /inscribe.

Once a day an immortal sits with a technique that does not exist yet and makes
it. Three rolls decide what they get up with, and all three are written down
before they are shown:

* the GRADE, which is what it hits for as a fraction of the realm behind it;
* the PATH, one usually and two rarely, and two is the strong outcome;
* three rounds of three stat options, some of which are losses of focus.

The screen never rolls anything. `forge_begin` opens the day, `forge_offer`
puts the board down once and keeps it, and `forge_take` takes an answer — so
closing this and reopening it shows the same three options, which is the whole
reason the offer is stored rather than generated on read. It is the rule
/destiny already runs on, for the same reason.

/inscribe is the other door into the same anvil. Instead of spending the day
and letting the sky pick, it burns technique pages: the pile sets a FLOOR on
the quality, the Paths come off the pages rather than off your attainment, and
half of where it lands in the band is how well those pages rolled inside their
own tiers. From the moment the forge row exists the two are indistinguishable -
the board, the rounds and the manual are all the same code.
"""

import discord
import psycopg
from discord import app_commands
from discord.ext import commands

from bot import database as db
from bot.formatting import (
    COLOUR_BAD,
    COLOUR_GOOD,
    COLOUR_INFO,
    embed,
    percent,
    thousands,
)
from bot.lookups import path_autocomplete
from bot.players import GameError, require_player
from bot.views import AnsweringView

SPARK = "\N{HIGH VOLTAGE SIGN}"
LOST = "\N{HEAVY EXCLAMATION MARK SYMBOL}"
DONE = "\N{WHITE HEAVY CHECK MARK}"


def refuse(exc: psycopg.errors.CheckViolation) -> GameError:
    return GameError(str(exc).splitlines()[0].capitalize())


async def open_forge(player_id: int) -> dict | None:
    """The forge this cultivator is in the middle of, if any."""
    return await db.fetch_one(
        """
        SELECT f.forge_id, f.power_grade, f.dual, f.paths, f.step,
               f.realm_rank, f.focus,
               q.name AS quality_name, q.emoji AS quality_emoji,
               q.flavour AS quality_flavour, q.effects AS effect_slots,
               (SELECT string_agg(p.emoji || ' ' || p.name, '  ')
                FROM paths p WHERE p.code = ANY(f.paths)) AS path_text
        FROM technique_forges f
        LEFT JOIN enlighten_qualities q ON q.code = f.quality
        WHERE f.player_id = %s AND f.finished_at IS NULL
        """,
        (player_id,),
    )


async def board_for(forge_id: int) -> list[dict]:
    """The three options of the current round, with what each one would do.

    `forge_offer` comes first because the board does not exist until something
    asks for it, and asking twice is free - it writes the three down on the
    first call and hands back the same three forever after. Reading
    `forge_choices` directly would show an empty round to whoever opened the
    screen first, which is exactly what it did before this line was here.

    The magnitudes were rolled when the board was written down, so this reads
    them rather than deciding them - two people looking at the same forge see
    the same numbers.
    """
    await db.fetch_value("SELECT forge_offer(%s)", (forge_id,))
    return await db.fetch_all(
        """
        SELECT o.code, o.magnitude, b.name, b.description, b.is_curse,
               b.manual_column,
               (SELECT ef.name FROM manual_effect_columns c
                JOIN gu_effects ef ON ef.code = c.effect_code
                WHERE c.manual_column = b.manual_column) AS reads_as
        FROM technique_forges f
        JOIN forge_choices ch
          ON ch.forge_id = f.forge_id AND ch.step = f.step
        CROSS JOIN LATERAL jsonb_to_recordset(ch.offered)
             AS o(code text, magnitude numeric)
        JOIN forge_boons b ON b.code = o.code
        WHERE f.forge_id = %s
        ORDER BY b.is_curse, o.magnitude DESC
        """,
        (forge_id,),
    )


def grade_word(grade: float) -> str:
    grade = float(grade)
    if grade >= 3.4:
        return "Peerless"
    if grade >= 2.4:
        return "Sovereign"
    if grade >= 1.6:
        return "Ascendant"
    if grade >= 0.9:
        return "Lesser"
    return "Crude"


def stat_line(row: dict) -> str:
    """What a boon actually does, named the way the rest of the game names it.

    Most manual columns are their own thing; four of them are a gu_effect
    wearing a different name, and those say so rather than making a player
    guess that speed is evasion.
    """
    said = row["manual_column"].replace("_bonus", "").replace("_", " ")
    if row["reads_as"]:
        said = row["reads_as"]
    return f"{said.title()} {percent(row['magnitude'])}"


async def forge_card(player_id: int, forge: dict | None) -> discord.Embed:
    if forge is None:
        last = await db.fetch_one(
            """
            SELECT t.name, m.quality, f.dual, f.power_grade,
                   -- What it hits for now, which for a forge made a
                   -- realm ago is twice what it was filed under.
                   technique_power_for(f.player_id, t.technique_id)
                       AS base_power
            FROM technique_forges f
            JOIN techniques t ON t.technique_id = f.technique_id
            LEFT JOIN manuals m ON m.manual_id = f.manual_id
            WHERE f.player_id = %s AND f.finished_at IS NOT NULL
            ORDER BY f.finished_at DESC LIMIT 1
            """,
            (player_id,),
        )
        card = embed(
            f"{SPARK} Nothing is on the anvil",
            "You have sat with it already today. **/enlighten** again tomorrow.",
            colour=COLOUR_INFO,
        )
        if last:
            card.add_field(
                name="Last forged",
                value=f"**{last['name']}** \N{BULLET} "
                f"{grade_word(last['power_grade'])}"
                + (" \N{BULLET} two Paths" if last["dual"] else "")
                # The query has fetched this since 0395 and printed the name
                # and the grade only. What it hits for is the thing a grade
                # was ever shorthand for.
                + f"\n\N{CROSSED SWORDS} hits for "
                  f"**{thousands(last['base_power'])}**",
                inline=False,
            )
        return card

    # The tier names itself now. `grade_word` is kept as the fallback for
    # forges opened before 0373, which carry no quality.
    tier = forge["quality_name"] or grade_word(forge["power_grade"])
    mark = forge["quality_emoji"] or SPARK
    stood = len(forge["paths"])

    card = embed(
        f"{mark} {tier} — "
        + ("three Paths" if stood > 2 else "two Paths" if stood > 1 else "one Path"),
        (f"*{forge['quality_flavour']}*\n\n" if forge["quality_flavour"] else "")
        + f"It has taken shape as **{forge['path_text']}**.\n"
        + (
            "Standing on more than one Path at once, which is the strongest "
            "thing a day of this can produce.\n"
            if stood > 1
            else ""
        )
        + (
            f"You sat down looking for the {forge['focus']} Path.\n"
            if forge["focus"]
            else ""
        )
        + "\nNow what it *teaches* you. Three rounds, one taken each time.",
        colour=COLOUR_GOOD,
    )

    # What the grade already rolled is worth in these hands. The screen
    # named the quality and the Paths and never the number the quality is
    # shorthand FOR, so a player chose between boons without knowing what
    # they were decorating. `technique_grade_power` is the same function
    # the swing itself asks, so this cannot drift from the damage.
    hits = await db.fetch_value(
        "SELECT technique_grade_power(%s, %s)",
        (player_id, forge["power_grade"]),
    )
    card.add_field(
        name="What it will hit for",
        value=f"\N{CROSSED SWORDS} **{thousands(hits)}** a strike, before your boons.",
        inline=False,
    )

    steps = int(await db.fetch_value("SELECT game_config_value(%s)",
                                     ("technique_forge_steps",)))
    board = await board_for(forge["forge_id"])

    card.add_field(
        name=f"Round {forge['step'] + 1} of {steps}",
        value="One of these, and it cannot be put back.",
        inline=False,
    )
    for one in board:
        mark = LOST if one["is_curse"] else "\N{SMALL BLUE DIAMOND}"
        card.add_field(
            name=f"{mark} {one['name']}",
            value=f"*{one['description']}*\n**{stat_line(one)}**",
            inline=False,
        )

    taken = await db.fetch_all(
        """
        SELECT b.name, c.magnitude, b.is_curse, b.manual_column,
               (SELECT ef.name FROM manual_effect_columns mc
                JOIN gu_effects ef ON ef.code = mc.effect_code
                WHERE mc.manual_column = b.manual_column) AS reads_as
        FROM forge_choices c
        JOIN forge_boons b ON b.code = c.taken
        WHERE c.forge_id = %s AND c.taken IS NOT NULL
        ORDER BY c.step
        """,
        (forge["forge_id"],),
    )
    if taken:
        card.add_field(
            name="Already written",
            value="\n".join(
                f"{LOST if t['is_curse'] else DONE} {t['name']} "
                f"\N{BULLET} {stat_line(t)}"
                for t in taken
            )[:1024],
            inline=False,
        )

    card.set_footer(
        text="The board is rolled once. Closing this and coming back "
        "shows the same three."
    )
    return card


class BoonSelect(discord.ui.Select):
    def __init__(self, screen: "ForgeView", board: list[dict]) -> None:
        self.screen = screen
        super().__init__(
            placeholder="Take one\N{HORIZONTAL ELLIPSIS}",
            options=[
                discord.SelectOption(
                    label=o["name"][:100],
                    value=o["code"],
                    description=stat_line(o)[:100],
                    emoji=LOST if o["is_curse"] else None,
                )
                for o in board
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        await self.screen.take(interaction, self.values[0])


class RiverButton(discord.ui.Button):
    """Spending a root special, offered where it is wanted.

    It sits on the refusal rather than on a command of its own: the moment a
    player learns the anvil is shut is the moment they want to know they can
    walk back to before it was, and a separate command is one they would have
    to already know about.
    """

    def __init__(self, player_id: int, name: str, left: int) -> None:
        self.player_id = player_id
        super().__init__(
            label=f"{name} ({left} left today)"[:80],
            emoji="🔷",
            style=discord.ButtonStyle.primary,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        try:
            spent = await db.fetch_one(
                "SELECT * FROM root_special_use(%s, 'forge_technique')",
                (player["player_id"],),
            )
            # Opening the anvil is what the charge was for, so it happens in
            # the same press. A cleared cooldown and a player who then has to
            # remember to run the command again is half a feature.
            await db.fetch_value(
                "SELECT forge_begin(%s, %s)", (player["player_id"], None)
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        card, view = await forge_screen(player["player_id"], interaction.user)
        card.set_footer(
            text=f"{spent['special_name']} • "
                 f"{spent['charges_left']} left today"
        )
        await interaction.response.edit_message(
            embed=card, view=view if view else discord.utils.MISSING
        )


class RiverView(AnsweringView):
    def __init__(self, player_id: int, name: str, left: int) -> None:
        super().__init__(timeout=180)
        self.add_item(RiverButton(player_id, name, left))


async def offer_the_river(player_id: int) -> tuple[discord.Embed, AnsweringView] | None:
    """What a root can do about a shut anvil, if anything.

    None for almost everybody, which is the point: this is asked of every
    refusal and answers for the one cultivator whose root has something to
    say about it.
    """
    row = await db.fetch_one(
        """
        SELECT r.special_name, r.special_text,
               root_special_charges_left(%(p)s, 'forge_technique') AS left,
               root_special_ready_at(%(p)s, 'forge_technique') AS returns_at
        FROM player_character pc
        JOIN roots r ON r.code = pc.root_code
        JOIN root_specials rs ON rs.root_code = pc.root_code
        WHERE pc.player_id = %(p)s AND rs.resets_action = 'forge_technique'
        """,
        {"p": player_id},
    )
    if row is None or not row["left"]:
        return None

    card = embed(
        f"🔷 {row['special_name']}",
        f"The anvil is shut — but *{row['special_text']}*",
        colour=COLOUR_INFO,
    )
    card.add_field(
        name="Today",
        value=f"**{row['left']}** left.",
        inline=False,
    )
    return card, RiverView(player_id, row["special_name"], int(row["left"]))


class ForgeView(AnsweringView):
    def __init__(
        self, player_id: int, user: discord.abc.User, forge: dict | None,
        board: list[dict],
    ) -> None:
        super().__init__(timeout=600)
        self.player_id = player_id
        self.user = user
        self.forge = forge
        if forge is not None and board:
            self.add_item(BoonSelect(self, board))

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "Your own meditation is your own \N{EM DASH} **/enlighten**.",
                ephemeral=True,
            )
            return False
        return True

    async def take(self, interaction: discord.Interaction, code: str) -> None:
        try:
            got = await db.fetch_one(
                "SELECT * FROM forge_take(%s, %s)", (self.forge["forge_id"], code)
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        if not got["done"]:
            self.forge = await open_forge(self.player_id)
            board = await board_for(self.forge["forge_id"]) if self.forge else []
            self.clear_items()
            if board:
                self.add_item(BoonSelect(self, board))
            await interaction.response.edit_message(
                embed=await forge_card(self.player_id, self.forge),
                view=self if self.children else discord.utils.MISSING,
            )
            return

        made = await db.fetch_one(
            """
            SELECT t.name, t.description, m.quality,
                   t.qi_cost_pct, t.cooldown_turns,
                   -- The forge row is not in this FROM and never was, so
                   -- `f.player_id` was a column reference to nothing: every
                   -- completed forge raised "missing FROM-clause entry for
                   -- table f" on the one screen that tells you what you made.
                   -- The cultivator is the one asking, so they are passed in.
                   technique_power_for(%(who)s, t.technique_id)
                       AS base_power,
                   -- Since 0461 a forge can produce a stance rather than a
                   -- strike, and the two want reading differently.
                   t.category,
                   m.strength_bonus, m.attack_bonus, m.hp_bonus,
                   m.defense_bonus, m.speed_bonus, m.lifesteal_bonus,
                   (SELECT string_agg(p.emoji || ' ' || p.name, '  ')
                    FROM technique_paths tp JOIN paths p ON p.code = tp.path_code
                    WHERE tp.technique_id = t.technique_id) AS path_text,
                   -- What it carries into a fight, named the way the battle
                   -- screen names it rather than by its internal code.
                   -- chr(37) is the per cent sign: a literal one here would be
                   -- read by psycopg as a placeholder marker.
                   (SELECT string_agg(
                        b.name || ' '
                        || round(100 * (e ->> 'magnitude')::numeric) || chr(37)
                        || ' for ' || (e ->> 'turns') || ' turns'
                        || CASE WHEN e ->> 'target' = 'party'
                                THEN ' (the whole room)' ELSE '' END,
                        chr(10))
                    FROM jsonb_array_elements(
                             COALESCE(t.effects -> 'apply', '[]'::jsonb)) AS e
                    JOIN battle_effect_kinds b ON b.code = e ->> 'code') AS carries
            FROM techniques t
            LEFT JOIN manuals m ON m.manual_id = %(manual)s
            WHERE t.technique_id = %(tech)s
            """,
            # Named rather than positional: this query grew a third parameter
            # in front of the other two, and a positional list would have put
            # the manual where the player goes without saying anything.
            {
                "who": self.player_id,
                "manual": got["manual_id"],
                "tech": got["technique_id"],
            },
        )

        lines = [
            f"{name} {percent(made[col])}"
            for col, name in (
                ("strength_bonus", "Strength"),
                ("attack_bonus", "Attack"),
                ("hp_bonus", "Health"),
                ("defense_bonus", "Defence"),
                ("speed_bonus", "Evasion"),
                ("lifesteal_bonus", "Life on Hit"),
            )
            if made[col]
        ]

        self.forge = None
        self.clear_items()
        card = embed(
            f"{DONE} {made['name']}",
            f"*{made['description']}*\n\n{made['path_text']}",
            colour=COLOUR_GOOD if made["quality"] != "common" else COLOUR_BAD,
        )
        card.add_field(name="Quality", value=made["quality"].title())
        card.add_field(
            name="What it is",
            value={
                "attack": "A strike",
                "defense": "A defensive stance",
                "support": "A supporting art",
                "utility": "A pull — it holds attention",
            }.get(made["category"], made["category"].title()),
        )
        card.add_field(
            name="Casting",
            value=f"{percent(made['qi_cost_pct'], signed=False)} of your qi"
            + (
                f"\n{made['cooldown_turns']} turn cooldown"
                if made["cooldown_turns"]
                else "\nno cooldown"
            ),
        )
        card.add_field(name="It teaches", value="\n".join(lines) or "nothing at all")
        if made["carries"]:
            card.add_field(
                name="It carries", value=made["carries"], inline=False
            )
        card.set_footer(
            text="The manual is yours. Equip it with /manuals to use the "
            "technique it teaches."
        )
        await interaction.response.edit_message(embed=card, view=discord.utils.MISSING)


async def forge_screen(
    player_id: int, user: discord.abc.User
) -> tuple[discord.Embed, "ForgeView | None"]:
    """The anvil as it stands, whichever door opened it.

    Pulled out of /enlighten so /inscribe hands off to exactly the same screen
    rather than growing a second copy of it that drifts.
    """
    forge = await open_forge(player_id)
    board = await board_for(forge["forge_id"]) if forge else []
    view = ForgeView(player_id, user, forge, board)
    return await forge_card(player_id, forge), (view if view.children else None)


async def fetch_technique_pages(player_id: int) -> list[dict]:
    """Every technique page still in your hands, deepest first."""
    return await db.fetch_all(
        """
        SELECT mp.page_id, mp.tier, mp.power, mp.path_code, mp.found_in,
               pa.name AS path_name, pa.emoji AS path_emoji,
               pt.power_min, pt.power_max,
               r.name AS region_name
        FROM manual_pages mp
        JOIN paths pa ON pa.code = mp.path_code
        JOIN page_tiers pt ON pt.tier = mp.tier
        LEFT JOIN regions r ON r.code = mp.found_in
        WHERE mp.owner_id = %s AND mp.consumed_at IS NULL
          AND mp.page_type = 'technique'
        ORDER BY mp.tier DESC, mp.power DESC
        """,
        (player_id,),
    )


async def pile_card(player_id: int, pages: list[dict],
                    reading: dict | None) -> discord.Embed:
    """What burning the chosen pages would be worth, before anything burns.

    Everything here comes out of `forge_pile_reading`, which is also what
    `forge_begin_from_pages` refuses on - so a pile this screen calls ready is
    a pile that forges.
    """
    card = embed(
        "\N{OPEN BOOK} Inscribe a technique",
        "Burn technique pages and write a move of your own out of them. The "
        "pile sets how good it can be and which Paths it can reach; the rest "
        "is still the roll.",
        colour=COLOUR_GOOD if reading and reading["ready"] else COLOUR_INFO,
    )

    card.add_field(
        name=f"Pages you hold ({len(pages)})",
        value="\n".join(
            f"{p['path_emoji']} **T{p['tier']} {p['path_name']}** "
            f"\N{BULLET} power {p['power']} of {p['power_min']}\N{EN DASH}"
            f"{p['power_max']}"
            + (f" \N{BULLET} *{p['region_name']}*" if p["region_name"] else "")
            for p in pages[:12]
        ) or "*None. A heaven drops them, about four times in a hundred pages.*",
        inline=False,
    )

    if reading is None or reading["pages"] == 0:
        card.set_footer(text="Choose the pages to burn.")
        return card

    if not reading["ready"]:
        card.add_field(
            name="\N{WARNING SIGN} Not a pile yet",
            value=f"{reading['refused'].capitalize()}.",
            inline=False,
        )
        return card

    lines = [
        f"{reading['floor_emoji'] or ''} Floors at **{reading['floor_name']}** "
        f"\N{EM DASH} average tier {reading['avg_tier']}. It can come out "
        "better than that and never worse.",
        f"\N{TWISTED RIGHTWARDS ARROWS} Paths it can reach: "
        f"**{reading['path_spread']}**",
    ]
    if reading["dual_possible"]:
        lines.append(
            "\N{LINK SYMBOL} A **dual Path** is possible \N{EM DASH} the pile "
            "holds more than one."
        )
    else:
        lines.append(
            "\N{HEAVY EXCLAMATION MARK SYMBOL} One Path only. A dual needs a "
            "mixed pile, however well the quality rolls."
        )
    if reading["may_step"]:
        lines.append(
            "\N{UPWARDS BLACK ARROW} Above the minimum \N{EM DASH} a chance "
            "the floor lifts one rung further."
        )
    lines.append(
        f"\N{DIRECT HIT} Those pages rolled **"
        f"{percent(float(reading['band_position']), signed=False)}** of the way "
        "up their own tiers, which is half of where this lands in its band."
    )

    # The floor had a NAME and no number. A quality is shorthand for what a
    # technique hits for, and /inscribe is the screen where somebody decides
    # whether a pile of pages is worth burning - which is a decision about
    # that number. A band rather than a figure, because a pile guarantees a
    # floor and the roll does the rest.
    band = await db.fetch_one(
        """
        SELECT technique_grade_power(%(p)s, q.grade_min) AS least_it_hits,
               technique_grade_power(%(p)s, q.grade_max) AS most_it_hits
        FROM enlighten_qualities q WHERE q.code = %(c)s
        """,
        {"p": player_id, "c": reading["floor_code"]},
    )
    if band:
        lines.append(
            f"\N{CROSSED SWORDS} Hits for **{thousands(band['least_it_hits'])}**"
            f"\N{EN DASH}**{thousands(band['most_it_hits'])}** a strike at that floor."
        )

    card.add_field(name="What it would be", value="\n".join(lines), inline=False)
    card.set_footer(
        text=f"{reading['pages']} of {reading['needed']} needed \N{BULLET} "
        "the pages are gone either way."
    )
    return card


class PageSelect(discord.ui.Select):
    """Which pages go in. The choosing is the mechanic, not a formality.

    A pile of one Path can only ever teach one Path, so this is where a player
    decides between aiming at a Path they want and reaching for a dual.
    """

    def __init__(self, screen: "InscribeView", pages: list[dict]) -> None:
        self.screen = screen
        super().__init__(
            placeholder="Which pages go into it…",
            min_values=1,
            max_values=min(25, len(pages)),
            options=[
                discord.SelectOption(
                    label=f"T{p['tier']} {p['path_name']}"[:100],
                    value=str(p["page_id"]),
                    description=f"power {p['power']} of "
                    f"{p['power_min']}-{p['power_max']}"[:100],
                    emoji=p["path_emoji"][:1] if p["path_emoji"] else None,
                    default=p["page_id"] in screen.chosen,
                )
                for p in pages[:25]
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        self.screen.chosen = [int(v) for v in self.values]
        await self.screen.refresh(interaction)


class InscribeView(AnsweringView):
    def __init__(
        self, player_id: int, user: discord.abc.User, pages: list[dict]
    ) -> None:
        super().__init__(timeout=300)
        self.player_id = player_id
        self.user = user
        self.pages = pages
        # Everything, to start. It is the commonest intent and the reading
        # below tells them immediately what it would come to.
        self.chosen = [p["page_id"] for p in pages][:25]
        self.reading: dict | None = None
        self.build()

    def build(self) -> None:
        self.clear_items()
        if self.pages:
            self.add_item(PageSelect(self, self.pages))
        self.add_item(BurnButton(self))

    async def read(self) -> dict | None:
        if not self.chosen:
            return None
        self.reading = await db.fetch_one(
            "SELECT * FROM forge_pile_reading(%s, %s)",
            (self.player_id, self.chosen),
        )
        return self.reading

    async def refresh(self, interaction: discord.Interaction) -> None:
        await self.read()
        self.build()
        await interaction.response.edit_message(
            embed=await pile_card(self.player_id, self.pages, self.reading),
            view=self,
        )

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "Not your pages.", ephemeral=True
            )
            return False
        return True

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True


class BurnButton(discord.ui.Button):
    def __init__(self, screen: InscribeView) -> None:
        self.screen = screen
        ready = bool(screen.reading and screen.reading["ready"])
        super().__init__(
            label="Burn them",
            style=discord.ButtonStyle.danger if ready else discord.ButtonStyle.secondary,
            emoji="\N{FIRE}",
            disabled=not ready,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        try:
            await db.fetch_value(
                "SELECT forge_begin_from_pages(%s, %s)",
                (self.screen.player_id, self.screen.chosen),
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        for item in self.screen.children:
            item.disabled = True
        await interaction.response.edit_message(view=self.screen)

        card, forge = await forge_screen(self.screen.player_id, self.screen.user)
        await interaction.followup.send(
            embed=card, view=forge if forge else discord.utils.MISSING
        )
        self.screen.stop()


class Enlighten(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @app_commands.command(
        description="Sit with a technique that does not exist yet. Once a day, immortals only."
    )
    @app_commands.describe(
        focus="A Path to sit looking for. It weights the draw; it never decides it."
    )
    @app_commands.autocomplete(focus=path_autocomplete)
    async def enlighten(
        self, interaction: discord.Interaction, focus: str | None = None
    ) -> None:
        player = await require_player(interaction.user)

        forge = await open_forge(player["player_id"])
        if forge is None:
            # Opening is what costs the day, so it is only attempted when there
            # is nothing already on the anvil. A focus named while something is
            # already on the anvil is ignored rather than refused - the board
            # was rolled the moment the day was spent.
            try:
                await db.fetch_value(
                    "SELECT forge_begin(%s, %s)", (player["player_id"], focus)
                )
            except psycopg.errors.CheckViolation as exc:
                # A root that can walk the day back is offered here rather
                # than as a bare refusal. Everybody else gets the refusal.
                offer = await offer_the_river(player["player_id"])
                if offer is None:
                    raise refuse(exc) from exc
                said, view = offer
                await interaction.response.send_message(embed=said, view=view)
                return
            forge = await open_forge(player["player_id"])

        card, view = await forge_screen(player["player_id"], interaction.user)
        await interaction.response.send_message(
            embed=card, view=view if view else discord.utils.MISSING
        )

    # -----------------------------------------------------------------------

    @app_commands.command(
        description="Burn technique pages into a move of your own. No daily cost."
    )
    async def inscribe(self, interaction: discord.Interaction) -> None:
        """The other door. Pages instead of the day, and you aim it.

        Refuses the same way /enlighten does when something is already on the
        anvil, because there is only one anvil - finishing what is on it is
        the answer either way.
        """
        player = await require_player(interaction.user)

        forge = await open_forge(player["player_id"])
        if forge is not None:
            card, view = await forge_screen(player["player_id"], interaction.user)
            await interaction.response.send_message(
                content="Something is already on the anvil. Finish it first.",
                embed=card,
                view=view if view else discord.utils.MISSING,
            )
            return

        pages = await fetch_technique_pages(player["player_id"])
        if not pages:
            raise GameError(
                "You hold no technique pages. A heaven drops them about four "
                "times in a hundred — **/explore** White or Black "
                "Heaven, or take them off a rogue immortal."
            )

        view = InscribeView(player["player_id"], interaction.user, pages)
        await view.read()
        view.build()
        await interaction.response.send_message(
            embed=await pile_card(player["player_id"], pages, view.reading),
            view=view,
        )


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Enlighten(bot))
