"""Servants on rarer ground (0465).

Until 0465 `servant_may_gather` bounded every servant to common and uncommon,
so every rare, epic and legendary material in the mortal realms was closed at
every rank. The only route was the unaimable lottery in `servant_settle`.
"""

from decimal import Decimal

import psycopg
import pytest


BANDS = ("rare", "epic", "legendary")


def share(conn, rarity: str, rank: int):
    return conn.execute(
        "SELECT servant_rarity_share(%s, %s::smallint)", (rarity, rank)
    ).fetchone()[0]


# ---------------------------------------------------------------------------
# The rate
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("rarity", ["common", "uncommon"])
@pytest.mark.parametrize("rank", [1, 9, 18])
def test_ordinary_ground_did_not_move(conn, rarity, rank):
    """The one that matters. Every servant now working carries on unchanged."""
    assert share(conn, rarity, rank) == 1


def test_rarer_ground_gives_less_of_itself(conn):
    rates = [share(conn, r, 18) for r in BANDS]
    assert rates == sorted(rates, reverse=True), dict(zip(BANDS, rates))
    assert rates[0] < 1, "rare ground is as generous as a meadow"


@pytest.mark.parametrize("rarity", BANDS)
def test_nothing_is_reachable_below_its_door(conn, rarity):
    door = conn.execute(
        "SELECT min_rank FROM servant_rarity_rates WHERE rarity = %s", (rarity,)
    ).fetchone()[0]
    if door > 1:
        assert share(conn, rarity, door - 1) == 0
    assert share(conn, rarity, door) > 0


@pytest.mark.parametrize("rarity", BANDS)
def test_going_on_cultivating_pays(conn, rarity):
    """The share grows with rank past the door, the same shape as the
    immortal haul."""
    door = conn.execute(
        "SELECT min_rank FROM servant_rarity_rates WHERE rarity = %s", (rarity,)
    ).fetchone()[0]
    assert share(conn, rarity, 18) > share(conn, rarity, door)


def test_no_rank_makes_rare_ground_a_meadow(conn):
    """Clamped at one, or a high enough rank would make the common band
    pointless."""
    for rarity, in conn.execute(
        "SELECT rarity FROM servant_rarity_rates"
    ).fetchall():
        assert share(conn, rarity, 99) <= 1


def test_mythic_and_above_stay_shut(conn):
    """The ask was rare to legendary. A rarity with no rate row is closed,
    which is how that holds without a second list saying so."""
    closed = conn.execute(
        """
        SELECT ra.code FROM rarities ra
        WHERE ra.sort_order > (SELECT sort_order FROM rarities
                               WHERE code = 'legendary')
        """
    ).fetchall()
    assert closed, "there is nothing above legendary to check"
    for (code,) in closed:
        assert share(conn, code, 18) == 0, f"{code} opened"


# ---------------------------------------------------------------------------
# Where a servant may be sent
# ---------------------------------------------------------------------------


@pytest.fixture
def a_servant(conn, make_player):
    """One servant at a chosen realm, with nothing else attached to them."""

    def _make(rank: int = 18):
        player_id = make_player("Master")
        realm_id = conn.execute(
            "SELECT realm_id FROM realms WHERE rank = %s ORDER BY realm_id LIMIT 1",
            (rank,),
        ).fetchone()[0]
        code = conn.execute(
            "SELECT servant_code FROM servants ORDER BY servant_code LIMIT 1"
        ).fetchone()[0]
        return conn.execute(
            "INSERT INTO player_servants (player_id, servant_code, realm_id) "
            "VALUES (%s, %s, %s) RETURNING player_servant_id",
            (player_id, code, realm_id),
        ).fetchone()[0]

    return _make


def mortal_material(conn, rarity: str):
    row = conn.execute(
        """
        SELECT m.code FROM materials m
        WHERE m.category IN ('gathering', 'beast') AND m.rarity = %s
          AND NOT is_immortal_material(m.code)
        ORDER BY m.code LIMIT 1
        """,
        (rarity,),
    ).fetchone()
    return row[0] if row else None


def test_a_deep_servant_may_be_sent_after_rare_ground(conn, a_servant):
    code = mortal_material(conn, "rare")
    if code is None:
        pytest.skip("no mortal rare material to send anybody after")
    assert conn.execute(
        "SELECT servant_may_gather(%s, %s)", (code, a_servant(18))
    ).fetchone()[0]


def test_a_shallow_servant_is_kept_off_legendary_ground(conn, a_servant):
    code = mortal_material(conn, "legendary")
    if code is None:
        pytest.skip("no mortal legendary material")
    assert not conn.execute(
        "SELECT servant_may_gather(%s, %s)", (code, a_servant(1))
    ).fetchone()[0]
    assert conn.execute(
        "SELECT servant_may_gather(%s, %s)", (code, a_servant(18))
    ).fetchone()[0]


def test_the_focus_screen_and_the_rule_agree(conn, a_servant):
    """`servant_focus_set` must accept whatever `servant_may_gather` offers,
    or the picker shows something that is then refused."""
    servant_id = a_servant(18)
    code = mortal_material(conn, "rare")
    if code is None:
        pytest.skip("no mortal rare material")

    owner = conn.execute(
        "SELECT player_id FROM player_servants WHERE player_servant_id = %s",
        (servant_id,),
    ).fetchone()[0]
    conn.execute(
        "SELECT * FROM servant_focus_set(%s, %s, %s)",
        (owner, servant_id, [code]),
    )
    assert conn.execute(
        "SELECT material_code FROM servant_focus WHERE player_servant_id = %s",
        (servant_id,),
    ).fetchone()[0] == code


def test_immortal_ground_is_still_its_own_gate(conn, a_servant):
    """0465 widened the mortal band and must not have opened immortal ground
    to somebody who has not crossed."""
    code = conn.execute(
        """
        SELECT m.code FROM materials m
        WHERE m.category IN ('gathering', 'beast')
          AND is_immortal_material(m.code)
        ORDER BY m.code LIMIT 1
        """
    ).fetchone()
    if code is None:
        pytest.skip("no immortal material")
    servant_id = a_servant(1)
    assert not conn.execute(
        "SELECT servant_may_gather(%s, %s)", (code[0], servant_id)
    ).fetchone()[0]


# ---------------------------------------------------------------------------
# Ascension (0478)
#
# Five stars used to be the end of a servant and the sixteenth duplicate was
# a dead card. It now buys a tier, and the stars are the price.
# ---------------------------------------------------------------------------


@pytest.fixture
def a_servant_at(conn, make_player):
    """One servant of a chosen tier, at a chosen number of stars."""

    def _make(tier: int = 1, stars: int = 5):
        player_id = make_player("Master")
        code = conn.execute(
            "SELECT servant_code FROM servants WHERE tier = %s "
            "ORDER BY servant_code LIMIT 1",
            (tier,),
        ).fetchone()
        if code is None:
            pytest.skip(f"no servant kind at tier {tier}")
        realm_id = conn.execute(
            "SELECT realm_id FROM realms ORDER BY rank LIMIT 1"
        ).fetchone()[0]
        servant_id = conn.execute(
            "INSERT INTO player_servants (player_id, servant_code, realm_id, stars) "
            "VALUES (%s, %s, %s, %s) RETURNING player_servant_id",
            (player_id, code[0], realm_id, stars),
        ).fetchone()[0]
        return player_id, servant_id

    return _make


def top_tier(conn) -> int:
    return conn.execute("SELECT max(tier) FROM servant_tiers").fetchone()[0]


def test_a_servant_below_the_cap_cannot_ascend(conn, a_servant_at):
    player_id, servant_id = a_servant_at(tier=1, stars=4)
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute("SELECT * FROM servant_ascend(%s, %s)",
                     (player_id, servant_id))


def test_five_stars_buys_a_tier(conn, a_servant_at):
    player_id, servant_id = a_servant_at(tier=1, stars=5)
    was, now, stars = conn.execute(
        "SELECT was_tier, now_tier, stars FROM servant_ascend(%s, %s)",
        (player_id, servant_id),
    ).fetchone()

    assert now == was + 1
    assert stars == conn.execute(
        "SELECT game_config_value('servant_ascend_stars')::int"
    ).fetchone()[0]


def test_the_kind_is_untouched(conn, a_servant_at):
    """`servants.tier` is template data. Promoting one copy must not promote
    every other player's."""
    player_id, servant_id = a_servant_at(tier=1, stars=5)
    code, before = conn.execute(
        "SELECT ps.servant_code, s.tier FROM player_servants ps "
        "JOIN servants s ON s.servant_code = ps.servant_code "
        "WHERE ps.player_servant_id = %s",
        (servant_id,),
    ).fetchone()

    conn.execute("SELECT * FROM servant_ascend(%s, %s)", (player_id, servant_id))

    assert conn.execute(
        "SELECT tier FROM servants WHERE servant_code = %s", (code,)
    ).fetchone()[0] == before


def test_a_servant_at_the_top_is_told_so(conn, a_servant_at):
    player_id, servant_id = a_servant_at(tier=top_tier(conn), stars=5)
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute("SELECT * FROM servant_ascend(%s, %s)",
                     (player_id, servant_id))


def test_somebody_elses_servant_is_refused(conn, a_servant_at, make_player):
    _, servant_id = a_servant_at(tier=1, stars=5)
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute("SELECT * FROM servant_ascend(%s, %s)",
                     (make_player("Thief"), servant_id))


@pytest.mark.parametrize("tier", [1, 2, 3, 4, 5, 6])
def test_ascending_is_near_enough_to_even(conn, a_servant_at, tier):
    """The claim the migration makes, at every tier it can be made at.

    The first draft reset to one star and the probe refused it: the hourly
    haul rises about half again per tier while five stars is worth exactly
    twice one, so a full reset is a real loss above tier 1.
    """
    player_id, servant_id = a_servant_at(tier=tier, stars=5)
    before = conn.execute(
        "SELECT servant_haul_per_hour(%s)", (servant_id,)
    ).fetchone()[0]

    after = conn.execute(
        "SELECT per_hour FROM servant_ascend(%s, %s)", (player_id, servant_id)
    ).fetchone()[0]

    assert after >= before * Decimal("0.9"), (
        f"tier {tier}: {before} an hour became {after}"
    )


def test_the_haul_reads_the_copys_tier(conn, a_servant_at):
    """`servant_haul_per_hour` used to join the kind's tier. If it still did,
    ascending would change nothing at all."""
    player_id, servant_id = a_servant_at(tier=1, stars=5)
    conn.execute("SELECT * FROM servant_ascend(%s, %s)", (player_id, servant_id))
    # Level the stars so only the tier differs.
    conn.execute(
        "UPDATE player_servants SET stars = 5 WHERE player_servant_id = %s",
        (servant_id,),
    )
    ascended = conn.execute(
        "SELECT servant_haul_per_hour(%s)", (servant_id,)
    ).fetchone()[0]

    conn.execute(
        "UPDATE player_servants SET ascension = 0 WHERE player_servant_id = %s",
        (servant_id,),
    )
    plain = conn.execute(
        "SELECT servant_haul_per_hour(%s)", (servant_id,)
    ).fetchone()[0]

    assert ascended > plain


def test_nothing_reads_a_copys_tier_off_the_kind(conn):
    """The guard that matters. Two functions joined `t.tier = s.tier` and both
    had to move; a third appearing later is the thing to catch."""
    offenders = conn.execute(
        """
        SELECT p.proname FROM pg_proc p
        WHERE p.pronamespace = 'public'::regnamespace
          AND p.proname NOT IN ('servant_roll', 'servant_tier_of')
          AND p.prosrc LIKE '%t.tier = s.tier%'
        """
    ).fetchall()
    assert offenders == []


def test_no_screen_reads_a_copys_tier_off_the_kind():
    """Same guard, for the two cogs that show a servant."""
    import pathlib

    root = pathlib.Path(__file__).resolve().parent.parent
    for name in ("bot/cogs/servants.py", "bot/cogs/trade.py"):
        text = (root / name).read_text(encoding="utf-8")
        assert "t.tier = s.tier" not in text, f"{name} shows the kind's tier"
        assert "servant_tier_of" in text, f"{name} never asks for the copy's"
