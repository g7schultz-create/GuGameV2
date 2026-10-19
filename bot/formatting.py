"""Shared presentation: colours, number formatting, and duration parsing.

Kept in one module so a Path never renders green in one command and blue in
the next, and so "what does an advantage look like" is answered once.
"""

import re
from decimal import ROUND_HALF_UP, Decimal

import discord

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------

COLOUR_DEFAULT = discord.Colour(0x5B4B8A)
COLOUR_GOOD = discord.Colour(0x3BA55D)
COLOUR_BAD = discord.Colour(0xED4245)
COLOUR_INFO = discord.Colour(0x5865F2)

# How each matchup interaction reads in an embed. Keys are the `code` column of
# matchup_interactions, so adding an interaction in a migration surfaces here as
# a missing key rather than as a silently blank line.
INTERACTION_DISPLAY = {
    "major_advantage": ("\N{UPWARDS BLACK ARROW}\N{UPWARDS BLACK ARROW}", "Major Advantage"),
    "advantage": ("\N{UPWARDS BLACK ARROW}", "Advantage"),
    "neutral": ("\N{EM DASH}", "Neutral"),
    "resistance": ("\N{DOWNWARDS BLACK ARROW}", "Resistance"),
    "immunity": ("\N{HEAVY MULTIPLICATION X}", "Immunity"),
}


def interaction_label(code: str) -> str:
    arrow, name = INTERACTION_DISPLAY.get(code, ("?", code))
    return f"{arrow} {name}"


# ---------------------------------------------------------------------------
# Numbers
# ---------------------------------------------------------------------------


# Where a number stops being read and starts being estimated. Below this a
# player is still comparing digits - 12,480 stones against 9,900 - and above it
# nobody is: 1,829,634 health is "about one and eight" however it is printed.
SHORTHAND_FROM = 100_000_000


def thousands(value: int | Decimal | None) -> str:
    """A number as a player reads it, in full up to a hundred million.

    0248 put every stat on a four-times-a-major-realm ladder, so an Ancient
    Realm cultivator carries eight figures of health and a rank 9 dungeon boss
    nine. A comma-grouped 150,994,944 is a number somebody has to count the
    groups of before they know how big it is.
    """
    if value is None:
        return "-"

    n = int(value)
    size = abs(n)
    if size < SHORTHAND_FROM:
        return f"{n:,}"

    # The unit is chosen against the ROUNDED value, so 999.6M comes out as
    # "1B" rather than the "1000M" nobody writes.
    if size >= 999_500_000_000:
        unit, suffix = 10 ** 12, "T"
    elif size >= 999_500_000:
        unit, suffix = 10 ** 9, "B"
    else:
        unit, suffix = 10 ** 6, "M"

    scaled = n / unit
    if abs(scaled) >= 100:
        told = f"{scaled:.0f}"
    elif abs(scaled) >= 10:
        told = f"{scaled:.1f}"
    else:
        told = f"{scaled:.2f}"

    # 1.50B reads as precision it does not have; 1.5B is the same number.
    if "." in told:
        told = told.rstrip("0").rstrip(".")
    return f"{told}{suffix}"


def percent(value: Decimal | float | None, *, signed: bool = True) -> str:
    """A modifier as a whole percentage. 0.25 -> '+25%'.

    Rounded to the integer, never a decimal place: every number a player reads
    in this bot is whole, so a stray '+12.5%' beside a column of round figures
    reads as a different kind of quantity rather than as more precision.

    A non-zero value that would round to 0% is floored to 1% (or -1%) instead,
    because '+0%' beside a bonus that is genuinely doing something is worse
    than being one point out.
    """
    if value is None:
        return "-"
    pct = Decimal(str(value)) * 100
    rounded = int(pct.to_integral_value(rounding=ROUND_HALF_UP))
    if rounded == 0 and pct != 0:
        rounded = 1 if pct > 0 else -1
    if signed and rounded > 0:
        return f"+{rounded}%"
    return f"{rounded}%"


def effect_amount(value: Decimal | float | None, *, is_base: bool) -> str:
    """What an effect gives, in the unit that effect is actually measured in.

    A base stat is points on a body, not a fraction of one: ten points of
    Sinew printed as '+1000%' is not a rounding problem, it is a different
    quantity. `/stats` has said so since it was written; the gear, auction
    and trade screens never had to, because no piece of equipment carried a
    flat stat until 0407 paid a boot's wasted Evasion into Sinew.
    """
    if value is None:
        return "-"
    if is_base:
        # The sign comes from the number, not from in front of it. Writing a
        # plus and letting the number write its own minus is how the SQL twin
        # of this function had Hollow Victory reading "Body +-12" - a penalty
        # introducing itself as a bonus. Fixed in both places in 0436.
        #
        # And a non-zero amount never rounds away, since 0446: a base stat is
        # multiplied by the wearer's realm afterwards, so four tenths of a
        # point of Hide is millions of hide on a developed body and "+0" is
        # the one reading that is certainly wrong. Same rule `percent` has
        # always had one branch below.
        raw = Decimal(str(value))
        points = int(raw.to_integral_value(rounding=ROUND_HALF_UP))
        if points == 0 and raw != 0:
            points = 1 if raw > 0 else -1
        return f"{points}" if points < 0 else f"+{points}"
    return percent(value)


def multiplier(value: Decimal | float | None) -> str:
    """A multiplier shown as the whole-percentage bonus it represents.

    1.25 -> '+25%'. Multipliers are stored as multipliers because that is how
    the SQL applies them, but '×1.25' is the only fractional number a player
    would otherwise see, and it means the same thing as the +25% written
    everywhere else.
    """
    if value is None:
        return "-"
    return percent(Decimal(str(value)) - 1)


def bar(current: int, maximum: int, width: int = 12) -> str:
    """A text meter. Used for HP and progress toward the next realm."""
    if maximum <= 0:
        return "\N{LIGHT SHADE}" * width
    filled = max(0, min(width, round(width * current / maximum)))
    return "\N{FULL BLOCK}" * filled + "\N{LIGHT SHADE}" * (width - filled)


# ---------------------------------------------------------------------------
# Durations
# ---------------------------------------------------------------------------

_DURATION_PART = re.compile(r"(\d+)\s*([hm])", re.IGNORECASE)


def parse_duration(text: str) -> int:
    """'8h', '90m', '2h30m' -> seconds. A bare number is read as hours.

    Raises ValueError with something a player can act on, because this is the
    one free-text argument in the whole command surface.
    """
    raw = text.strip().lower()
    if not raw:
        raise ValueError("Give a duration, for example `8h`, `90m` or `2h30m`.")

    if raw.isdigit():
        return int(raw) * 3600

    parts = _DURATION_PART.findall(raw)
    if not parts or "".join(f"{n}{u}" for n, u in parts) != raw.replace(" ", ""):
        raise ValueError(
            f"`{text}` is not a duration. Use hours and minutes, "
            "for example `8h`, `90m` or `2h30m`."
        )

    seconds = 0
    for amount, unit in parts:
        seconds += int(amount) * (3600 if unit == "h" else 60)
    if seconds <= 0:
        raise ValueError("A session has to last longer than zero.")
    return seconds


def humanise_duration(seconds: float) -> str:
    """Seconds -> '8h 30m'. Rounds to the minute; sessions are hours long."""
    total = int(seconds)
    if total < 60:
        return f"{total}s"
    hours, remainder = divmod(total, 3600)
    minutes = remainder // 60
    if hours and minutes:
        return f"{hours}h {minutes}m"
    if hours:
        return f"{hours}h"
    return f"{minutes}m"


# ---------------------------------------------------------------------------
# Embeds
# ---------------------------------------------------------------------------


# Discord refuses a whole message for one oversized field, so this is a hard
# limit rather than a style preference:
#
#     400 Bad Request (50035): In embeds.0.fields.2.value:
#     Must be 1024 or fewer in length
#
# The whole card is rejected, which is why a screen that overflows does not
# look untidy - it looks broken. /equipment did exactly that for anybody
# carrying enough manuals to fill the shelf listing.
FIELD_LIMIT = 1024


def fit_field(
    entries: list[str],
    *,
    sep: str = "\n",
    empty: str = "*Nothing.*",
    noun: str = "more",
) -> str:
    """As many entries as fit in a field, and an honest count of what did not.

    Paging is the real answer and every screen that can page does. This is the
    backstop underneath it: a page size is chosen from a typical entry, and one
    unusually long name should not take the message down with it.
    """
    if not entries:
        return empty

    out: list[str] = []
    used = 0
    for i, entry in enumerate(entries):
        tail = f"{sep}*… and {len(entries) - i} {noun}*"
        if used + len(entry) + len(sep) + len(tail) > FIELD_LIMIT and out:
            return sep.join(out) + tail
        out.append(entry)
        used += len(entry) + len(sep)
    return sep.join(out)


def embed(title: str, description: str = "", *, colour: discord.Colour = COLOUR_DEFAULT) -> discord.Embed:
    return discord.Embed(title=title, description=description, colour=colour)


def error_embed(message: str) -> discord.Embed:
    return discord.Embed(
        title="That did not work",
        description=message,
        colour=COLOUR_BAD,
    )
