"""Reading a character's three traits, and rendering them.

Race, Root and Physique are three tables with the same shape of bonus, so the
queries and the formatting are written once here and used by both the creation
screen and `/profile`. The alternative - each command assembling its own view
of a character - is how two screens end up disagreeing about what a root does.
"""

import discord

from bot import database as db
from bot.formatting import COLOUR_DEFAULT, bar, multiplier, percent, thousands

# Rarity marker, keyed by the `rarities.code` column. A missing key would show
# the code itself rather than nothing, which is the failure mode you want.
RARITY_MARK = {
    "common": "\N{MEDIUM WHITE CIRCLE}",
    "uncommon": "\N{LARGE GREEN CIRCLE}",
    "rare": "\N{LARGE BLUE CIRCLE}",
    "epic": "\N{LARGE PURPLE CIRCLE}",
    "legendary": "\N{LARGE ORANGE CIRCLE}",
    "mythic": "\N{LARGE RED CIRCLE}",
    "divine": "\N{SPARKLES}",
    "unique": "\N{GEM STONE}",
    "extreme": "\N{GEM STONE}",
}

RATE_ICON = "\N{HERB}"
BODY_ICON = "\N{FLEXED BICEPS}"
BOOK_ICON = "\N{OPEN BOOK}"
BLADE_ICON = "\N{CROSSED SWORDS}"
HEART_ICON = "\N{HEAVY BLACK HEART}"
SHIELD_ICON = "\N{SHIELD}"
SPECIAL_ICON = "\N{LARGE BLUE DIAMOND}"


def mark(rarity: str) -> str:
    return RARITY_MARK.get(rarity, "")


# ---------------------------------------------------------------------------
# Reads
# ---------------------------------------------------------------------------


async def fetch_character(player_id: int) -> dict | None:
    """Everything the creation screen and /profile need, in one row.

    Race, root and physique are joined here rather than fetched separately
    because every caller wants all three - and a character with a root but no
    physique is not a state this game has.
    """
    return await db.fetch_one(
        """
        SELECT
            pc.character_name, pc.confirmed_at,
            pc.root_rerolls_left, pc.physique_rerolls_left,
            pc.root_rolls, pc.physique_rolls,

            ra.code AS race_code, ra.name AS race_name,
            ra.specialty AS race_specialty, ra.description AS race_description,
            ra.cultivation_rate_bonus AS race_cultivation,
            ra.physique_rate_bonus    AS race_physique,
            ra.attainment_rate_bonus  AS race_attainment,
            ra.defense_bonus          AS race_defense,
            ra.unmodelled             AS race_unmodelled,

            ro.code AS root_code, ro.name AS root_name, ro.rarity AS root_rarity,
            ro.description AS root_description,
            ro.cultivation_rate_bonus AS root_cultivation,
            ro.physique_rate_bonus    AS root_physique,
            ro.attainment_rate_bonus  AS root_attainment,
            ro.hp_bonus               AS root_hp,
            ro.defense_bonus          AS root_defense,
            ro.special_name           AS root_special_name,
            ro.special_text           AS root_special_text,
            ro.unmodelled             AS root_unmodelled,
            rr.name AS root_rarity_name, rr.colour AS root_colour,

            ph.physique_id, ph.code AS physique_code, ph.name AS physique_name,
            ph.tier AS physique_rarity, ph.description AS physique_description,
            ph.cultivation_rate_bonus AS physique_cultivation,
            ph.physique_rate_bonus    AS physique_physique,
            ph.attainment_rate_bonus  AS physique_attainment,
            ph.hp_multiplier, ph.defense_multiplier, ph.strength_multiplier,
            ph.affinity_path, ph.affinity_bonus,
            ph.special_name           AS physique_special_name,
            ph.special_text           AS physique_special_text,
            ph.unmodelled             AS physique_unmodelled,
            ph.aperture_instability,
            pr.name AS physique_rarity_name, pr.colour AS physique_colour
        FROM player_character pc
        JOIN races ra ON ra.code = pc.race_code
        JOIN roots ro ON ro.code = pc.root_code
        JOIN rarities rr ON rr.code = ro.rarity
        LEFT JOIN player_physique pp ON pp.player_id = pc.player_id
        LEFT JOIN physiques ph ON ph.physique_id = pp.physique_id
        LEFT JOIN rarities pr ON pr.code = ph.tier
        WHERE pc.player_id = %s
        """,
        (player_id,),
    )


async def fetch_path_bonuses(player_id: int) -> dict[str, list[dict]]:
    """Per-Path bonuses, grouped by which trait grants them.

    One query with a tag column rather than three, so the three tables cannot
    drift into being read three different ways.
    """
    rows = await db.fetch_all(
        """
        SELECT 'race' AS source, p.name AS path_name,
               b.attainment_bonus, b.damage_bonus
        FROM player_character pc
        JOIN race_path_bonuses b ON b.race_code = pc.race_code
        JOIN paths p ON p.code = b.path_code
        WHERE pc.player_id = %s

        UNION ALL

        SELECT 'root', p.name, b.attainment_bonus, b.damage_bonus
        FROM player_character pc
        JOIN root_path_bonuses b ON b.root_code = pc.root_code
        JOIN paths p ON p.code = b.path_code
        WHERE pc.player_id = %s

        UNION ALL

        SELECT 'physique', p.name, b.attainment_bonus, b.damage_bonus
        FROM player_physique pp
        JOIN physique_path_bonuses b ON b.physique_id = pp.physique_id
        JOIN paths p ON p.code = b.path_code
        WHERE pp.player_id = %s
        """,
        (player_id, player_id, player_id),
    )
    grouped: dict[str, list[dict]] = {"race": [], "root": [], "physique": []}
    for row in rows:
        grouped[row["source"]].append(row)
    return grouped


async def fetch_trait_effects(player_id: int) -> dict[str, list[dict]]:
    """What the rolled traits grant in the shared effect vocabulary.

    Same shape as `fetch_path_bonuses` and for the same reason: two tables
    saying the same kind of thing must not be read two different ways.

    The magnitude is capped here because `root_stat` and `physique_stat` cap it
    too — a sheet quoting the stored figure would be quoting a number the game
    never uses.
    """
    rows = await db.fetch_all(
        """
        SELECT 'root' AS source, ef.name, ef.emoji,
               LEAST(ef.cap, re.magnitude) AS magnitude,
               -- Rendered by SQL because `is_base` is the only thing that
               -- knows whether a magnitude is points or a fraction, and the
               -- 29.7 points of Body on the Primordial Origin Body read as
               -- a bonus of 2970 per cent for as long as this screen
               -- decided the unit for itself. (No per-cent SIGN in this
               -- comment: psycopg scans the whole string for placeholders,
               -- comments included, and a bare %% before a quote is read as
               -- a malformed one.)
               effect_amount(ef.code, LEAST(ef.cap, re.magnitude)) AS amount,
               ef.is_base
        FROM player_character pc
        JOIN root_effects re ON re.root_code = pc.root_code
        JOIN gu_effects ef ON ef.code = re.effect_code
        WHERE pc.player_id = %s

        UNION ALL

        SELECT 'physique', ef.name, ef.emoji, LEAST(ef.cap, pe.magnitude),
               effect_amount(ef.code, LEAST(ef.cap, pe.magnitude)), ef.is_base
        FROM player_physique pp
        JOIN physique_effects pe ON pe.physique_id = pp.physique_id
        JOIN gu_effects ef ON ef.code = pe.effect_code
        WHERE pp.player_id = %s

        -- Percentages first, then base stats, each by size. Sorting the two
        -- together by raw magnitude compares a count of points against a
        -- fraction and puts 29.7 above a doubling, which is not bigger.
        ORDER BY 6, 4 DESC
        """,
        (player_id, player_id),
    )
    grouped: dict[str, list[dict]] = {"root": [], "physique": []}
    for row in rows:
        grouped[row["source"]].append(row)
    return grouped


def _effect_lines(effects: list[dict]) -> list[str]:
    return [
        f"{row['emoji']} {row['name']}: {row['amount']}" for row in effects
    ]


async def fetch_foundation(player_id: int) -> dict:
    """The stat line, plus the multipliers that produced it."""
    return await db.fetch_one(
        """
        SELECT
            pp.max_hp, pp.current_hp, pp.defense, pp.strength, pp.body_level,
            pb.body_rank, pb.rank_name, pb.path_emoji,
            pc.cultivation, pc.essence, pc.qi, pc.aptitude, pc.focus_path,
            pc.reserve, cultivation_reserve_cap(pc.player_id) AS reserve_cap,
            r.name AS realm_name, r.realm_id,
            -- Off STANDING, not the realm. Both curves keep doubling a
            -- rung past the ladder (0520), so a Venerable was shown
            -- rank 18's figures - less than half of what they hold.
            standing_capacity(pc.player_id, 'qi') AS qi_capacity,
            standing_capacity(pc.player_id, 'essence') AS essence_capacity,
            r.cultivation_required AS realm_floor,
            next.cultivation_required AS next_floor,
            next.name AS next_realm,
            tr.cultivation_multiplier, tr.physique_multiplier,
            tr.attainment_multiplier, tr.hp_multiplier AS total_hp_multiplier
        FROM player_cultivation pc
        JOIN realms r ON r.realm_id = pc.realm_id
        LEFT JOIN realms next ON next.realm_id = pc.realm_id + 1
        LEFT JOIN player_physique pp ON pp.player_id = pc.player_id
        LEFT JOIN player_body pb ON pb.player_id = pc.player_id
        LEFT JOIN player_trait_rates tr ON tr.player_id = pc.player_id
        WHERE pc.player_id = %s
        """,
        (player_id,),
    )


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------


def _flat_lines(char: dict, prefix: str) -> list[str]:
    """The bonuses a trait grants regardless of Path."""
    lines = []
    for column, icon, label in (
        (f"{prefix}_cultivation", RATE_ICON, "Cultivation Speed"),
        (f"{prefix}_physique", BODY_ICON, "Physique Training"),
        (f"{prefix}_attainment", BOOK_ICON, "All Path Attainment"),
        (f"{prefix}_hp", HEART_ICON, "Maximum HP"),
        (f"{prefix}_defense", SHIELD_ICON, "Defense"),
    ):
        value = char.get(column)
        if value:
            lines.append(f"{icon} {label}: {percent(value)}")
    return lines


def _merge_affinity(bonuses: list[dict], char: dict) -> list[dict]:
    """Fold a physique's affinity into its per-Path attainment.

    A physique may carry BOTH a `physique_path_bonuses` row for a Path and an
    `affinity_path` naming the same one, and `player_attainment_rate` adds
    both - Void Sovereign Body is +25% from the row and +18% from the
    affinity, and a Void cultivator really does learn Space at +43%.

    Rendered separately that came out as two identical-looking "Space
    Attainment" lines, which reads as the screen repeating itself rather than
    as two contributions. So they are added here and shown once, which is the
    figure a player is actually comparing.
    """
    path = char.get("affinity_path")
    extra = (char.get("affinity_bonus") or 1) - 1
    if not path or not extra:
        return bonuses

    merged = [dict(row) for row in bonuses]
    for row in merged:
        if row["path_name"].replace(" Path", "").lower() == path.lower():
            row["attainment_bonus"] = (row["attainment_bonus"] or 0) + extra
            return merged

    # An affinity for a Path the physique has no other opinion about.
    merged.append({
        "path_name": path.title(),
        "attainment_bonus": extra,
        "damage_bonus": 0,
    })
    return merged


def _path_lines(bonuses: list[dict]) -> list[str]:
    lines = []
    for row in bonuses:
        name = row["path_name"].replace(" Path", "")
        if row["attainment_bonus"]:
            lines.append(f"{BOOK_ICON} {name} Attainment: {percent(row['attainment_bonus'])}")
        if row["damage_bonus"]:
            lines.append(f"{BLADE_ICON} {name} Damage: {percent(row['damage_bonus'])}")
    return lines


def _unmodelled_lines(payload: dict | None) -> list[str]:
    """Designed effects with no system behind them yet.

    Shown rather than hidden - they are part of what the trait *is* - but
    italicised and footnoted, because a player reading a bonus that does
    nothing and not being told is worse than not listing it.
    """
    if not payload:
        return []
    return [f"*{label}: {value}*" for label, value in payload.items()]


def render_character(
    char: dict,
    bonuses: dict[str, list[dict]],
    foundation: dict,
    effects: dict[str, list[dict]],
    *,
    display_name: str,
    avatar_url: str | None = None,
) -> discord.Embed:
    """The character sheet, used by both /register and /profile."""
    confirmed = char["confirmed_at"] is not None
    colour = discord.Colour(char["root_colour"] or COLOUR_DEFAULT.value)
    if char["physique_rarity"] in ("unique", "extreme"):
        colour = discord.Colour(char["physique_colour"])

    title = char["character_name"] or display_name
    card = discord.Embed(
        title=f"\N{DNA DOUBLE HELIX} {title}" if confirmed else "\N{DNA DOUBLE HELIX} Character Setup",
        colour=colour,
    )
    if avatar_url:
        card.set_thumbnail(url=avatar_url)

    status = "\N{WHITE HEAVY CHECK MARK} Confirmed" if confirmed else "Choosing"
    card.description = f"{display_name} \N{BULLET} {status}"

    # -- Race ---------------------------------------------------------------
    race_lines = [f"**{char['race_name']}** — *{char['race_description']}*"]
    race_lines += _flat_lines(char, "race")
    race_lines += _path_lines(bonuses["race"])
    race_lines += _unmodelled_lines(char["race_unmodelled"])
    card.add_field(
        name="\N{DROP OF BLOOD} Race",
        value="\n".join(race_lines),
        inline=False,
    )

    # -- Root ---------------------------------------------------------------
    rerolls = (
        f" — {char['root_rerolls_left']} reroll(s) left" if not confirmed else ""
    )
    root_lines = [
        f"{mark(char['root_rarity'])} **{char['root_name']}** "
        f"({char['root_rarity_name']}){rerolls}",
        f"*{char['root_description']}*",
    ]
    root_lines += _flat_lines(char, "root")
    root_lines += _path_lines(bonuses["root"])
    root_lines += _effect_lines(effects["root"])
    if char["root_special_name"]:
        root_lines.append(
            f"{SPECIAL_ICON} **{char['root_special_name']}** — {char['root_special_text']}"
        )
    root_lines += _unmodelled_lines(char["root_unmodelled"])
    card.add_field(name="\N{SEEDLING} Root", value="\n".join(root_lines), inline=False)

    # -- Physique -----------------------------------------------------------
    if char["physique_name"]:
        rerolls = (
            f" — {char['physique_rerolls_left']} reroll(s) left" if not confirmed else ""
        )
        phys_lines = [
            f"{mark(char['physique_rarity'])} **{char['physique_name']}** "
            f"({char['physique_rarity_name']}){rerolls}",
            f"*{char['physique_description']}*",
        ]
        for value, icon, label in (
            (char["hp_multiplier"], HEART_ICON, "Maximum HP"),
            (char["defense_multiplier"], SHIELD_ICON, "Defense"),
            (char["strength_multiplier"], BODY_ICON, "Strength"),
        ):
            # Stored as multipliers rather than fractions; shown as the
            # fraction, because "+25%" is what a player compares.
            if value and value != 1:
                phys_lines.append(f"{icon} {label}: {percent(value - 1)}")
        phys_lines += _flat_lines(char, "physique")
        # "Attainment", not "affinity". `affinity_bonus` is stored as a
        # multiplier on its own column, but what it DOES is add to
        # `player_attainment_rate` beside the Race and Root per-Path bonuses -
        # one number reached from two tables. Calling it something else on the
        # one screen where a player compares them made two words for one
        # mechanic. "Affinity" still means what it means in /refinegu, where it
        # is a material agreeing with a Path rather than how fast anybody
        # learns.
        phys_lines += _path_lines(_merge_affinity(bonuses["physique"], char))
        phys_lines += _effect_lines(effects["physique"])
        if char["physique_special_name"]:
            phys_lines.append(
                f"{SPECIAL_ICON} **{char['physique_special_name']}** — "
                f"{char['physique_special_text']}"
            )
        phys_lines += _unmodelled_lines(char["physique_unmodelled"])
        if char["aperture_instability"]:
            phys_lines.append(
                "\N{WARNING SIGN} **Aperture Instability** — this body fights back "
                "as mortal cultivation progresses."
            )
        card.add_field(
            name="\N{FLEXED BICEPS} Physique",
            value="\n".join(phys_lines),
            inline=False,
        )

    # -- Foundation ---------------------------------------------------------
    card.add_field(
        name="\N{GEM STONE} Foundation Stats",
        value=(
            f"{HEART_ICON} HP {thousands(foundation['max_hp'])}  \N{BULLET}  "
            f"{SHIELD_ICON} DEF {thousands(foundation['defense'])}  \N{BULLET}  "
            f"{BODY_ICON} STR {thousands(foundation['strength'])}\n"
            f"\N{DROPLET} QI {thousands(foundation['qi_capacity'])}  \N{BULLET}  "
            f"\N{FOUR LEAF CLOVER} APT {foundation['aptitude']}  \N{BULLET}  "
            f"{body_line(foundation)}\n"
            f"{RATE_ICON} Cultivation {multiplier(foundation['cultivation_multiplier'])}  \N{BULLET}  "
            f"{BODY_ICON} Physique {multiplier(foundation['physique_multiplier'])}  \N{BULLET}  "
            f"{BOOK_ICON} Attainment {multiplier(foundation['attainment_multiplier'])}"
        ),
        inline=False,
    )

    if confirmed:
        card.add_field(
            name="Cultivation",
            value=cultivation_bar(foundation),
            inline=False,
        )
        card.set_footer(text="Italic lines are designed but not yet wired to a system.")
    else:
        card.set_footer(
            text=(
                f"Race is chosen \N{BULLET} Root roll {char['root_rolls']} \N{BULLET} "
                f"Physique roll {char['physique_rolls']} \N{BULLET} "
                "Confirming locks this character and starts your cultivation."
            )
        )
    return card


def body_line(foundation: dict) -> str:
    """What the body is called, falling back to the number when it has no name.

    A rank with no path chosen has no name to give, which is exactly the state
    /physique exists to resolve - so the profile states the rank plainly and
    leaves the invitation to the screen that can act on it.
    """
    if foundation.get("rank_name"):
        return f"{foundation['path_emoji']} {foundation['rank_name']}"
    if foundation.get("body_rank"):
        return f"Body rank {foundation['body_rank']}"
    return f"Body level {foundation['body_level']}"


def cultivation_bar(foundation: dict) -> str:
    """Progress toward the next realm, as a filling bar.

    Nothing ticks: the total is settled from elapsed time whenever somebody
    looks, so the bar is always current and there is no job to fall behind.
    """
    if foundation["next_floor"] is None:
        return (
            f"**{foundation['realm_name']}** — the top of the ladder.\n"
            f"{thousands(foundation['cultivation'])} cultivation."
        )

    span = foundation["next_floor"] - foundation["realm_floor"]
    into = foundation["cultivation"] - foundation["realm_floor"]
    lines = [
        f"**{foundation['realm_name']}**",
        f"{bar(into, span, width=18)}  {percent(into / span if span else 0, signed=False)}",
        f"{thousands(into)} / {thousands(span)} toward **{foundation['next_realm']}**",
    ]
    # A full bar is a bottleneck, not an achievement: cultivation stops there
    # and stays stopped until somebody takes the realm. What is earned in
    # the meantime is held rather than lost, so the bar says where it went -
    # a player who cannot see the reserve has no reason to believe in it.
    # Subscripted, not .get(): two different queries feed this renderer and
    # a missing column should raise here rather than silently render a
    # screen that says a player is holding nothing.
    held = foundation["reserve"] or 0
    if into >= span:
        lines.append(
            f"\N{HIGH VOLTAGE SIGN} **The bottleneck.** Nothing more accrues "
            "here — **/breakthrough**."
        )
    if held:
        lines.append(
            f"\N{DROPLET} **{thousands(held)}** of "
            f"{thousands(foundation['reserve_cap'])} held in reserve, "
            "poured in when you cross."
        )
    return "\n".join(lines)
