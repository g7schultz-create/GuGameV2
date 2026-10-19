"""Understanding as the new cultivation (0489-0490).

Everything below rank 18 is a meter filled with hours and pills. Above it a
cultivator advances by understanding their own Dao, and understanding accrues
by acting in accordance with it.

Two things had to be true before any of this could work, and neither was:

    player_techniques.times_used was DEAD - 0 everywhere, no writer. It is the
    only counter that separates swinging a Path technique in a fight from
    buying insight with pills, which is the meter this replaces. 0489 wired it
    into player_swing, the one function all seven fighting lanes go through.

    Two of the six axes record no deed at all. A root is rolled rather than
    chosen and nothing is done in accordance with one; a destiny would need
    sixty separate hooks. They stay aspects and feed nothing, which these
    tests pin so it cannot be forgotten later.
"""

import psycopg
import pytest


FEEDING = ("path", "body", "craft", "gu")


def total(conn, player_id):
    return conn.execute(
        "SELECT dao_understanding_total(%s)", (player_id,)
    ).fetchone()[0]


def rung(conn, player_id):
    return conn.execute("SELECT venerable_rank_of(%s)", (player_id,)).fetchone()[0]


def understanding(conn, player_id):
    return conn.execute(
        "SELECT source_kind, source_code, gained, understanding, weight "
        "FROM dao_understanding(%s) ORDER BY ordinal",
        (player_id,),
    ).fetchall()


@pytest.fixture
def venerable(conn, make_player):
    """A cultivator with a history, a body, a craft and a technique to swing."""

    def _make(paths=(("sword", 90_000),), body="buddhist", craft="mining", craft_level=50):
        pid = make_player("Venerable")
        conn.execute(
            "INSERT INTO player_cultivation (player_id, realm_id, cultivation) "
            "VALUES (%s, (SELECT min(realm_id) FROM realms), 0)",
            (pid,),
        )
        conn.execute(
            "INSERT INTO player_physique (player_id, physique_id, body_path, body_level) "
            "VALUES (%s, (SELECT min(physique_id) FROM physiques), %s, 100)",
            (pid, body),
        )
        if craft is not None:
            conn.execute(
                "INSERT INTO player_professions (player_id, profession, level) "
                "VALUES (%s, %s, %s)",
                (pid, craft, craft_level),
            )
        for code, insight in paths:
            conn.execute(
                "INSERT INTO player_path_attainment (player_id, path_code, insight, tier) "
                "VALUES (%s, %s, %s, 5)",
                (pid, code, insight),
            )
        return pid

    return _make


@pytest.fixture
def swinger(conn):
    """A technique standing on one named path, learned, plus something to hit."""

    def _make(player_id, path_code="sword"):
        tid = conn.execute(
            """
            SELECT t.technique_id FROM techniques t
            JOIN technique_paths tp ON tp.technique_id = t.technique_id
            WHERE tp.path_code = %s
            GROUP BY t.technique_id HAVING count(*) = 1
            ORDER BY t.technique_id LIMIT 1
            """,
            (path_code,),
        ).fetchone()
        assert tid is not None, f"no single-path {path_code} technique seeded"
        tid = tid[0]
        conn.execute(
            "INSERT INTO player_techniques (player_id, technique_id) VALUES (%s, %s) "
            "ON CONFLICT DO NOTHING",
            (player_id, tid),
        )
        species = conn.execute(
            "SELECT species_id FROM creature_species ORDER BY species_id LIMIT 1"
        ).fetchone()[0]
        return tid, species

    return _make


def swing(conn, player_id, technique_id, species_id, times=1):
    for _ in range(times):
        conn.execute(
            "SELECT player_swing(%s, %s, %s, 1000000::bigint, 0::bigint)",
            (player_id, technique_id, species_id),
        ).fetchall()


# ---------------------------------------------------------------------------
# The counter 0489 had to resurrect
# ---------------------------------------------------------------------------


def test_a_swing_counts_a_cast(conn, venerable, swinger):
    """`times_used` was 0 in every row and no function wrote it."""
    pid = venerable()
    tid, species = swinger(pid)
    swing(conn, pid, tid, species, times=3)
    assert conn.execute(
        "SELECT times_used FROM player_techniques WHERE player_id = %s AND technique_id = %s",
        (pid, tid),
    ).fetchone()[0] == 3


def test_a_borrowed_technique_ticks_nothing(conn, venerable, swinger):
    """`player_techniques` is the learned shelf; UPDATE, never upsert.

    A technique swung straight off a manual was never made your own, so it
    accrues no understanding of its Path - and swinging it must not invent a
    shelf row either.
    """
    pid = venerable()
    tid, species = swinger(pid)
    conn.execute("DELETE FROM player_techniques WHERE player_id = %s", (pid,))
    swing(conn, pid, tid, species)
    assert conn.execute(
        "SELECT count(*) FROM player_techniques WHERE player_id = %s", (pid,)
    ).fetchone()[0] == 0


def test_a_cast_is_shared_out_between_the_paths_of_a_technique(conn, venerable):
    """A forged two-Path technique counts half to each, not once to both.

    Otherwise a cultivator could double their understanding by forging wide.
    """
    pid = venerable()
    tid = conn.execute(
        """
        SELECT t.technique_id FROM techniques t
        JOIN technique_paths tp ON tp.technique_id = t.technique_id
        GROUP BY t.technique_id HAVING count(*) > 1
        ORDER BY t.technique_id LIMIT 1
        """
    ).fetchone()
    if tid is None:
        pytest.skip("no multi-path technique seeded")
    tid = tid[0]
    species = conn.execute(
        "SELECT species_id FROM creature_species ORDER BY species_id LIMIT 1"
    ).fetchone()[0]
    conn.execute(
        "INSERT INTO player_techniques (player_id, technique_id) VALUES (%s, %s)",
        (pid, tid),
    )
    swing(conn, pid, tid, species, times=4)
    shared = conn.execute(
        """
        SELECT sum(path_casts_of(%s, tp.path_code))
        FROM technique_paths tp WHERE tp.technique_id = %s
        """,
        (pid, tid),
    ).fetchone()[0]
    assert round(float(shared), 2) == 4.00, shared


def test_a_rehearsal_is_not_a_cast(conn, venerable, swinger):
    """`trial_rehearse` and `delve_rehearse` run player_swing to forecast.

    Both abort the subtransaction they do it in, so a forecast must leave the
    counter where it was - otherwise opening a screen would advance a Dao.
    """
    pid = venerable()
    tid, species = swinger(pid)
    swing(conn, pid, tid, species, times=2)
    before = conn.execute(
        "SELECT times_used FROM player_techniques WHERE player_id = %s", (pid,)
    ).fetchone()[0]
    assert before == 2

    conn.execute("SELECT delve_rehearse(%s, %s)", (pid, species)).fetchall()
    conn.execute("SELECT trial_rehearse(%s, %s)", (pid, species)).fetchall()

    after = conn.execute(
        "SELECT times_used FROM player_techniques WHERE player_id = %s", (pid,)
    ).fetchone()[0]
    assert after == before, "a forecast advanced the Dao"


# ---------------------------------------------------------------------------
# Which axes feed, and which only look like they do
# ---------------------------------------------------------------------------


def test_the_four_feeding_axes_have_a_rate(conn):
    kinds = {
        r[0] for r in conn.execute("SELECT source_kind FROM dao_deed_rates").fetchall()
    }
    assert kinds == set(FEEDING)


@pytest.mark.parametrize("kind,code", [("root", "iron_root"), ("destiny", "killing_intent")])
def test_an_axis_that_records_nothing_says_so(conn, kind, code):
    """NULL, not zero. "No deed is recorded" differs from "no deed was done"."""
    assert conn.execute(
        "SELECT dao_deed_of(1, %s, %s)", (kind, code)
    ).fetchone()[0] is None


def test_root_and_destiny_never_reach_the_understanding_list(conn, venerable):
    pid = venerable()
    conn.execute(
        "INSERT INTO player_character (player_id, race_code, root_code) "
        "VALUES (%s, (SELECT min(code) FROM races), 'iron_root')",
        (pid,),
    )
    conn.execute("SELECT dao_stamp(%s)", (pid,))
    kinds = {r[0] for r in understanding(conn, pid)}
    assert "root" not in kinds and "destiny" not in kinds
    # but they are still aspects of the Dao
    assert conn.execute(
        "SELECT count(*) FROM player_dao_aspects WHERE player_id = %s AND source_kind = 'root'",
        (pid,),
    ).fetchone()[0] == 1


def test_the_deed_counters_are_realm_neutral(conn):
    """Levels and counts, not exp.

    physique_xp tops out near two million and craft exp is larger again, both
    inflated by realm. A flat rate against an exponential bar is the oldest
    fault in this schema; these four do not inflate.
    """
    rows = conn.execute(
        "SELECT source_kind, unit_name FROM dao_deed_rates ORDER BY source_kind"
    ).fetchall()
    units = dict(rows)
    assert "exp" not in " ".join(units.values()).lower()
    assert units["craft"].endswith("levels") and units["body"].endswith("levels")


# ---------------------------------------------------------------------------
# The stamp
# ---------------------------------------------------------------------------


def test_nothing_accrues_before_a_stamp(conn, venerable):
    pid = venerable()
    assert total(conn, pid) == 0
    assert rung(conn, pid) is None
    assert understanding(conn, pid) == []


def test_a_long_history_is_not_backdated_credit(conn, venerable):
    """The whole point of a baseline.

    A cultivator arriving with three thousand mining levels has a history, not
    an understanding - the history is what gave them the Dao in the first
    place. Understanding is what they do afterwards.
    """
    pid = venerable(craft_level=3000)
    conn.execute("SELECT dao_stamp(%s)", (pid,))
    assert total(conn, pid) == 0


def test_a_deed_after_the_stamp_accrues(conn, venerable):
    pid = venerable(craft_level=50)
    conn.execute("SELECT dao_stamp(%s)", (pid,))
    conn.execute(
        "UPDATE player_professions SET level = 250 WHERE player_id = %s", (pid,)
    )
    assert total(conn, pid) > 0


def test_casting_accrues_understanding_of_that_path(conn, venerable, swinger):
    pid = venerable()
    tid, species = swinger(pid)
    conn.execute("SELECT dao_stamp(%s)", (pid,))
    swing(conn, pid, tid, species, times=10)
    paths = [r for r in understanding(conn, pid) if r[0] == "path"]
    assert any(float(r[3]) > 0 for r in paths), paths


def test_understanding_is_weighted_by_the_aspect(conn, venerable, swinger):
    """Your Dao decides which of your deeds advance you.

    Two cultivators cast the same technique the same number of times; the one
    whose Dao leads with that Path gains more. This is the mechanic, not a
    detail of it.
    """
    lead = venerable(paths=(("sword", 90_000),))
    minor = venerable(paths=(("shadow", 90_000), ("sword", 12_000)))
    for pid in (lead, minor):
        conn.execute("SELECT dao_stamp(%s)", (pid,))
    tid, species = swinger(lead, "sword")
    swinger(minor, "sword")
    swing(conn, lead, tid, species, times=20)
    swing(conn, minor, tid, species, times=20)

    def sword_points(pid):
        return float(
            conn.execute(
                "SELECT COALESCE(sum(understanding), 0) FROM dao_understanding(%s) "
                "WHERE source_code = 'sword'",
                (pid,),
            ).fetchone()[0]
        )

    assert sword_points(lead) > sword_points(minor) > 0


def test_a_stamped_dao_does_not_grow_a_new_aspect(conn, venerable):
    """The reason for freezing at all.

    Without it a cultivator could train a fresh Path to the top and have the
    ladder re-weight itself underneath them.
    """
    pid = venerable()
    conn.execute("SELECT dao_stamp(%s)", (pid,))
    before = conn.execute(
        "SELECT count(*) FROM player_dao_aspects WHERE player_id = %s", (pid,)
    ).fetchone()[0]
    conn.execute(
        "INSERT INTO player_path_attainment (player_id, path_code, insight, tier) "
        "VALUES (%s, 'poison', 9000000, 10)",
        (pid,),
    )
    assert conn.execute(
        "SELECT count(*) FROM player_dao_aspects WHERE player_id = %s", (pid,)
    ).fetchone()[0] == before
    assert all(r[1] != "poison" for r in understanding(conn, pid))


def test_stamping_twice_is_refused(conn, venerable):
    """It would reset every baseline and erase what had been understood."""
    pid = venerable()
    conn.execute("SELECT dao_stamp(%s)", (pid,))
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute("SELECT dao_stamp(%s)", (pid,))


def test_a_character_with_no_path_cannot_be_stamped(conn, make_player):
    pid = make_player("Pathless")
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute("SELECT dao_stamp(%s)", (pid,))


def test_the_stamp_keeps_the_name_it_was_read_under(conn, venerable):
    pid = venerable()
    live = conn.execute("SELECT dao_name_of(%s)", (pid,)).fetchone()[0]
    stamped = conn.execute("SELECT dao_stamp(%s)", (pid,)).fetchone()[0]
    assert stamped == live
    assert conn.execute(
        "SELECT dao_name FROM player_dao WHERE player_id = %s", (pid,)
    ).fetchone()[0] == live


def test_deleting_a_cultivator_takes_their_stamp(conn, venerable):
    pid = venerable()
    conn.execute("SELECT dao_stamp(%s)", (pid,))
    conn.execute("DELETE FROM players WHERE player_id = %s", (pid,))
    assert conn.execute(
        "SELECT count(*) FROM player_dao_aspects WHERE player_id = %s", (pid,)
    ).fetchone()[0] == 0


# ---------------------------------------------------------------------------
# The rungs
# ---------------------------------------------------------------------------


def test_the_ladder_begins_where_the_fruits_end(conn):
    """"The fruits end; the Venerable ranks begin." Rank 18 is Yellow Apricot."""
    assert conn.execute("SELECT min(rank) FROM venerable_ranks").fetchone()[0] == 19
    assert conn.execute("SELECT max(rank) FROM realms").fetchone()[0] == 18


def test_every_rung_is_harder_than_the_one_below(conn):
    worse = conn.execute(
        """
        SELECT a.rank, b.rank FROM venerable_ranks a
        JOIN venerable_ranks b ON b.rank = a.rank + 1
        WHERE b.understanding_required <= a.understanding_required
           OR b.aspects_required < a.aspects_required
           OR b.per_aspect_required <= a.per_aspect_required
        """
    ).fetchall()
    assert worse == []


def test_a_rung_demands_breadth_and_depth_as_data(conn):
    """The spec's open question - breadth or focus - is three columns.

    Leaving it in a function would make answering it a migration. It is a
    balance question and nobody has stood at rank 19 yet.
    """
    cols = {
        r[0]
        for r in conn.execute(
            "SELECT column_name FROM information_schema.columns "
            "WHERE table_name = 'venerable_ranks'"
        ).fetchall()
    }
    assert {"understanding_required", "aspects_required", "per_aspect_required"} <= cols


def test_an_unstamped_cultivator_holds_no_rung(conn, venerable):
    assert rung(conn, venerable()) is None


def test_enough_understanding_reaches_a_rung(conn, venerable):
    pid = venerable(craft_level=50)
    conn.execute("SELECT dao_stamp(%s)", (pid,))
    conn.execute(
        "UPDATE player_professions SET level = 30000 WHERE player_id = %s", (pid,)
    )
    conn.execute("UPDATE player_physique SET body_level = 30000 WHERE player_id = %s", (pid,))
    assert rung(conn, pid) is not None


def test_total_understanding_alone_is_not_enough(conn, venerable):
    """A rung wants it spread across aspects too, not piled into one.

    Written against the breadth demand rather than against a number: 0495
    repriced the ladder and the original form of this test asserted that one
    craft at the SMALLINT ceiling (3,276 understanding) exceeded the top
    rung's total, which was true at 1,500 and is false at 10,000. The property
    worth pinning is that a cultivator with a single feeding aspect cannot
    hold a rung that asks for more than one, however far they push it.
    """
    pid = venerable(craft=None)
    conn.execute("SELECT dao_stamp(%s)", (pid,))
    conn.execute(
        "UPDATE player_physique SET body_level = 32000 WHERE player_id = %s", (pid,)
    )
    feeding = [r for r in understanding(conn, pid) if float(r[3]) > 0]
    assert len(feeding) == 1, feeding

    lowest_breadth = conn.execute(
        "SELECT min(aspects_required) FROM venerable_ranks WHERE venerable_tier > 1"
    ).fetchone()[0]
    assert lowest_breadth >= 2, "no rung above the granted one asks for breadth"

    # The first rung is paid for with the Sovereign Calamity rather than
    # with understanding (0523), so it is the floor a stamped Dao sits on
    # and the thing one aspect must not be able to climb PAST.
    granted = conn.execute("SELECT min(rank) FROM venerable_ranks").fetchone()[0]
    assert rung(conn, pid) == granted, (
        f"one aspect bought a rung above the one the sky grants: "
        f"{total(conn, pid)} understanding"
    )


def test_the_rung_reads_its_demands_from_the_table(conn, venerable):
    """Tuning the ladder is an UPDATE, so the reader must not hard-code any of it."""
    pid = venerable(craft_level=50)
    conn.execute("SELECT dao_stamp(%s)", (pid,))
    conn.execute(
        "UPDATE player_professions SET level = 300 WHERE player_id = %s", (pid,)
    )
    # Rank 19 is granted by the sky, so rank 20 is the first rung the table
    # charges for and the first one that can prove the reader reads it.
    assert rung(conn, pid) == 19
    conn.execute(
        "UPDATE venerable_ranks SET understanding_required = 1, "
        "aspects_required = 1, per_aspect_required = 1 WHERE rank = 20"
    )
    assert rung(conn, pid) == 20


# ---------------------------------------------------------------------------
# Nine rungs and a bar (0495)
# ---------------------------------------------------------------------------


def progress(conn, player_id):
    return conn.execute(
        """
        SELECT held_tier, next_tier, understanding, floor_at, required, fraction,
               aspects_realised, aspects_needed, per_aspect
        FROM venerable_progress(%s)
        """,
        (player_id,),
    ).fetchone()


def test_the_ladder_has_nine_rungs_numbered_one_to_nine(conn):
    """"I want multiple ranks of venerables" - nine, like every other ladder."""
    rows = conn.execute(
        "SELECT venerable_tier, rank FROM venerable_ranks ORDER BY rank"
    ).fetchall()
    assert [t for t, _ in rows] == list(range(1, 10))
    assert [r for _, r in rows] == list(range(19, 28))


def test_a_rung_cannot_ask_for_more_aspects_than_can_ever_feed(conn):
    """The one that would have shipped an unreachable top rung.

    A Dao holds up to nine aspects but only four KINDS record a deed: at most
    three Paths, one body, one craft, one worm. Six.
    """
    ceiling = 3 + 1 + 1 + 1
    worst = conn.execute("SELECT max(aspects_required) FROM venerable_ranks").fetchone()[0]
    assert worst <= ceiling, worst


def test_a_rungs_demands_are_consistent_with_each_other(conn):
    """Six aspects at 1,200 each is 7,200 - a total below that is meaningless."""
    bad = conn.execute(
        """
        SELECT venerable_tier FROM venerable_ranks
        WHERE aspects_required * per_aspect_required > understanding_required
        """
    ).fetchall()
    assert bad == []


def test_the_first_rung_takes_far_longer_than_a_realm_used_to(conn):
    """Eighteen ranks went in about thirty days - 1.7 days a rank.

    At the measured ~28 understanding a day for a dedicated cultivator, the
    first climb a Venerable makes must take weeks rather than days.

    Measured against the first rung the TABLE charges for, not against tier
    1: since 0523 the Sovereign Calamity pays for that one, so its price is
    0 and dividing it by a daily rate says nothing. The requirement is the
    user's - "last realm was passed too fast" - and it is about the climb.
    """
    first_climb = float(
        conn.execute(
            """
            SELECT min(understanding_required) FROM venerable_ranks
            WHERE understanding_required > 0
            """
        ).fetchone()[0]
    )
    assert first_climb / 28 > 7, (
        f"the first Venerable climb is {first_climb / 28:.1f} days"
    )

    # And the whole realm is still a long way further than the one below it.
    whole = float(
        conn.execute(
            "SELECT max(understanding_required) FROM venerable_ranks"
        ).fetchone()[0]
    )
    assert whole / 28 > 30 * 3, f"the whole realm is {whole / 28:.0f} days"


def test_the_whole_ladder_takes_months(conn):
    last = float(
        conn.execute(
            "SELECT understanding_required FROM venerable_ranks WHERE venerable_tier = 9"
        ).fetchone()[0]
    )
    assert last / 28 > 180


def test_casting_no_longer_swamps_the_other_axes(conn):
    """At 0490's rate of one point per two casts, 200 swings a day was 100
    understanding - six times the other three axes combined."""
    path = float(
        conn.execute(
            "SELECT units_per_point FROM dao_deed_rates WHERE source_kind = 'path'"
        ).fetchone()[0]
    )
    body = float(
        conn.execute(
            "SELECT units_per_point FROM dao_deed_rates WHERE source_kind = 'body'"
        ).fetchone()[0]
    )
    # 200 casts/day measured against the body axis's measured 132 levels/day
    assert 200 / path <= 2 * (132 / body)


def test_an_unstamped_cultivator_has_no_place_on_the_ladder(conn, venerable):
    """No row at all, rather than a row full of nulls."""
    assert progress(conn, venerable()) is None


def test_a_freshly_stamped_dao_starts_the_bar_empty(conn, venerable):
    pid = venerable()
    conn.execute("SELECT dao_stamp(%s)", (pid,))
    assert float(progress(conn, pid)[5]) == 0


def test_the_bar_fills_as_deeds_are_done(conn, venerable):
    """Swept rather than landed on.

    This set one body level and asserted the bar sat between 0.4 and 0.6,
    which pinned the ladder's tuning rather than the bar's behaviour - and
    broke the moment 0523 made the first rung free and moved its floor from
    400 to 0. What matters is that the bar RISES as deeds are done and
    passes through the middle on the way, which no retuning changes.
    """
    pid = venerable()
    conn.execute("SELECT dao_stamp(%s)", (pid,))

    seen = []
    for level in range(100, 8200, 400):
        conn.execute(
            "UPDATE player_physique SET body_level = %s WHERE player_id = %s",
            (level, pid),
        )
        row = progress(conn, pid)
        seen.append((level, int(row[1] or 0), float(row[5])))

    # Within a rung it only ever rises; crossing one starts it over, which
    # is the whole point of filling from the rung held.
    for (_, tier_a, frac_a), (lvl, tier_b, frac_b) in zip(seen, seen[1:]):
        if tier_a == tier_b:
            assert frac_b >= frac_a, f"the bar fell at body level {lvl}: {seen}"

    assert any(0.3 < f < 0.7 for _, _, f in seen), (
        f"the bar never half-filled: {seen}"
    )
    assert max(f for _, _, f in seen) > 0.9, (
        f"the bar never approached full: {seen}"
    )


def test_the_bar_restarts_at_each_rung(conn, venerable):
    """Otherwise one bar creeps to full across all nine and says nothing.

    It fills from the rung held, not from zero.
    """
    pid = venerable(craft_level=10)
    conn.execute("SELECT dao_stamp(%s)", (pid,))

    # Breadth is demanded too, and it is what actually stops this
    # cultivator: two feeding aspects against the three a middle rung wants.
    # It is tested on its own in test_the_bar_reports_the_breadth_demand_too,
    # and left standing here it pins the bar at 1.000 before a single rung is
    # crossed - so the question this test asks could never arise. Lifted
    # inside the transaction, which rolls back.
    conn.execute(
        "UPDATE venerable_ranks SET aspects_required = 1, per_aspect_required = 1"
    )

    crossings = []
    seen = []
    for level in range(100, 32000, 500):
        conn.execute(
            "UPDATE player_physique SET body_level = %s WHERE player_id = %s",
            (level, pid),
        )
        row = progress(conn, pid)
        here = (int(row[0] or 0), float(row[3]), float(row[5]))
        if seen and here[0] > seen[-1][0]:
            crossings.append((seen[-1], here))
        seen.append(here)

    assert crossings, f"no rung was crossed at all: {seen[:4]} ... {seen[-4:]}"

    for before, after in crossings:
        tier, floor_at, frac = after
        # The bar starts over rather than carrying on up.
        assert frac < before[2], (
            f"the bar did not restart crossing into rung {tier}: "
            f"{before[2]:.3f} -> {frac:.3f}"
        )
        # And it fills from the rung HELD, read off the table rather than
        # remembered - which is what let this test survive 0495 retuning the
        # whole ladder.
        floor_should_be = conn.execute(
            "SELECT understanding_required FROM venerable_ranks "
            "WHERE venerable_tier = %s",
            (tier,),
        ).fetchone()[0]
        assert floor_at == float(floor_should_be), (
            f"rung {tier}'s bar fills from {floor_at}, not from {floor_should_be}"
        )


def test_the_bar_never_leaves_its_bounds(conn, venerable):
    pid = venerable(craft_level=10)
    conn.execute("SELECT dao_stamp(%s)", (pid,))
    for body in (1, 2, 500, 5000, 30000):
        conn.execute(
            "UPDATE player_physique SET body_level = %s WHERE player_id = %s", (body, pid)
        )
        frac = float(progress(conn, pid)[5])
        assert 0 <= frac <= 1, (body, frac)


def test_the_bar_reports_the_breadth_demand_too(conn, venerable):
    """Understanding alone does not carry a rung, so the bar must say so."""
    pid = venerable(craft_level=10)
    conn.execute("SELECT dao_stamp(%s)", (pid,))
    conn.execute("UPDATE player_physique SET body_level = 10000 WHERE player_id = %s", (pid,))
    row = progress(conn, pid)
    realised, needed = int(row[6]), int(row[7])
    assert realised < needed, row

    # The sky grants the first rung outright, so the thing understanding
    # alone must not buy is the one ABOVE it.
    granted = conn.execute(
        "SELECT min(venerable_tier) FROM venerable_ranks"
    ).fetchone()[0]
    assert row[0] == granted, (
        f"a rung past the one the sky grants was given on total "
        f"understanding alone: {row}"
    )


# ---------------------------------------------------------------------------
# Nobody living was touched
# ---------------------------------------------------------------------------


def test_no_dao_is_stamped_without_the_calamity(conn):
    """`venerable_ascend` is the only caller of `dao_stamp` since 0521.

    The owner command that used to stamp was removed, because a stamp from
    there would have minted a Venerable who never fought the Sovereign
    Calamity. So every Dao that exists must have a survived rank 19 behind it.

    This used to assert `count(*) FROM player_dao = 0` - true on the day it
    was written and false the moment somebody actually crossed. A census of a
    live world measures the world; the rule it was standing in for is the one
    below, and it cannot go stale.
    """
    unearned = conn.execute(
        """
        SELECT d.player_id
        FROM player_dao d
        WHERE NOT EXISTS (
            SELECT 1 FROM player_tribulations t
            WHERE t.player_id = d.player_id
              AND t.rank = 19 AND t.status = 'passed')
        """
    ).fetchall()
    assert unearned == [], (
        f"these cultivators hold a Dao without surviving the Sovereign "
        f"Calamity: {[r[0] for r in unearned]}"
    )


def test_understanding_and_the_rung_agree_about_who_has_ascended(conn):
    """The two readers must never disagree about whether somebody crossed.

    `venerable_rank_of` is NULL for anybody with no `player_dao` row - it is
    guarded by that EXISTS - and `dao_understanding_total` has nothing to sum
    for them, because the aspects are written at the stamp. Above the door,
    the rung is real and understanding is never negative.
    """
    rows = conn.execute(
        """
        SELECT p.player_id,
               EXISTS (SELECT 1 FROM player_dao d WHERE d.player_id = p.player_id)
                   AS stamped,
               dao_understanding_total(p.player_id),
               venerable_rank_of(p.player_id)
        FROM players p WHERE p.deleted_at IS NULL
        """
    ).fetchall()
    assert rows, "no cultivators to check"

    floor, ceiling = conn.execute(
        "SELECT min(rank), max(rank) FROM venerable_ranks"
    ).fetchone()

    for player_id, stamped, tot, rung in rows:
        if not stamped:
            assert tot == 0, (player_id, tot)
            assert rung is None, (player_id, rung)
        else:
            assert rung is not None, (player_id, "stamped but no rung")
            assert floor <= rung <= ceiling, (player_id, rung)
            assert tot >= 0, (player_id, tot)
