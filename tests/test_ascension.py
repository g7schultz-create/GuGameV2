"""The crossing out of the eighteen realms, and what a failed sky costs (0521-0522).

Nothing in this game could move a cultivator above rank 18. `breakthrough`
walks `realms` by realm_id + 1 and refuses when there is nothing there, and
`tribulation_standing` decided a sky was owed by reading that same next row -
so at the peak of the ladder it reported nothing owed and the realm the whole
Venerable engine was built for was unreachable.

THE TWO LADDERS ARE SEPARATE ON PURPOSE. `realms` stops at 18;
`venerable_ranks` runs 19 to 27. Adding a realms row would have let
`breakthrough` walk into it and demand `cultivation_required` from somebody
whose meter is understanding, which is the exact thing the Venerable ranks
replace. So the door is synthesised inside `tribulation_standing` and the
crossing is its own function.

AND THE FIRST RUNG IS GRANTED BY THE SKY, not derived. `venerable_rank_of`
read every rung off understanding, which would have left somebody who had just
crossed holding zero understanding, meeting no rung, and standing at 18 to the
rest of the game - they would have ascended into nothing.

THE PENALTY, which the user asked for in those words: a failed tribulation
leaves 500 jade owed, and while it is owed cultivation does not advance. The
halt lives at the single choke point every cultivation gain goes through, and
it BANKS NOTHING rather than refusing, because `settle_passive_cultivation` is
the tick half the bot's screens run before they draw anything.
"""

import psycopg
import pytest


FEE = 500


def _named(conn, sql, cols, *args):
    """One read, returned as a dict keyed by the columns it asked for.

    `conn` hands back tuples, so a composite result is read by naming its
    columns rather than by position - a function gaining a column in the
    middle must not quietly change what a test is asserting about.
    """
    row = conn.execute(
        sql.replace("COLS", ", ".join(cols)), args
    ).fetchone()
    return None if row is None else dict(zip(cols, row))


STANDING = (
    "owed", "rank", "realm_name", "trial_name", "trial_text", "species_id",
    "passed", "facing_battle", "wait_seconds", "may_face", "blocked_by",
    "trial_hp", "trial_attack",
)
CROSSING = (
    "dao_name", "venerable_rank", "tier", "title", "aperture_gained", "aspects",
)
PAYMENT = ("paid", "jade_left")


def standing(conn, player_id):
    return _named(
        conn, "SELECT COLS FROM tribulation_standing(%s)", STANDING, player_id
    )


def ascend(conn, player_id):
    return _named(
        conn, "SELECT COLS FROM venerable_ascend(%s)", CROSSING, player_id
    )


def pay(conn, player_id):
    return _named(
        conn, "SELECT COLS FROM pay_tribulation_debt(%s)", PAYMENT, player_id
    )


def halt(conn, player_id):
    return conn.execute("SELECT cultivation_halt(%s)", (player_id,)).fetchone()[0]


def cultivation(conn, player_id):
    return conn.execute(
        "SELECT cultivation FROM player_cultivation WHERE player_id = %s", (player_id,)
    ).fetchone()[0]


def debt(conn, player_id):
    return conn.execute(
        "SELECT tribulation_debt FROM player_cultivation WHERE player_id = %s",
        (player_id,),
    ).fetchone()[0]


@pytest.fixture
def at_the_peak(conn, make_player):
    """A cultivator standing at the very top of the realm ladder.

    The peak specifically, not just rank 18: the middle and late stages of
    rank 18 still have a next realm row, so the door must not open for them.
    """

    def _make(stage="peak", paths=(("sword", 90_000),)):
        pid = make_player("Peak")
        conn.execute(
            """
            INSERT INTO player_cultivation (player_id, realm_id, cultivation)
            SELECT %s, r.realm_id, r.cultivation_required
            FROM realms r
            WHERE r.rank = (SELECT max(rank) FROM realms) AND r.stage = %s
            """,
            (pid, stage),
        )
        conn.execute(
            "INSERT INTO player_physique (player_id, physique_id, body_path, body_level) "
            "VALUES (%s, (SELECT min(physique_id) FROM physiques), 'buddhist', 100)",
            (pid,),
        )
        for code, insight in paths:
            conn.execute(
                "INSERT INTO player_path_attainment (player_id, path_code, insight, tier) "
                "VALUES (%s, %s, %s, 5)",
                (pid, code, insight),
            )
        return pid

    return _make


def survive(conn, player_id, rank=19):
    conn.execute(
        "INSERT INTO player_tribulations (player_id, rank, status, settled_at) "
        "VALUES (%s, %s, 'passed', now())",
        (player_id, rank),
    )


# ---------------------------------------------------------------------------
# The door
# ---------------------------------------------------------------------------


def test_the_sky_above_the_last_realm_exists_at_all(conn):
    """The thing 0521 is for. Rank 19 had no tribulation and no door."""
    row = conn.execute(
        """
        SELECT cs.name, cs.kind, cs.immortal_rank, cs.base_hp
        FROM tribulations tb JOIN creature_species cs USING (species_id)
        WHERE tb.rank = 19
        """
    ).fetchone()
    assert row is not None, "rank 19 has nothing standing in its door"
    assert row[1] == "tribulation"


def test_the_ladder_of_skies_has_no_hole_in_it(conn):
    missing = conn.execute(
        """
        SELECT array_agg(g) FROM generate_series(2, 19) g
        WHERE NOT EXISTS (SELECT 1 FROM tribulations WHERE rank = g)
        """
    ).fetchone()[0]
    assert missing is None, f"ranks with no tribulation: {missing}"


def test_the_sovereign_calamity_stands_above_the_ninth(conn):
    """Continued off rank 18's own row rather than chosen, on every axis."""
    old, new = conn.execute(
        """
        SELECT tb.rank, cs.base_hp, cs.base_attack, cs.base_defense,
               cs.base_speed, cs.immortal_rank
        FROM tribulations tb JOIN creature_species cs USING (species_id)
        WHERE tb.rank IN (18, 19) ORDER BY tb.rank
        """
    ).fetchall()
    for i, axis in enumerate(
        ["hp", "attack", "defence", "speed", "immortal rank"], start=1
    ):
        assert new[i] > old[i], f"the rank 19 sky is no bigger on {axis}"


def test_the_peak_of_the_last_realm_now_owes_a_sky(conn, at_the_peak):
    pid = at_the_peak()
    here = standing(conn, pid)
    assert here["owed"] is True, "the peak of the ladder still owes nothing"
    assert here["rank"] == 19
    assert here["species_id"] is not None
    assert here["trial_hp"] > 0, "the door reports no body to cut"


def test_a_stage_below_the_peak_still_breaks_through_instead(conn, at_the_peak):
    """The door is keyed on there being NO next realm, not on the rank.

    Rank 18's middle and late stages have a next row, so they must keep
    offering the ordinary stage crossing rather than the Venerable sky.
    """
    for stage in ("middle", "late"):
        pid = at_the_peak(stage=stage)
        here = standing(conn, pid)
        assert here["rank"] != 19, (
            f"the Venerable door opened at rank 18 {stage}, which still has a "
            "realm above it"
        )


def test_the_venerable_door_does_not_ask_for_cultivation(conn, at_the_peak):
    """Rank 19 is gated on surviving, not on a meter it replaces.

    Standing at the peak already means having paid every rung of the realm
    ladder; asking again for the thing understanding replaces would be asking
    twice.
    """
    pid = at_the_peak()
    conn.execute(
        "UPDATE player_cultivation SET cultivation = 0 WHERE player_id = %s", (pid,)
    )
    here = standing(conn, pid)
    assert here["owed"] is True
    assert here["blocked_by"] != "cultivation"


def test_facing_the_sovereign_calamity_opens_a_real_fight(conn, at_the_peak):
    """`tribulation_face` needed no change, which is the point of the design."""
    pid = at_the_peak()
    conn.execute(
        "UPDATE player_physique SET max_hp = 10000000000000, "
        "current_hp = 10000000000000 WHERE player_id = %s",
        (pid,),
    )
    fight = conn.execute("SELECT tribulation_face(%s)", (pid,)).fetchone()[0]
    assert fight is not None
    assert (
        conn.execute(
            "SELECT kind FROM battles WHERE battle_id = %s", (fight,)
        ).fetchone()[0]
        == "tribulation"
    )
    # The thing in the door is the thing in the fight. Read off
    # `battle_combatants`, where a battle keeps its creature - `battles`
    # itself carries no species.
    assert conn.execute(
        """
        SELECT bc.species_id FROM battle_combatants bc
        WHERE bc.battle_id = %s AND bc.species_id IS NOT NULL
        """,
        (fight,),
    ).fetchone()[0] == conn.execute(
        "SELECT species_id FROM tribulations WHERE rank = 19"
    ).fetchone()[0]
    assert (
        conn.execute(
            "SELECT rank FROM player_tribulations WHERE battle_id = %s", (fight,)
        ).fetchone()[0]
        == 19
    )


def test_a_survived_venerable_sky_points_at_ascend_not_breakthrough(
    conn, at_the_peak
):
    """`breakthrough` walks `realms` and would say nothing is above them.

    A dead end at the single most important moment in the game, which is what
    the message said before 0521.
    """
    pid = at_the_peak()
    survive(conn, pid)
    with pytest.raises(psycopg.errors.CheckViolation) as caught:
        conn.execute("SELECT tribulation_face(%s)", (pid,))
    assert "/ascend" in str(caught.value)
    assert "/breakthrough" not in str(caught.value)


def test_a_lower_sky_still_points_at_breakthrough(conn, make_player):
    """The same message, for the seventeen skies that are not the Venerable one."""
    pid = make_player("Climber")
    conn.execute(
        """
        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT %s, r.realm_id, r.cultivation_required
        FROM realms r WHERE r.rank = 2 AND r.stage = 'peak'
        """,
        (pid,),
    )
    rank = standing(conn, pid)["rank"]
    conn.execute(
        "INSERT INTO player_tribulations (player_id, rank, status, settled_at) "
        "VALUES (%s, %s, 'passed', now())",
        (pid, rank),
    )
    with pytest.raises(psycopg.errors.CheckViolation) as caught:
        conn.execute("SELECT tribulation_face(%s)", (pid,))
    assert "/breakthrough" in str(caught.value)


# ---------------------------------------------------------------------------
# The crossing
# ---------------------------------------------------------------------------


def test_crossing_is_refused_until_the_sky_is_survived(conn, at_the_peak):
    pid = at_the_peak()
    with pytest.raises(psycopg.errors.CheckViolation, match="has not been survived"):
        conn.execute("SELECT * FROM venerable_ascend(%s)", (pid,))


def test_crossing_is_refused_below_the_top_of_the_ladder(conn, at_the_peak):
    pid = at_the_peak(stage="middle")
    with pytest.raises(psycopg.errors.CheckViolation, match="still above you"):
        conn.execute("SELECT * FROM venerable_ascend(%s)", (pid,))


def test_the_ascension_stamps_the_dao(conn, at_the_peak):
    """Stamping IS the crossing, which is what 0490 built `dao_stamp` for."""
    pid = at_the_peak()
    survive(conn, pid)
    row = ascend(conn, pid)

    assert row["dao_name"], "crossed without a Dao"
    assert row["aspects"] >= 1
    stored = conn.execute(
        "SELECT dao_name FROM player_dao WHERE player_id = %s", (pid,)
    ).fetchone()
    assert stored is not None and stored[0] == row["dao_name"]


def test_the_sky_grants_the_first_rung_rather_than_understanding(conn, at_the_peak):
    """The gap 0521 closed.

    `venerable_rank_of` derived every rung from understanding, and a cultivator
    who has just crossed has none - so they met no rung, read NULL, and
    `player_standing` fell back to 18. They would have ascended into nothing.
    """
    pid = at_the_peak()
    survive(conn, pid)
    row = ascend(conn, pid)

    assert row["venerable_rank"] == 19
    assert row["tier"] == 1
    assert (
        conn.execute(
            "SELECT dao_understanding_total(%s)", (pid,)
        ).fetchone()[0]
        == 0
    ), "the point of this test is a cultivator with NO understanding yet"
    assert conn.execute("SELECT venerable_rank_of(%s)", (pid,)).fetchone()[0] == 19


def test_the_whole_game_sees_a_venerable_above_eighteen(conn, at_the_peak):
    """0519 moved six gates onto `player_standing` for exactly this moment."""
    pid = at_the_peak()
    survive(conn, pid)
    before_lid = conn.execute(
        "SELECT gu_effect_cap('crit_damage', %s)", (pid,)
    ).fetchone()[0]
    conn.execute("SELECT * FROM venerable_ascend(%s)", (pid,))

    assert conn.execute("SELECT player_standing(%s)", (pid,)).fetchone()[0] == 19
    after_lid = conn.execute(
        "SELECT gu_effect_cap('crit_damage', %s)", (pid,)
    ).fetchone()[0]
    assert after_lid > before_lid, "a Venerable's crit lid is frozen at rank 18"


def test_a_venerable_carries_more_aperture_than_the_rank_they_were(conn, at_the_peak):
    """0520. Ascending must never cost something."""
    pid = at_the_peak()
    survive(conn, pid)
    before = conn.execute("SELECT gu_capacity_of(%s)", (pid,)).fetchone()[0]
    row = ascend(conn, pid)
    after = conn.execute("SELECT gu_capacity_of(%s)", (pid,)).fetchone()[0]

    assert after > before
    assert row["aperture_gained"] == after - before, (
        "the card reports an aperture gain the body did not get"
    )


def test_nobody_crosses_twice(conn, at_the_peak):
    pid = at_the_peak()
    survive(conn, pid)
    conn.execute("SELECT * FROM venerable_ascend(%s)", (pid,))
    with pytest.raises(psycopg.errors.CheckViolation, match="already a Venerable"):
        conn.execute("SELECT * FROM venerable_ascend(%s)", (pid,))


def test_the_door_shuts_behind_a_venerable(conn, at_the_peak):
    """Otherwise /tribulation asks them to fight the same sky for ever."""
    pid = at_the_peak()
    survive(conn, pid)
    conn.execute("SELECT * FROM venerable_ascend(%s)", (pid,))
    assert standing(conn, pid)["owed"] is False


def test_breakthrough_still_refuses_above_the_ladder(conn, at_the_peak):
    """The reason the Venerable ladder is a separate table.

    If ascension had added a `realms` row, this would start demanding
    cultivation from a cultivator whose meter is understanding.
    """
    pid = at_the_peak()
    survive(conn, pid)
    conn.execute("SELECT * FROM venerable_ascend(%s)", (pid,))
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute("SELECT * FROM breakthrough(%s)", (pid,))


# ---------------------------------------------------------------------------
# What a failed sky costs
# ---------------------------------------------------------------------------


def test_the_fee_is_the_five_hundred_that_was_asked_for(conn):
    assert (
        conn.execute(
            "SELECT game_config_value('tribulation_failure_jade')"
        ).fetchone()[0]
        == FEE
    )


def test_nobody_owes_anything_until_they_fail(conn, at_the_peak):
    pid = at_the_peak()
    assert debt(conn, pid) == 0
    assert halt(conn, pid) is None


def test_a_sky_below_the_venerable_door_leaves_no_debt(conn, make_player):
    """500 jade is 1.7 days of income at realm 18 and 235 days at realm 1.

    Measured over fourteen days of `jade_ledger`. Below the Venerable door
    the fee would not cost a character something, it would end it, so 0526
    gave it a rank floor in config. A failed sky down there still costs the
    fight and the eight hour wait, which is what it always cost.
    """
    floor = int(
        conn.execute(
            "SELECT game_config_value('tribulation_debt_from_rank')"
        ).fetchone()[0]
    )
    assert floor > 2, "the fee reaches the first sky a beginner ever faces"

    pid = make_player("Beginner")
    # The NEXT realm's requirement: the door asks what the rank above
    # costs, not what this one did.
    conn.execute(
        """
        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT %s, r.realm_id, nxt.cultivation_required
        FROM realms r JOIN realms nxt ON nxt.realm_id = r.realm_id + 1
        WHERE r.rank = 2 AND r.stage = 'peak'
        """,
        (pid,),
    )
    conn.execute(
        "INSERT INTO player_physique (player_id, physique_id, max_hp, current_hp) "
        "VALUES (%s, (SELECT min(physique_id) FROM physiques), "
        "10000000000000, 10000000000000)",
        (pid,),
    )

    rank = standing(conn, pid)["rank"]
    assert rank < floor, f"this cultivator is at rank {rank}, not below the floor"

    # Opened the way `tribulation_face` opens one. A rank 3 door also wants
    # a Body Tempering Pill and whatever else `breakthrough_gate` asks for,
    # and the branch under test only reads `player_tribulations.rank`.
    fight = conn.execute(
        "SELECT battle_open(%s, s.species_id) FROM tribulation_standing(%s) s",
        (pid, pid),
    ).fetchone()[0]
    conn.execute(
        "UPDATE battles SET kind = 'tribulation' WHERE battle_id = %s", (fight,)
    )
    conn.execute(
        "INSERT INTO player_tribulations (player_id, rank, battle_id, status) "
        "VALUES (%s, %s, %s, 'facing')",
        (pid, rank, fight),
    )
    conn.execute("SELECT battle_conclude(%s, 'fled')", (fight,))

    assert (
        conn.execute(
            "SELECT status FROM player_tribulations WHERE battle_id = %s",
            (fight,),
        ).fetchone()[0]
        == "failed"
    ), "the setup did not actually fail a tribulation"
    assert debt(conn, pid) == 0, "a beginner was billed for losing one fight"
    assert halt(conn, pid) is None
    # And the cost that has always been there still is.
    assert standing(conn, pid)["wait_seconds"] > 0, (
        "the low sky now costs nothing at all"
    )


def test_fleeing_the_sky_leaves_the_debt(conn, at_the_peak):
    """A flight and an expiry are failures as surely as a death.

    `battle_conclude` settles every ending through one statement, which is why
    the debt is written next to it rather than in the losing branch.
    """
    pid = at_the_peak()
    conn.execute(
        "UPDATE player_physique SET max_hp = 10000000000000, "
        "current_hp = 10000000000000 WHERE player_id = %s",
        (pid,),
    )
    fight = conn.execute("SELECT tribulation_face(%s)", (pid,)).fetchone()[0]
    conn.execute("SELECT battle_conclude(%s, 'fled')", (fight,))

    assert (
        conn.execute(
            "SELECT status FROM player_tribulations WHERE battle_id = %s", (fight,)
        ).fetchone()[0]
        == "failed"
    )
    assert debt(conn, pid) == FEE
    assert halt(conn, pid) is not None
    assert "500 jade" in halt(conn, pid)


def test_two_failures_leave_one_debt(conn, at_the_peak):
    """The fee is a flat gate, so it is SET rather than added."""
    pid = at_the_peak()
    conn.execute(
        "UPDATE player_cultivation SET tribulation_debt = %s WHERE player_id = %s",
        (FEE, pid),
    )
    conn.execute(
        "UPDATE player_physique SET max_hp = 10000000000000, "
        "current_hp = 10000000000000 WHERE player_id = %s",
        (pid,),
    )
    conn.execute(
        "UPDATE player_tribulations SET status = 'failed', settled_at = now() - "
        "interval '99 hours' WHERE player_id = %s",
        (pid,),
    )
    fight = conn.execute("SELECT tribulation_face(%s)", (pid,)).fetchone()[0]
    conn.execute("SELECT battle_conclude(%s, 'fled')", (fight,))
    assert debt(conn, pid) == FEE


def test_cultivation_stops_while_the_debt_stands(conn, at_the_peak):
    pid = at_the_peak()
    conn.execute(
        "UPDATE player_cultivation SET tribulation_debt = %s WHERE player_id = %s",
        (FEE, pid),
    )
    was = cultivation(conn, pid)
    conn.execute("SELECT apply_cultivation_xp(%s, 500000000)", (pid,))
    assert cultivation(conn, pid) == was, "cultivation advanced while stopped"


def test_the_halt_does_not_quietly_store_the_gain_instead(conn, at_the_peak):
    """The reserve is not a hiding place for the penalty.

    It exists for cultivation waiting behind a realm ceiling, and
    `cultivation_reserve_cap` is 0 at the peak anyway because there is no next
    gap to measure. A halted hour is a spent hour - that is the penalty.
    """
    pid = at_the_peak()
    conn.execute(
        "UPDATE player_cultivation SET tribulation_debt = %s WHERE player_id = %s",
        (FEE, pid),
    )
    conn.execute("SELECT apply_cultivation_xp(%s, 500000000)", (pid,))
    assert (
        conn.execute(
            "SELECT reserve FROM player_cultivation WHERE player_id = %s", (pid,)
        ).fetchone()[0]
        == 0
    )


def test_the_halt_returns_a_realm_rather_than_stranding_its_callers(
    conn, at_the_peak
):
    """Two callers assign the return straight into `r_after`."""
    pid = at_the_peak()
    conn.execute(
        "UPDATE player_cultivation SET tribulation_debt = %s WHERE player_id = %s",
        (FEE, pid),
    )
    got = conn.execute("SELECT apply_cultivation_xp(%s, 1000)", (pid,)).fetchone()[0]
    assert got is not None
    assert (
        got
        == conn.execute(
            "SELECT realm_id FROM player_cultivation WHERE player_id = %s", (pid,)
        ).fetchone()[0]
    )


def test_the_passive_tick_survives_a_debt(conn, at_the_peak):
    """The reason the halt banks nothing instead of refusing.

    `settle_passive_cultivation` is the tick half the bot's screens run before
    they draw anything. A refusal at the choke point would have broken the
    game rather than slowing it.
    """
    pid = at_the_peak()
    conn.execute(
        "UPDATE player_cultivation SET tribulation_debt = %s, "
        "last_tick_at = now() - interval '6 hours' WHERE player_id = %s",
        (FEE, pid),
    )
    was = cultivation(conn, pid)
    banked = conn.execute(
        "SELECT cultivation_gained FROM settle_passive_cultivation(%s)", (pid,)
    ).fetchone()
    assert banked is not None, "the tick returned nothing at all"
    assert banked[0] == 0, "the card reports cultivation the halt did not bank"
    assert cultivation(conn, pid) == was


def test_the_venerable_door_shuts_while_the_sky_is_owed(conn, at_the_peak):
    """Where the penalty actually bites.

    At the peak, cultivation has no ceiling left to climb towards and buys
    nothing but leaderboard position and servant food, so halting it alone
    would barely sting the only people who can get here.
    """
    pid = at_the_peak()
    survive(conn, pid)
    conn.execute(
        "UPDATE player_cultivation SET tribulation_debt = %s WHERE player_id = %s",
        (FEE, pid),
    )
    with pytest.raises(psycopg.errors.CheckViolation, match="cultivation is stopped"):
        with conn.transaction():
            conn.execute("SELECT * FROM venerable_ascend(%s)", (pid,))
    assert not conn.execute(
        "SELECT EXISTS (SELECT 1 FROM player_dao WHERE player_id = %s)", (pid,)
    ).fetchone()[0], "the refused crossing stamped a Dao anyway"


def test_paying_is_refused_without_the_jade_and_says_what_is_short(
    conn, at_the_peak
):
    pid = at_the_peak()
    conn.execute(
        "UPDATE player_cultivation SET tribulation_debt = %s WHERE player_id = %s",
        (FEE, pid),
    )
    # Savepoint, so the refusal aborts only the inner block and the debt can
    # still be read back - which is the half of this test that matters.
    with pytest.raises(psycopg.errors.CheckViolation, match="short"):
        with conn.transaction():
            conn.execute("SELECT * FROM pay_tribulation_debt(%s)", (pid,))
    assert debt(conn, pid) == FEE, "a refused payment still cleared the debt"
    assert halt(conn, pid) is not None, "a refused payment lifted the halt"


def test_paying_clears_it_and_cultivation_resumes(conn, at_the_peak):
    pid = at_the_peak()
    conn.execute(
        "UPDATE player_cultivation SET tribulation_debt = %s WHERE player_id = %s",
        (FEE, pid),
    )
    conn.execute("SELECT grant_jade(%s, %s, 'test')", (pid, FEE + 17))
    row = pay(conn, pid)

    assert row["paid"] == FEE
    assert row["jade_left"] == 17
    assert debt(conn, pid) == 0
    assert halt(conn, pid) is None

    was = cultivation(conn, pid)
    conn.execute("SELECT apply_cultivation_xp(%s, 1000000)", (pid,))
    assert cultivation(conn, pid) == was + 1000000


def test_a_cleared_debt_cannot_be_paid_twice(conn, at_the_peak):
    pid = at_the_peak()
    conn.execute("SELECT grant_jade(%s, %s, 'test')", (pid, FEE))
    with pytest.raises(psycopg.errors.CheckViolation, match="owe the sky nothing"):
        with conn.transaction():
            conn.execute("SELECT * FROM pay_tribulation_debt(%s)", (pid,))
    assert (
        conn.execute("SELECT jade_held(%s)", (pid,)).fetchone()[0] == FEE
    ), "a refused payment still took the jade"


def test_paying_opens_the_door_again(conn, at_the_peak):
    """The whole loop: fail, stop, pay, cross."""
    pid = at_the_peak()
    survive(conn, pid)
    conn.execute(
        "UPDATE player_cultivation SET tribulation_debt = %s WHERE player_id = %s",
        (FEE, pid),
    )
    conn.execute("SELECT grant_jade(%s, %s, 'test')", (pid, FEE))
    pay(conn, pid)
    row = ascend(conn, pid)
    assert row["venerable_rank"] == 19


def test_the_debt_is_never_negative(conn, at_the_peak):
    pid = at_the_peak()
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute(
            "UPDATE player_cultivation SET tribulation_debt = -1 WHERE player_id = %s",
            (pid,),
        )


def test_no_living_cultivator_is_stopped_by_this_change(conn):
    """Five cultivators have failed a sky and all five retried and passed it.

    The column defaults to 0 and is only ever written by `battle_conclude`, so
    nobody is charged for a tribulation they already settled.
    """
    stopped = conn.execute(
        """
        SELECT count(*) FROM players p
        WHERE p.deleted_at IS NULL AND cultivation_halt(p.player_id) IS NOT NULL
        """
    ).fetchone()[0]
    assert stopped == 0
