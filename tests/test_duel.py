"""A duel between two cultivators: /duel, and the four ways it could be stolen.

0534 built the duel loop and 0541 left it reached from nowhere - "`duel_open`
would have pulled two" - so none of what is tested here was ever live. It
becomes live the moment `/duel` exists, which is what makes it worth a test
file rather than a migration probe: a probe runs once, on the day it is
written, and every one of these is a rule somebody could break later.

The four, in the order they were found:

  duel_force had no deadline      - force the other side to brace on demand
                                    and win every duel untouched (0548)
  duel_force read the wrong clock - `chose_at` is cleared by every resolve, so
                                    the fix could be pressed over and over to
                                    draw a duel you were losing (0549)
  battle_act took any battle      - it reads seat 1 as a creature and acts as
                                    seat 0, so the second cultivator would
                                    have been swinging as the first
  battle_abandon ended any battle - 'expired', no winner, both released: the
                                    losing side pressing a button and the
                                    fight never having happened
"""

import psycopg
import pytest


def duellist(conn, make_player, name, hp=50_000, defense=300, strength=900):
    """Somebody with a body and one thing to swing.

    The figures are passed in rather than rolled because every test below is
    about WHO ENDS THE FIGHT AND HOW, not about the damage - and a duel whose
    length depends on a random body is a test that fails on Tuesdays.
    """
    who = make_player(name)
    conn.execute(
        "INSERT INTO player_cultivation (player_id, realm_id, cultivation) "
        "SELECT %s, r.realm_id, r.cultivation_required FROM realms r "
        "WHERE r.rank = 4 ORDER BY r.realm_id DESC LIMIT 1",
        (who,),
    )
    conn.execute(
        "INSERT INTO player_physique (player_id, physique_id) VALUES "
        "(%s, (SELECT physique_id FROM physiques WHERE code = 'mortal_body'))",
        (who,),
    )
    conn.execute(
        "UPDATE player_physique SET max_hp = %s, current_hp = %s, "
        "defense = %s, strength = %s WHERE player_id = %s",
        (hp, hp, defense, strength, who),
    )
    conn.execute(
        "INSERT INTO player_techniques (player_id, technique_id) "
        "SELECT %s, technique_id FROM techniques WHERE created_by IS NULL "
        "AND category = 'attack' AND rank = 1 ORDER BY base_power DESC LIMIT 1",
        (who,),
    )
    return who


def a_move(conn, who):
    return conn.execute(
        "SELECT technique_id FROM player_usable_techniques "
        "WHERE player_id = %s LIMIT 1",
        (who,),
    ).fetchone()[0]


def age_the_round(conn, battle_id):
    """Push the round's clock past its deadline.

    The clock is the newest `battle_actions.created_at` for the fight, or the
    fight's own `started_at` before a round has been played - 0549 moved it
    there because `duel_resolve` clears `chose_at` on both seats every time it
    runs, which made a just-resolved round look like an unanswered one.
    """
    secs = conn.execute(
        "SELECT game_config_value('duel_round_seconds')"
    ).fetchone()[0]
    conn.execute(
        "UPDATE battles SET started_at = now() - make_interval("
        "secs => %s::double precision) WHERE battle_id = %s",
        (float(secs) + 5, battle_id),
    )
    conn.execute(
        "UPDATE battle_actions SET created_at = now() - make_interval("
        "secs => %s::double precision) WHERE battle_id = %s",
        (float(secs) + 5, battle_id),
    )


def play_out(conn, battle, *who, limit=60):
    """Play the duel to its end, swinging when qi allows and bracing when not.

    Bracing is what restores the qi to swing again, so a loop that only ever
    attacks is not playing the fight the screen offers.
    """
    played = 0
    for _ in range(limit):
        if conn.execute(
            "SELECT status FROM battles WHERE battle_id = %s", (battle,)
        ).fetchone()[0] != "active":
            break
        for one in who:
            try:
                # Savepointed: running out of qi is an ordinary refusal, and
                # without one it would poison the whole fight.
                with conn.transaction():
                    conn.execute(
                        "SELECT duel_choose(%s, %s, 'attack', %s)",
                        (battle, one, a_move(conn, one)),
                    )
            except psycopg.errors.CheckViolation:
                conn.execute("SELECT duel_choose(%s, %s, 'guard')", (battle, one))
        played += 1
    return played


def rounds_played(conn, battle_id):
    return conn.execute(
        "SELECT turn_number FROM battles WHERE battle_id = %s", (battle_id,)
    ).fetchone()[0]


# ---------------------------------------------------------------------------


def test_a_duel_needs_two_standing_cultivators(conn, make_player):
    a = duellist(conn, make_player, "Alone")
    b = duellist(conn, make_player, "Felled")
    conn.execute(
        "UPDATE player_physique SET current_hp = 0 WHERE player_id = %s", (b,)
    )
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute("SELECT duel_open(%s, %s)", (a, b))


def test_nobody_duels_themselves(conn, make_player):
    a = duellist(conn, make_player, "Mirror")
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute("SELECT duel_open(%s, %s)", (a, a))


def test_a_duel_claims_both_of_them(conn, make_player):
    """`player_active_battle` is one row per player whatever the fight is.

    This is why every guard below has to exist: the claim is what `/battle`
    and `/abandon` find a fight through, so a duel is visible to both of them
    the instant it opens.
    """
    a = duellist(conn, make_player, "Claimed-A")
    b = duellist(conn, make_player, "Claimed-B")
    battle = conn.execute("SELECT duel_open(%s, %s)", (a, b)).fetchone()[0]

    held = conn.execute(
        "SELECT count(*) FROM player_active_battle WHERE battle_id = %s",
        (battle,),
    ).fetchone()[0]
    assert held == 2, "a duel left one of them free to walk into another fight"


def test_forcing_a_round_that_is_still_running_is_refused(conn, make_player):
    """THE EXPLOIT 0548 CLOSED.

    `duel_force` braces whoever has not answered. Without a deadline, either
    side could pick their heaviest attack and force the other to brace on the
    spot - swinging every round, taking nothing back, and winning every duel
    without being hit once.
    """
    a = duellist(conn, make_player, "Patient")
    b = duellist(conn, make_player, "Hurried")
    battle = conn.execute("SELECT duel_open(%s, %s)", (a, b)).fetchone()[0]
    conn.execute(
        "SELECT duel_choose(%s, %s, 'attack', %s)", (battle, a, a_move(conn, a))
    )

    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute("SELECT duel_force(%s)", (battle,))


def test_a_round_that_has_run_out_can_be_forced(conn, make_player):
    a = duellist(conn, make_player, "Waiting")
    b = duellist(conn, make_player, "Gone")
    battle = conn.execute("SELECT duel_open(%s, %s)", (a, b)).fetchone()[0]
    conn.execute(
        "SELECT duel_choose(%s, %s, 'attack', %s)", (battle, a, a_move(conn, a))
    )
    was = rounds_played(conn, battle)

    age_the_round(conn, battle)
    conn.execute("SELECT duel_force(%s)", (battle,))

    assert rounds_played(conn, battle) > was, (
        "a round whose time had run out was still not played"
    )


def test_a_resolved_round_does_not_let_the_next_one_be_forced(conn, make_player):
    """THE THEFT 0549 CLOSED, and the reason 0548's guard was not enough.

    `duel_resolve` ends by setting `intent_action` and `chose_at` back to NULL
    on both seats. So the instant a round is played, 0548's "nobody has chosen,
    so there is nothing to force them away from" became true again - and fifty
    presses braced both sides to `battle_turn_cap` and DREW the duel. The side
    about to lose could deny the win outright.
    """
    a = duellist(conn, make_player, "Winner")
    b = duellist(conn, make_player, "Staller")
    battle = conn.execute("SELECT duel_open(%s, %s)", (a, b)).fetchone()[0]

    # Play one round honestly, both of them answering.
    conn.execute(
        "SELECT duel_choose(%s, %s, 'guard')", (battle, a)
    )
    conn.execute(
        "SELECT duel_choose(%s, %s, 'guard')", (battle, b)
    )
    was = rounds_played(conn, battle)

    # Savepoint, so the refusal aborts only itself and the count below is
    # still readable. See tests/test_battles.py for the same note.
    with pytest.raises(psycopg.errors.CheckViolation):
        with conn.transaction():
            conn.execute("SELECT duel_force(%s)", (battle,))

    assert rounds_played(conn, battle) == was, (
        "a refused force played a round anyway"
    )


def test_battle_act_will_not_drive_a_duel(conn, make_player):
    """It reads seat 1 as a creature and takes no player argument.

    `species_id`, `creature_moves`, `roll_creature_intent` - and it always
    acts as seat 0, so on a duel the second cultivator would be swinging as
    the first, at an opponent with no species at all.
    """
    a = duellist(conn, make_player, "Seat-nought")
    b = duellist(conn, make_player, "Seat-one")
    battle = conn.execute("SELECT duel_open(%s, %s)", (a, b)).fetchone()[0]

    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute("SELECT battle_act(%s, 'guard')", (battle,))


def test_a_duel_is_not_walked_away_from(conn, make_player):
    a = duellist(conn, make_player, "Leaver")
    b = duellist(conn, make_player, "Left")
    battle = conn.execute("SELECT duel_open(%s, %s)", (a, b)).fetchone()[0]

    with pytest.raises(psycopg.errors.CheckViolation):
        with conn.transaction():
            conn.execute("SELECT battle_abandon(%s)", (battle,))

    assert conn.execute(
        "SELECT status FROM battles WHERE battle_id = %s", (battle,)
    ).fetchone()[0] == "active", "the refusal still ended the duel"


def test_yielding_is_losing(conn, make_player):
    """A concession that cost nothing would be the same escape, politer.

    `battle_conclude` reads the winner off who is left standing, so the
    conceder goes down - and that is deliberate rather than incidental: being
    felled and yielding cost the same, which makes the choice whether to keep
    swinging and not whether to pay.
    """
    a = duellist(conn, make_player, "Yielder")
    b = duellist(conn, make_player, "Taker")
    battle = conn.execute("SELECT duel_open(%s, %s)", (a, b)).fetchone()[0]

    won = conn.execute(
        "SELECT winner FROM duel_concede(%s, %s)", (battle, a)
    ).fetchone()[0]

    assert won == b, "conceding named the wrong cultivator"
    assert conn.execute(
        "SELECT current_hp FROM player_physique WHERE player_id = %s", (a,)
    ).fetchone()[0] == 0, "the cultivator who yielded walked away standing"
    assert conn.execute(
        "SELECT count(*) FROM player_active_battle WHERE battle_id = %s",
        (battle,),
    ).fetchone()[0] == 0, "a conceded duel still held one of them"


def test_only_the_two_of_them_may_yield_it(conn, make_player):
    a = duellist(conn, make_player, "In-A")
    b = duellist(conn, make_player, "In-B")
    outsider = duellist(conn, make_player, "Outside")
    battle = conn.execute("SELECT duel_open(%s, %s)", (a, b)).fetchone()[0]

    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute("SELECT duel_concede(%s, %s)", (battle, outsider))


def test_a_duel_cannot_run_forever(conn, make_player):
    """THE LOCK 0548 CLOSED.

    `battle_act` caps everything that is not 'pve' at `battle_turn_cap` and a
    duel does not go through `battle_act`, so it inherited none of it. Two
    cultivators who both brace take nothing from each other - and the claim
    on both of them is a lock on hunting, delving, the horde and the dungeon
    for as long as it lasts.
    """
    a = duellist(conn, make_player, "Cautious-A")
    b = duellist(conn, make_player, "Cautious-B")
    battle = conn.execute("SELECT duel_open(%s, %s)", (a, b)).fetchone()[0]
    cap = conn.execute(
        "SELECT game_config_value('battle_turn_cap')"
    ).fetchone()[0]

    # The cap is reached rather than played to, because fifty braced rounds
    # prove nothing the fiftieth does not.
    conn.execute(
        "UPDATE battles SET turn_number = %s WHERE battle_id = %s",
        (int(cap), battle),
    )
    conn.execute("SELECT duel_choose(%s, %s, 'guard')", (battle, a))
    conn.execute("SELECT duel_choose(%s, %s, 'guard')", (battle, b))

    status, winner = conn.execute(
        "SELECT status, winner_side FROM battles WHERE battle_id = %s",
        (battle,),
    ).fetchone()
    assert status == "expired", f"a duel at the cap ended as {status}"
    assert winner is None, "a duel nobody won named a winner"
    assert conn.execute(
        "SELECT count(*) FROM player_active_battle WHERE battle_id = %s",
        (battle,),
    ).fetchone()[0] == 0, "a duel that ran out of rounds still held them"


def test_both_blows_land_in_the_same_round(conn, make_player):
    """A duel cannot be won by moving first.

    `duel_resolve` measures both blows against the health each side held when
    the round OPENED, so a cultivator cut down this round still lands theirs.
    Two bodies thin enough to fall in one blow each is the only way to see it.
    """
    a = duellist(conn, make_player, "Together-A", hp=1, strength=9_000_000)
    b = duellist(conn, make_player, "Together-B", hp=1, strength=9_000_000)
    battle = conn.execute("SELECT duel_open(%s, %s)", (a, b)).fetchone()[0]

    conn.execute(
        "SELECT duel_choose(%s, %s, 'attack', %s)", (battle, a, a_move(conn, a))
    )
    conn.execute(
        "SELECT duel_choose(%s, %s, 'attack', %s)", (battle, b, a_move(conn, b))
    )

    standing = conn.execute(
        "SELECT count(*) FROM battle_combatants "
        "WHERE battle_id = %s AND current_hp > 0",
        (battle,),
    ).fetchone()[0]
    assert standing == 0, (
        "one of them survived a round that should have felled both - the "
        "second blow was measured against health the first had already taken"
    )
    assert conn.execute(
        "SELECT winner_side FROM battles WHERE battle_id = %s", (battle,)
    ).fetchone()[0] is None, "a double knockout handed the duel to a seat"


def test_the_stronger_body_wins(conn, make_player):
    """The cheapest guard against the two sides being swapped.

    `compute_duel_damage` scaled the defence divisor by the defender's
    CREATURE rank earlier in this build, so a player defender fell to rank 1
    and a blow that looked reasonable was 5.2 billion rounds from killing
    anybody. A duel where the weaker body wins would say the same thing.

    THE RATIOS ARE REAL ONES. 0532's curve reads strength per point of health
    and nothing else, and the live world runs 0.20 at rank 1 to 3.91 near the
    top - so a pair invented at 0.10 and 0.002, as this test first used, is
    measuring a fight nobody can have. It drew at the cap, which is exactly
    what 0550 was written about.
    """
    strong = duellist(conn, make_player, "Strong", hp=50_000, strength=100_000)
    weak = duellist(conn, make_player, "Weak", hp=50_000, strength=10_000)
    battle = conn.execute(
        "SELECT duel_open(%s, %s)", (strong, weak)
    ).fetchone()[0]

    play_out(conn, battle, strong, weak)

    winner = conn.execute(
        "SELECT winner_side FROM battles WHERE battle_id = %s", (battle,)
    ).fetchone()[0]
    assert winner == 0, (
        f"the body with ten times the strength did not win (side {winner})"
    )


def test_the_shallow_end_can_win_a_duel(conn, make_player):
    """WHAT 0550 FIXED, pinned against figures this file builds itself.

    `duel_bite` was 0.05, and at the strength-per-health a rank 1 cultivator
    actually has - 0.20 - a blow landed for so little of the pool that fifty
    rounds of real damage ran into `battle_turn_cap` and were called a draw.
    Three of seven live standings could not win a duel at all.

    A mirror duel is the longest a fight at a given depth can run, so if this
    one finishes, every uneven pairing at that depth finishes sooner.
    """
    cap = conn.execute(
        "SELECT game_config_value('battle_turn_cap')"
    ).fetchone()[0]

    # 0.20 strength per point of health: the shallowest ratio in the world.
    a = duellist(conn, make_player, "Shallow-A", hp=50_000, strength=10_000)
    b = duellist(conn, make_player, "Shallow-B", hp=50_000, strength=10_000)
    battle = conn.execute("SELECT duel_open(%s, %s)", (a, b)).fetchone()[0]

    rounds = play_out(conn, battle, a, b, limit=int(cap) + 5)

    status = conn.execute(
        "SELECT status FROM battles WHERE battle_id = %s", (battle,)
    ).fetchone()[0]
    assert status != "expired", (
        f"two cultivators at the shallow end landed blows for {rounds} rounds "
        f"and the turn cap ({cap}) called it a draw"
    )
    # And with room to spare, because a braced round must not be the thing
    # that tips it back into a draw.
    assert rounds < int(cap) * 0.8, (
        f"the shallow end won in {rounds} rounds against a cap of {cap} - "
        "no margin for a round spent bracing"
    )
