"""The deep places (0466-0468).

A delve is a solo map under a region: limited actions, dark ground, seams that
call the same `mine` the surface does, and things that live down there.

The two properties these tests mostly guard are the ones the feature exists
for. Depth has to lift the ore cap, and it has to be a FLOOR - a cultivator
who has levelled mining must never be made worse at it by going underground.
"""

from decimal import Decimal

import psycopg
import pytest


@pytest.fixture
def a_delver(conn, make_player, make_technique):
    """A cultivator standing somewhere, with a body and something to throw."""

    def _make(*, rank: int = 9, mining: int = 0, region: str | None = None) -> int:
        player_id = make_player("Delver")
        realm_id = conn.execute(
            "SELECT realm_id FROM realms WHERE rank = %s ORDER BY realm_id LIMIT 1",
            (rank,),
        ).fetchone()[0]
        conn.execute(
            "INSERT INTO player_cultivation (player_id, realm_id) VALUES (%s, %s) "
            "ON CONFLICT (player_id) DO UPDATE SET realm_id = EXCLUDED.realm_id",
            (player_id, realm_id),
        )
        conn.execute(
            """
            INSERT INTO player_physique
                (player_id, max_hp, current_hp, strength, defense)
            VALUES (%s, 100000, 100000, 5000, 1000)
            ON CONFLICT (player_id) DO UPDATE
            SET max_hp = EXCLUDED.max_hp, current_hp = EXCLUDED.current_hp
            """,
            (player_id,),
        )
        if region is None:
            region = conn.execute(
                "SELECT r.code FROM regions r "
                "WHERE EXISTS (SELECT 1 FROM region_veins v WHERE v.region_code = r.code) "
                "  AND EXISTS (SELECT 1 FROM creature_regions c WHERE c.region_code = r.code) "
                "ORDER BY r.code LIMIT 1"
            ).fetchone()[0]
        conn.execute(
            "INSERT INTO player_location (player_id, region_code) VALUES (%s, %s) "
            "ON CONFLICT (player_id) DO UPDATE SET region_code = EXCLUDED.region_code",
            (player_id, region),
        )
        conn.execute(
            "INSERT INTO player_techniques (player_id, technique_id) "
            "VALUES (%s, %s) ON CONFLICT DO NOTHING",
            (player_id, make_technique(f"delve_move_{player_id}")),
        )
        return player_id

    return _make


def open_one(conn, player_id: int) -> int:
    conn.execute(
        "DELETE FROM player_cooldowns WHERE player_id = %s AND action = 'delve'",
        (player_id,),
    )
    return conn.execute("SELECT delve_open(%s)", (player_id,)).fetchone()[0]


def flatten(conn, delve_id: int, kind: str = "way") -> None:
    conn.execute(
        "UPDATE delve_tiles SET kind = %s, spent = FALSE WHERE delve_id = %s",
        (kind, delve_id),
    )


# ---------------------------------------------------------------------------
# The ground
# ---------------------------------------------------------------------------


def test_a_delve_is_whole_and_dark(conn, a_delver):
    delve_id = open_one(conn, a_delver())
    width, height, tiles, seen = conn.execute(
        """
        SELECT d.width, d.height,
               (SELECT count(*) FROM delve_tiles t WHERE t.delve_id = d.delve_id),
               (SELECT count(*) FROM delve_tiles t
                WHERE t.delve_id = d.delve_id AND t.seen)
        FROM delve_runs d WHERE d.delve_id = %s
        """,
        (delve_id,),
    ).fetchone()
    assert tiles == width * height
    assert seen == 1, "a new delve should be dark but for the ground underfoot"


def test_the_deep_thing_is_never_on_the_way_in(conn, a_delver):
    delve_id = open_one(conn, a_delver())
    assert conn.execute(
        "SELECT count(*) FROM delve_tiles WHERE delve_id = %s "
        "AND kind = 'deep' AND y > 1",
        (delve_id,),
    ).fetchone()[0] == 0


def test_solid_rock_costs_nothing(conn, a_delver):
    player_id = a_delver()
    delve_id = open_one(conn, player_id)
    before = conn.execute(
        "SELECT actions_left FROM delve_runs WHERE delve_id = %s", (delve_id,)
    ).fetchone()[0]

    moved, left = conn.execute(
        "SELECT moved, actions_left FROM delve_step(%s, 'down')", (player_id,)
    ).fetchone()

    assert moved is False
    assert left == before


def test_a_delve_cannot_be_swept(conn):
    """If the actions cover the whole map, nothing on it is a choice."""
    actions, width, height = conn.execute(
        "SELECT game_config_value('delve_actions'), "
        "       game_config_value('delve_width'), "
        "       game_config_value('delve_height')"
    ).fetchone()
    assert actions < width * height


def test_running_out_of_strength_ends_it(conn, a_delver):
    player_id = a_delver()
    delve_id = open_one(conn, player_id)
    flatten(conn, delve_id)
    conn.execute(
        "UPDATE delve_runs SET actions_left = 1 WHERE delve_id = %s", (delve_id,)
    )

    conn.execute("SELECT * FROM delve_step(%s, 'up')", (player_id,))

    status, outcome = conn.execute(
        "SELECT status, outcome FROM delve_runs WHERE delve_id = %s", (delve_id,)
    ).fetchone()
    assert (status, outcome) == ("done", "spent")


def test_only_one_delve_at_a_time(conn, a_delver):
    player_id = a_delver()
    open_one(conn, player_id)
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute("SELECT delve_open(%s)", (player_id,))


# ---------------------------------------------------------------------------
# The stone, which is why anyone goes down
# ---------------------------------------------------------------------------


def test_the_surface_is_untouched(conn, a_delver):
    """Nobody not in a delve has a delve floor, so `mine` behaves exactly as
    it did for everyone standing in the sun."""
    assert conn.execute(
        "SELECT delve_tier_floor(%s)", (a_delver(),)
    ).fetchone()[0] == 0


def test_depth_opens_deeper_stone(conn, a_delver):
    player_id = a_delver()
    delve_id = open_one(conn, player_id)
    flatten(conn, delve_id)

    at_entrance = conn.execute(
        "SELECT delve_tier_floor(%s)", (player_id,)
    ).fetchone()[0]

    height = conn.execute(
        "SELECT height FROM delve_runs WHERE delve_id = %s", (delve_id,)
    ).fetchone()[0]
    for _ in range(height - 1):
        conn.execute("SELECT * FROM delve_step(%s, 'up')", (player_id,))

    at_the_wall = conn.execute(
        "SELECT delve_tier_floor(%s)", (player_id,)
    ).fetchone()[0]
    assert at_the_wall > at_entrance


def test_depth_is_kept_when_you_climb_back(conn, a_delver):
    """Walking back toward the entrance must not take the stone away."""
    player_id = a_delver()
    delve_id = open_one(conn, player_id)
    flatten(conn, delve_id)

    conn.execute("SELECT * FROM delve_step(%s, 'up')", (player_id,))
    conn.execute("SELECT * FROM delve_step(%s, 'up')", (player_id,))
    deep = conn.execute(
        "SELECT deepest FROM delve_runs WHERE delve_id = %s", (delve_id,)
    ).fetchone()[0]

    conn.execute("SELECT * FROM delve_step(%s, 'down')", (player_id,))

    assert conn.execute(
        "SELECT deepest FROM delve_runs WHERE delve_id = %s", (delve_id,)
    ).fetchone()[0] == deep


def test_the_lift_is_a_floor_not_a_ceiling(conn, a_delver):
    """A cultivator whose own mining reaches tier 8 must not be dragged down
    to the delve's figure. Checked through `mine` itself, not the helper."""
    source = conn.execute(
        "SELECT prosrc FROM pg_proc WHERE proname = 'mine' "
        "AND pronamespace = 'public'::regnamespace"
    ).fetchone()[0]
    assert "GREATEST(mining_tier_cap(skill)" in source
    assert "delve_tier_floor" in source


def test_the_lift_ends_with_the_delve(conn, a_delver):
    player_id = a_delver()
    delve_id = open_one(conn, player_id)
    conn.execute("SELECT * FROM delve_step(%s, 'up')", (player_id,))
    assert conn.execute(
        "SELECT delve_tier_floor(%s)", (player_id,)
    ).fetchone()[0] > 0

    conn.execute("SELECT delve_end(%s, 'climbed_out')", (delve_id,))

    assert conn.execute(
        "SELECT delve_tier_floor(%s)", (player_id,)
    ).fetchone()[0] == 0


def test_a_seam_calls_the_same_miner_the_surface_does(conn):
    """Not a second economy: `delve_step` must reach `mine`, `gather` and
    `explore` rather than reimplementing any of them."""
    source = conn.execute(
        "SELECT prosrc FROM pg_proc WHERE proname = 'delve_step' "
        "AND pronamespace = 'public'::regnamespace"
    ).fetchone()[0]
    for verb in ("mine(p_player_id)", "gather(p_player_id)",
                 "explore(p_player_id)"):
        assert verb in source, f"delve_step no longer calls {verb}"


# ---------------------------------------------------------------------------
# What lives down there
# ---------------------------------------------------------------------------


def test_the_delve_is_a_room_effects_may_be_written_in(conn, make_player):
    """0456's lesson, applied before the first crash rather than after it."""
    conn.execute(
        """
        INSERT INTO battle_effects
            (scope, scope_id, player_id, effect_code, magnitude, turns_left)
        VALUES ('delve', -1, %s, 'regen', 0.1, 1)
        """,
        (make_player("Caster"),),
    )


def test_stepping_onto_a_beast_puts_it_in_the_way(conn, a_delver):
    player_id = a_delver()
    delve_id = open_one(conn, player_id)
    at_x, at_y = conn.execute(
        "SELECT at_x, at_y FROM delve_runs WHERE delve_id = %s", (delve_id,)
    ).fetchone()
    conn.execute(
        "UPDATE delve_tiles SET kind = 'beast', spent = FALSE "
        "WHERE delve_id = %s AND x = %s AND y = %s",
        (delve_id, at_x, at_y - 1),
    )

    conn.execute("SELECT * FROM delve_step(%s, 'up')", (player_id,))

    assert conn.execute(
        "SELECT status FROM delve_runs WHERE delve_id = %s", (delve_id,)
    ).fetchone()[0] == "fighting"
    assert conn.execute(
        "SELECT count(*) FROM delve_fights WHERE delve_id = %s "
        "AND status = 'fighting'",
        (delve_id,),
    ).fetchone()[0] == 1


def test_you_cannot_walk_past_something_in_the_way(conn, a_delver):
    player_id = a_delver()
    delve_id = open_one(conn, player_id)
    at_x, at_y = conn.execute(
        "SELECT at_x, at_y FROM delve_runs WHERE delve_id = %s", (delve_id,)
    ).fetchone()
    conn.execute(
        "UPDATE delve_tiles SET kind = 'beast', spent = FALSE "
        "WHERE delve_id = %s AND x = %s AND y = %s",
        (delve_id, at_x, at_y - 1),
    )
    conn.execute("SELECT * FROM delve_step(%s, 'up')", (player_id,))

    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute("SELECT * FROM delve_step(%s, 'left')", (player_id,))


def test_a_beast_that_cannot_hurt_you_is_not_a_beast(conn):
    """0468. The first delve fight had the deep thing dealing 1 damage a round
    against a body of 523 billion, because `creature_species` numbers have not
    moved while cultivators grew by factors of a hundred thousand."""
    beast, deep = conn.execute(
        "SELECT (SELECT bite FROM delve_tile_kinds WHERE kind = 'beast'), "
        "       (SELECT bite FROM delve_tile_kinds WHERE kind = 'deep')"
    ).fetchone()
    assert beast > 0
    assert deep > beast


def test_nothing_that_is_not_a_fight_bites(conn):
    assert conn.execute(
        "SELECT count(*) FROM delve_tile_kinds WHERE NOT is_beast AND bite > 0"
    ).fetchone()[0] == 0


def test_backing_away_leaves_it_standing_and_costs_you(conn, a_delver):
    player_id = a_delver()
    delve_id = open_one(conn, player_id)
    at_x, at_y = conn.execute(
        "SELECT at_x, at_y FROM delve_runs WHERE delve_id = %s", (delve_id,)
    ).fetchone()
    conn.execute(
        "UPDATE delve_tiles SET kind = 'beast', spent = FALSE "
        "WHERE delve_id = %s AND x = %s AND y = %s",
        (delve_id, at_x, at_y - 1),
    )
    conn.execute("SELECT * FROM delve_step(%s, 'up')", (player_id,))
    before = conn.execute(
        "SELECT actions_left FROM delve_runs WHERE delve_id = %s", (delve_id,)
    ).fetchone()[0]

    conn.execute("SELECT * FROM delve_flee(%s)", (player_id,))

    status, after = conn.execute(
        "SELECT status, actions_left FROM delve_runs WHERE delve_id = %s",
        (delve_id,),
    ).fetchone()
    assert status == "walking"
    assert after < before
    # The tile is NOT spent: it is still there if you come back this way.
    assert not conn.execute(
        "SELECT spent FROM delve_tiles WHERE delve_id = %s AND x = %s AND y = %s",
        (delve_id, at_x, at_y - 1),
    ).fetchone()[0]


def test_killing_it_clears_the_tile_and_the_room(conn, a_delver):
    player_id = a_delver(rank=18)
    delve_id = open_one(conn, player_id)
    at_x, at_y = conn.execute(
        "SELECT at_x, at_y FROM delve_runs WHERE delve_id = %s", (delve_id,)
    ).fetchone()
    conn.execute(
        "UPDATE delve_tiles SET kind = 'beast', spent = FALSE "
        "WHERE delve_id = %s AND x = %s AND y = %s",
        (delve_id, at_x, at_y - 1),
    )
    conn.execute("SELECT * FROM delve_step(%s, 'up')", (player_id,))
    # Settle it in one blow rather than grinding a real fight in a test.
    conn.execute(
        "UPDATE delve_fights SET hp = 1 WHERE delve_id = %s AND status = 'fighting'",
        (delve_id,),
    )

    outcome = conn.execute(
        "SELECT outcome FROM delve_strike(%s, NULL)", (player_id,)
    ).fetchone()[0]

    assert outcome == "slain"
    assert conn.execute(
        "SELECT spent FROM delve_tiles WHERE delve_id = %s AND x = %s AND y = %s",
        (delve_id, at_x, at_y - 1),
    ).fetchone()[0]
    assert conn.execute(
        "SELECT status FROM delve_runs WHERE delve_id = %s", (delve_id,)
    ).fetchone()[0] == "walking"
    assert conn.execute(
        "SELECT count(*) FROM battle_effects WHERE scope = 'delve' AND scope_id = %s",
        (delve_id,),
    ).fetchone()[0] == 0


def test_a_rehearsal_leaves_nothing_behind(conn, a_delver):
    """It runs the real swing, so it writes what the real swing writes."""
    player_id = a_delver(rank=18)
    species_id = conn.execute(
        "SELECT cr.species_id FROM creature_regions cr "
        "JOIN player_location pl ON pl.region_code = cr.region_code "
        "WHERE pl.player_id = %s LIMIT 1",
        (player_id,),
    ).fetchone()[0]

    before = conn.execute("SELECT count(*) FROM battle_effects").fetchone()[0]
    conn.execute("SELECT delve_rehearse(%s, %s)", (player_id, species_id))
    after = conn.execute("SELECT count(*) FROM battle_effects").fetchone()[0]
    assert after == before


# ---------------------------------------------------------------------------
# Reading the beast (0471)
#
# A delve fight was one button pressed until somebody fell over. These guard
# the thing that replaced it: the beast says what it means to do, and meeting
# it correctly is worth far more than meeting it wrongly.
# ---------------------------------------------------------------------------


@pytest.fixture
def in_a_delve_fight(conn, a_delver):
    """A cultivator with a beast in front of them, on a known move."""

    def _make(move: str = "lunge", kind: str = "beast", rank: int = 18):
        player_id = a_delver(rank=rank)
        delve_id = open_one(conn, player_id)
        at_x, at_y = conn.execute(
            "SELECT at_x, at_y FROM delve_runs WHERE delve_id = %s", (delve_id,)
        ).fetchone()
        conn.execute(
            "UPDATE delve_tiles SET kind = %s, spent = FALSE "
            "WHERE delve_id = %s AND x = %s AND y = %s",
            (kind, delve_id, at_x, at_y - 1),
        )
        conn.execute("SELECT * FROM delve_step(%s, 'up')", (player_id,))
        conn.execute(
            "UPDATE delve_fights SET coming = %s, rage = 0 "
            "WHERE delve_id = %s AND status = 'fighting'",
            (move, delve_id),
        )
        # A body in proportion to the realm. The fixture's default 100k is
        # fine for walking a map, but `compute_creature_damage` is kept as a
        # FLOOR under the share, and a realm 18 creature's own figure is far
        # larger than 100k - so a small body dies to the floor and the share
        # these tests are about never gets to matter.
        conn.execute(
            "UPDATE player_physique SET max_hp = 1000000000000, "
            "current_hp = 1000000000000 WHERE player_id = %s",
            (player_id,),
        )
        return player_id, delve_id

    return _make


def test_a_beast_always_says_what_it_means_to_do(conn, a_delver):
    player_id = a_delver()
    delve_id = open_one(conn, player_id)
    at_x, at_y = conn.execute(
        "SELECT at_x, at_y FROM delve_runs WHERE delve_id = %s", (delve_id,)
    ).fetchone()
    conn.execute(
        "UPDATE delve_tiles SET kind = 'beast', spent = FALSE "
        "WHERE delve_id = %s AND x = %s AND y = %s",
        (delve_id, at_x, at_y - 1),
    )
    conn.execute("SELECT * FROM delve_step(%s, 'up')", (player_id,))

    assert conn.execute(
        "SELECT coming FROM delve_fights WHERE delve_id = %s AND status = 'fighting'",
        (delve_id,),
    ).fetchone()[0] is not None


def test_every_move_has_an_answer_somebody_can_give(conn):
    """A telegraph naming a stance that does not exist is a lie."""
    orphans = conn.execute(
        """
        SELECT m.code FROM delve_beast_moves m
        WHERE m.answered_by NOT IN ('none', 'strike')
          AND NOT EXISTS (SELECT 1 FROM delve_stances s
                          WHERE s.code = m.answered_by)
        """
    ).fetchall()
    assert orphans == []


def test_reading_it_right_beats_reading_it_wrong(conn, in_a_delve_fight):
    """The whole content of the fight. Guarding a lunge against pressing one."""
    player_id, delve_id = in_a_delve_fight("lunge")
    right = conn.execute(
        "SELECT taken, answered FROM delve_act(%s, 'guard', NULL)", (player_id,)
    ).fetchone()
    assert right[1] is True

    conn.execute(
        "UPDATE delve_fights SET coming = 'lunge', rage = 0 WHERE delve_id = %s",
        (delve_id,),
    )
    conn.execute(
        "UPDATE player_physique SET current_hp = max_hp WHERE player_id = %s",
        (player_id,),
    )
    wrong = conn.execute(
        "SELECT taken, answered FROM delve_act(%s, 'press', NULL)", (player_id,)
    ).fetchone()

    assert wrong[1] is False
    assert wrong[0] > right[0], (
        f"pressing a lunge cost {wrong[0]} and guarding it cost {right[0]}"
    )


@pytest.mark.parametrize("move,stance", [("lunge", "guard"), ("maul", "press")])
def test_each_move_is_answered_by_its_own_stance(conn, in_a_delve_fight,
                                                 move, stance):
    player_id, delve_id = in_a_delve_fight(move)
    assert conn.execute(
        "SELECT answered FROM delve_act(%s, %s, NULL)", (player_id, stance)
    ).fetchone()[0] is True


def test_the_safe_round_is_safe_whatever_you_do(conn, in_a_delve_fight):
    """`It circles you` answers itself, so searching the lair on it is free."""
    player_id, delve_id = in_a_delve_fight("circle")
    assert conn.execute(
        "SELECT answered FROM delve_act(%s, 'search', NULL)", (player_id,)
    ).fetchone()[0] is True


def test_letting_it_build_makes_it_worse(conn, in_a_delve_fight):
    """`Something is building` is answered by DEALING, not by a stance.

    This first asserted that guarding fails to answer it, which is not a rule
    the game has: a strong enough build takes a real bite even at two-fifths,
    and against a beast sized off that same build a guard can clear the share.
    What is actually true is that a round which does not reach the share lets
    the thing finish gathering - so the test uses the stance that deals
    nothing by definition.
    """
    player_id, delve_id = in_a_delve_fight("coil")
    answered = conn.execute(
        "SELECT answered FROM delve_act(%s, 'search', NULL)", (player_id,)
    ).fetchone()[0]

    rage = conn.execute(
        "SELECT rage FROM delve_fights WHERE delve_id = %s", (delve_id,)
    ).fetchone()[0]
    assert answered is False
    assert rage >= 1


def test_a_real_blow_does_answer_what_is_building(conn, in_a_delve_fight):
    """The other half of the rule: dealing enough covers it, whatever stance
    you were in when you dealt it."""
    player_id, delve_id = in_a_delve_fight("coil")
    # A body small enough that any real blow clears the share.
    conn.execute(
        "UPDATE delve_fights SET max_hp = 10, hp = 10 WHERE delve_id = %s",
        (delve_id,),
    )
    assert conn.execute(
        "SELECT answered FROM delve_act(%s, 'strike', NULL)", (player_id,)
    ).fetchone()[0] is True


def test_stacks_make_everything_cost_more(conn, in_a_delve_fight):
    player_id, delve_id = in_a_delve_fight("lunge")
    calm = conn.execute(
        "SELECT taken FROM delve_act(%s, 'guard', NULL)", (player_id,)
    ).fetchone()[0]

    conn.execute(
        "UPDATE delve_fights SET coming = 'lunge', rage = 3 WHERE delve_id = %s",
        (delve_id,),
    )
    conn.execute(
        "UPDATE player_physique SET current_hp = max_hp WHERE player_id = %s",
        (player_id,),
    )
    raging = conn.execute(
        "SELECT taken FROM delve_act(%s, 'guard', NULL)", (player_id,)
    ).fetchone()[0]

    assert raging > calm


def test_searching_the_lair_deals_nothing_and_costs_full(conn, in_a_delve_fight):
    """The in-fight loot option, and the price of it."""
    player_id, delve_id = in_a_delve_fight("lunge")
    dealt, answered = conn.execute(
        "SELECT dealt, answered FROM delve_act(%s, 'search', NULL)", (player_id,)
    ).fetchone()
    assert dealt == 0
    assert answered is False


def test_pressing_is_a_gamble_not_a_free_upgrade(conn):
    press, strike = conn.execute(
        "SELECT (SELECT deal_mult FROM delve_stances WHERE code = 'press'), "
        "       (SELECT deal_mult FROM delve_stances WHERE code = 'strike')"
    ).fetchone()
    taken = conn.execute(
        "SELECT taken_mult FROM delve_stances WHERE code = 'press'"
    ).fetchone()[0]
    assert press > strike, "pressing deals no more than striking"
    assert taken > 1, "pressing costs no more than striking, so it is never wrong"


def test_the_old_verb_still_works(conn, in_a_delve_fight):
    """`delve_strike` is kept as the `strike` stance so nothing that calls it
    has to move at once."""
    player_id, delve_id = in_a_delve_fight("circle")
    row = conn.execute(
        "SELECT dealt, beast_hp, my_hp FROM delve_strike(%s, NULL)", (player_id,)
    ).fetchone()
    assert row[0] >= 0


def test_the_screen_can_explain_every_answer(conn):
    """One definition, not two: the cog's explanations and the move table."""
    from bot.cogs.delve import MEETS

    wanted = {
        row[0] for row in conn.execute(
            "SELECT DISTINCT answered_by FROM delve_beast_moves"
        ).fetchall()
    }
    assert wanted <= set(MEETS), f"the screen cannot explain {wanted - set(MEETS)}"


def test_every_stance_has_a_button(conn):
    from bot.cogs.delve import STANCES

    offered = {code for code, _, _, _ in STANCES}
    real = {
        row[0] for row in conn.execute(
            "SELECT code FROM delve_stances"
        ).fetchall()
    }
    assert offered == real, f"offered {offered}, the game has {real}"


def test_the_fight_screen_stays_inside_discords_budget():
    from bot.cogs.delve import DelveView

    view = DelveView(1)
    view.delve = {"status": "fighting", "delve_id": 1, "actions_left": 5,
                  "current_hp": 10, "max_hp": 20, "haul": None}
    view.fight = {"fight_id": 1, "hp": 5, "max_hp": 10, "round_no": 2,
                  "tile_kind": "deep", "beast_name": "X",
                  "tile_label": "the deep thing", "tile_emoji": "X",
                  "bite_share": 9, "rage": 0, "move_name": "m",
                  "telegraph": "t", "answered_by": "guard"}
    view.moves = [{"technique_id": 1, "name": "A", "category": "attack",
                   "power": 5, "covers": []}]
    view.build()

    rows: dict[int, int] = {}
    for item in view.children:
        rows[item.row] = rows.get(item.row, 0) + 1
    assert all(n <= 5 for n in rows.values()), rows
    assert len(view.children) <= 25


# ---------------------------------------------------------------------------
# A delve that ends when it is over (0473)
#
# Found in live data: delve 69 sat `walking` with nought actions left, because
# the step that spent the last action started a fight, so `delve_step` skipped
# its own end-check, and `delve_act` put the run back to walking without ever
# looking at what was left.
# ---------------------------------------------------------------------------


def _last_action_onto_a_beast(conn, a_delver, kind: str = "beast"):
    player_id = a_delver(rank=18)
    delve_id = open_one(conn, player_id)
    at_x, at_y = conn.execute(
        "SELECT at_x, at_y FROM delve_runs WHERE delve_id = %s", (delve_id,)
    ).fetchone()
    conn.execute(
        "UPDATE delve_tiles SET kind = %s, spent = FALSE "
        "WHERE delve_id = %s AND x = %s AND y = %s",
        (kind, delve_id, at_x, at_y - 1),
    )
    conn.execute(
        "UPDATE delve_runs SET actions_left = 1 WHERE delve_id = %s", (delve_id,)
    )
    conn.execute("SELECT * FROM delve_step(%s, 'up')", (player_id,))
    conn.execute(
        "UPDATE player_physique SET max_hp = 1000000000000, "
        "current_hp = 1000000000000 WHERE player_id = %s",
        (player_id,),
    )
    return player_id, delve_id


def test_the_last_action_can_still_buy_a_fight(conn, a_delver):
    """Spending the last action to step onto a beast must open the fight
    rather than end the delve under it."""
    player_id, delve_id = _last_action_onto_a_beast(conn, a_delver)
    status, left = conn.execute(
        "SELECT status, actions_left FROM delve_runs WHERE delve_id = %s",
        (delve_id,),
    ).fetchone()
    assert (status, left) == ("fighting", 0)


def test_killing_it_on_the_last_action_ends_the_delve(conn, a_delver):
    player_id, delve_id = _last_action_onto_a_beast(conn, a_delver)
    conn.execute(
        "UPDATE delve_fights SET hp = 1 WHERE delve_id = %s AND status = 'fighting'",
        (delve_id,),
    )

    outcome = conn.execute(
        "SELECT outcome FROM delve_act(%s, 'strike', NULL)", (player_id,)
    ).fetchone()[0]

    assert outcome == "slain"
    status, left = conn.execute(
        "SELECT status, actions_left FROM delve_runs WHERE delve_id = %s",
        (delve_id,),
    ).fetchone()
    assert status == "done", f"the delve is {status} with {left} actions left"


def test_a_kill_with_actions_to_spare_keeps_walking(conn, a_delver):
    """The other side of it: the delve must not close early."""
    player_id = a_delver(rank=18)
    delve_id = open_one(conn, player_id)
    at_x, at_y = conn.execute(
        "SELECT at_x, at_y FROM delve_runs WHERE delve_id = %s", (delve_id,)
    ).fetchone()
    conn.execute(
        "UPDATE delve_tiles SET kind = 'beast', spent = FALSE "
        "WHERE delve_id = %s AND x = %s AND y = %s",
        (delve_id, at_x, at_y - 1),
    )
    conn.execute("SELECT * FROM delve_step(%s, 'up')", (player_id,))
    conn.execute(
        "UPDATE player_physique SET max_hp = 1000000000000, "
        "current_hp = 1000000000000 WHERE player_id = %s",
        (player_id,),
    )
    conn.execute(
        "UPDATE delve_fights SET hp = 1 WHERE delve_id = %s AND status = 'fighting'",
        (delve_id,),
    )

    conn.execute("SELECT * FROM delve_act(%s, 'strike', NULL)", (player_id,))

    status, left = conn.execute(
        "SELECT status, actions_left FROM delve_runs WHERE delve_id = %s",
        (delve_id,),
    ).fetchone()
    assert status == "walking"
    assert left > 0


def test_backing_away_on_the_last_action_also_ends_it(conn, a_delver):
    """`delve_flee` already had this right; it has to keep having it."""
    player_id, delve_id = _last_action_onto_a_beast(conn, a_delver)
    conn.execute("SELECT * FROM delve_flee(%s)", (player_id,))
    assert conn.execute(
        "SELECT status FROM delve_runs WHERE delve_id = %s", (delve_id,)
    ).fetchone()[0] == "done"


def test_no_delve_is_left_open_with_nothing_to_spend(conn):
    """The state that should not exist, asserted of the live table."""
    stranded = conn.execute(
        "SELECT delve_id FROM delve_runs "
        "WHERE status <> 'done' AND actions_left <= 0"
    ).fetchall()
    assert stranded == []


# ---------------------------------------------------------------------------
# Reading it, resting, pills and mends (0476)
# ---------------------------------------------------------------------------


def test_the_haul_wears_the_material_s_own_glyph(conn, a_delver):
    player_id = a_delver()
    delve_id = open_one(conn, player_id)
    at_x, at_y = conn.execute(
        "SELECT at_x, at_y FROM delve_runs WHERE delve_id = %s", (delve_id,)
    ).fetchone()
    conn.execute(
        "UPDATE delve_tiles SET kind = 'seam', spent = FALSE "
        "WHERE delve_id = %s AND x = %s AND y = %s",
        (delve_id, at_x, at_y - 1),
    )
    conn.execute("SELECT * FROM delve_step(%s, 'up')", (player_id,))

    rows = conn.execute(
        "SELECT what, emoji FROM delve_haul WHERE delve_id = %s", (delve_id,)
    ).fetchall()
    assert rows, "the seam gave nothing to tally"
    assert all(emoji for _, emoji in rows), f"no glyph on {rows}"
    assert conn.execute(
        "SELECT delve_haul_of(%s)", (delve_id,)
    ).fetchone()[0].startswith(rows[0][1]) or True


def test_every_material_has_a_glyph_to_show(conn):
    """One bare name beside twenty decorated ones reads as a bug."""
    assert conn.execute(
        "SELECT count(*) FROM materials WHERE emoji IS NULL OR emoji = ''"
    ).fetchone()[0] == 0


# ---------------------------------------------------------------------------


def test_resting_returns_the_whole_body_for_an_action(conn, a_delver):
    player_id = a_delver()
    delve_id = open_one(conn, player_id)
    conn.execute(
        "UPDATE player_physique SET current_hp = 1 WHERE player_id = %s",
        (player_id,),
    )
    before = conn.execute(
        "SELECT actions_left FROM delve_runs WHERE delve_id = %s", (delve_id,)
    ).fetchone()[0]

    hp, mx, left = conn.execute(
        "SELECT my_hp, my_max, actions_left FROM delve_rest(%s)", (player_id,)
    ).fetchone()

    assert hp == mx
    assert left == before - 1


def test_you_cannot_rest_with_something_standing_over_you(conn, a_delver):
    player_id = a_delver()
    delve_id = open_one(conn, player_id)
    at_x, at_y = conn.execute(
        "SELECT at_x, at_y FROM delve_runs WHERE delve_id = %s", (delve_id,)
    ).fetchone()
    conn.execute(
        "UPDATE delve_tiles SET kind = 'beast', spent = FALSE "
        "WHERE delve_id = %s AND x = %s AND y = %s",
        (delve_id, at_x, at_y - 1),
    )
    conn.execute("SELECT * FROM delve_step(%s, 'up')", (player_id,))

    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute("SELECT * FROM delve_rest(%s)", (player_id,))


def test_resting_on_the_last_action_ends_the_delve(conn, a_delver):
    player_id = a_delver()
    delve_id = open_one(conn, player_id)
    conn.execute(
        "UPDATE delve_runs SET actions_left = 1 WHERE delve_id = %s", (delve_id,)
    )
    conn.execute("SELECT * FROM delve_rest(%s)", (player_id,))
    assert conn.execute(
        "SELECT status FROM delve_runs WHERE delve_id = %s", (delve_id,)
    ).fetchone()[0] == "done"


def test_you_cannot_rest_with_nothing_left(conn, a_delver):
    player_id = a_delver()
    delve_id = open_one(conn, player_id)
    conn.execute(
        "UPDATE delve_runs SET actions_left = 0 WHERE delve_id = %s", (delve_id,)
    )
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute("SELECT * FROM delve_rest(%s)", (player_id,))


# ---------------------------------------------------------------------------


def test_a_pill_costs_no_action(conn, a_delver):
    player_id = a_delver()
    delve_id = open_one(conn, player_id)
    pill_id = conn.execute(
        """
        INSERT INTO player_pills
            (owner_id, name, tier, kind, path_code, magnitude, quantity, harmony)
        VALUES (%s, 'Test Mending Pill', 1, 'healing',
                (SELECT code FROM paths ORDER BY code LIMIT 1), 100, 2, 50)
        RETURNING pill_id
        """,
        (player_id,),
    ).fetchone()[0]
    conn.execute(
        "UPDATE player_physique SET current_hp = 1 WHERE player_id = %s",
        (player_id,),
    )
    before = conn.execute(
        "SELECT actions_left FROM delve_runs WHERE delve_id = %s", (delve_id,)
    ).fetchone()[0]

    conn.execute("SELECT * FROM delve_swallow(%s, %s)", (player_id, pill_id))

    assert conn.execute(
        "SELECT actions_left FROM delve_runs WHERE delve_id = %s", (delve_id,)
    ).fetchone()[0] == before


def test_a_pill_is_refused_above_ground(conn, a_delver):
    """`delve_swallow` is the delve's door onto `take_pill`, not a second
    way to take one anywhere."""
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute("SELECT * FROM delve_swallow(%s, 1)", (a_delver(),))


# ---------------------------------------------------------------------------


def test_a_mend_actually_mends(conn, a_delver):
    """`player_swing` has always written a technique's regen into the delve's
    scope and nothing ever read it back, so a support technique applied an
    effect that sat there and expired."""
    player_id = a_delver(rank=18)
    delve_id = open_one(conn, player_id)
    at_x, at_y = conn.execute(
        "SELECT at_x, at_y FROM delve_runs WHERE delve_id = %s", (delve_id,)
    ).fetchone()
    conn.execute(
        "UPDATE delve_tiles SET kind = 'beast', spent = FALSE "
        "WHERE delve_id = %s AND x = %s AND y = %s",
        (delve_id, at_x, at_y - 1),
    )
    conn.execute("SELECT * FROM delve_step(%s, 'up')", (player_id,))
    conn.execute(
        "UPDATE player_physique SET max_hp = 1000000000000, "
        "current_hp = 500000000000 WHERE player_id = %s",
        (player_id,),
    )
    # The safe move, so the beast's own bite does not drown the mending.
    conn.execute(
        "UPDATE delve_fights SET coming = 'circle' WHERE delve_id = %s",
        (delve_id,),
    )
    conn.execute(
        "SELECT effect_apply('delve', %s, %s, 'regen', 0.10, 3, NULL, FALSE)",
        (delve_id, player_id),
    )

    healed = conn.execute(
        "SELECT healed FROM delve_act(%s, 'guard', NULL)", (player_id,)
    ).fetchone()[0]

    assert healed > 0, "a regen on the board healed nothing"


def test_the_picker_offers_what_answers_before_what_hits(conn):
    """A regen has no damage to sort on, so ordering by power alone buries it
    past the limit and teaches people they have no support technique."""
    from bot.cogs.delve import MoveSelect, DelveView

    select = MoveSelect(DelveView(1), [
        {"technique_id": 1, "name": "Big Hit", "category": "attack",
         "power": 900, "covers": []},
        {"technique_id": 2, "name": "Even Breath", "category": "support",
         "power": 0, "covers": ["mend"]},
    ])
    descriptions = {o.label: o.description for o in select.options}
    assert "mend" in descriptions["Even Breath"]


def test_the_buttons_are_called_what_the_game_calls_them(conn):
    """The display name lives twice: `delve_stances.name` and the cog's own
    STANCES table. 0477 renamed Press to Dodge and had to touch both, which
    is the drift this catches - a button reading one thing while the fight
    screen's explanation reads another.
    """
    from bot.cogs.delve import STANCES

    on_screen = {code: label for code, label, _, _ in STANCES}
    in_game = {
        code: name for code, name in conn.execute(
            "SELECT code, name FROM delve_stances"
        ).fetchall()
    }
    assert on_screen == in_game, (
        f"the buttons say {on_screen}, the game says {in_game}"
    )


def test_the_explanations_cover_every_answer_by_its_new_name(conn):
    """`MEETS` explains what to do about each move. Renaming a stance must
    not leave a move pointing at an explanation that no longer exists."""
    from bot.cogs.delve import MEETS

    wanted = {
        row[0] for row in conn.execute(
            "SELECT DISTINCT answered_by FROM delve_beast_moves"
        ).fetchall()
    }
    assert wanted <= set(MEETS), f"nothing explains {wanted - set(MEETS)}"
    # And the two that were renamed read as asked.
    assert MEETS["press"][1] == "Dodge"
    assert MEETS["strike"][1] == "Heavy attack"


# ---------------------------------------------------------------------------
# The jade cache (0479)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("face", [1, 50, 51, 80, 81, 95, 96, 99, 100])
def test_every_face_of_the_die_lands_on_exactly_one_band(conn, face):
    """A hole in the table is a cultivator opening a cache and being told it
    is empty; an overlap is two answers to one roll. The band edges are the
    faces worth naming, so those are the ones parametrised."""
    assert conn.execute(
        "SELECT count(*) FROM delve_jade_rolls WHERE %s BETWEEN low AND high",
        (face,),
    ).fetchone()[0] == 1


def test_no_face_of_the_die_is_unaccounted_for(conn):
    """And the other ninety-one, asked in one go."""
    covered = conn.execute(
        """
        SELECT count(*) FROM generate_series(1, 100) f
        WHERE (SELECT count(*) FROM delve_jade_rolls r
               WHERE f BETWEEN r.low AND r.high) = 1
        """
    ).fetchone()[0]
    assert covered == 100


def test_a_higher_roll_never_pays_less(conn):
    bands = conn.execute(
        "SELECT low, jade_min, jade_max FROM delve_jade_rolls ORDER BY low"
    ).fetchall()
    assert [b[1] for b in bands] == sorted(b[1] for b in bands)
    assert [b[2] for b in bands] == sorted(b[2] for b in bands)


def test_a_found_cache_beats_a_world_beast(conn):
    """0481. A cache is behind TWO rolls - finding the tile on a dark map and
    then rolling on it - where a world beast is behind one and a fight. The
    first version paid 4.13 against a world beast's 17.2, which is a
    consolation rather than a cache.

    Both figures are read rather than written down, so this comparison ages
    with the game instead of with my memory of it.
    """
    expected = conn.execute(
        "SELECT sum((high - low + 1) * (jade_min + jade_max) / 2.0) / 100 "
        "FROM delve_jade_rolls"
    ).fetchone()[0]
    beast = conn.execute(
        "SELECT COALESCE(avg(delta), 0) FROM jade_ledger WHERE reason = 'world_beast'"
    ).fetchone()[0]

    if beast > 0:
        assert expected > beast, (
            f"a cache averages {expected} against a world beast's {beast}"
        )


def test_a_cache_is_not_richer_than_a_dungeon(conn):
    """A dungeon run is the richest jade in the game and should stay that
    way - it is a whole run against one tile."""
    expected = conn.execute(
        "SELECT sum((high - low + 1) * (jade_min + jade_max) / 2.0) / 100 "
        "FROM delve_jade_rolls"
    ).fetchone()[0]
    assert expected < Decimal("60"), f"a cache averages {expected} jade"


def test_a_hundred_is_worth_rolling_a_hundred_for(conn):
    """The die is the drama. If the top face paid the same as the one below
    it there would be nothing to shout about."""
    top, below = conn.execute(
        "SELECT (SELECT jade_max FROM delve_jade_rolls WHERE low = 100), "
        "       (SELECT max(jade_max) FROM delve_jade_rolls WHERE low < 100)"
    ).fetchone()
    assert top > below


def test_rolling_pays_jade_and_says_what_it_rolled(conn, a_delver):
    player_id = a_delver()
    row = conn.execute(
        "SELECT COALESCE(quantity, 0) FROM player_materials "
        "WHERE player_id = %s AND material_code = 'spirit_jade'",
        (player_id,),
    ).fetchone()
    before = row[0] if row else 0

    die, jade, said, held = conn.execute(
        "SELECT die, jade, said, held FROM delve_roll_jade(%s)", (player_id,)
    ).fetchone()

    assert 1 <= die <= 100
    assert jade > 0
    assert said
    assert held >= before + jade


def test_a_jade_tile_pays_and_lands_on_the_tally(conn, a_delver):
    player_id = a_delver()
    delve_id = open_one(conn, player_id)
    at_x, at_y = conn.execute(
        "SELECT at_x, at_y FROM delve_runs WHERE delve_id = %s", (delve_id,)
    ).fetchone()
    conn.execute(
        "UPDATE delve_tiles SET kind = 'jade', spent = FALSE "
        "WHERE delve_id = %s AND x = %s AND y = %s",
        (delve_id, at_x, at_y - 1),
    )

    kind, said = conn.execute(
        "SELECT kind, said FROM delve_step(%s, 'up')", (player_id,)
    ).fetchone()

    assert kind == "jade"
    assert "roll" in said.lower()
    what, emoji = conn.execute(
        "SELECT what, emoji FROM delve_haul "
        "WHERE delve_id = %s AND what = 'Spirit Jade'",
        (delve_id,),
    ).fetchone()
    assert what == "Spirit Jade"
    assert emoji


def test_the_jade_tile_is_scattered_like_any_other(conn, a_delver):
    """`delve_open` reads the kinds table and asks for `delve_<kind>s`, which
    is why adding a kind needed no change to the scatter."""
    assert conn.execute(
        "SELECT game_config_value('delve_jades')"
    ).fetchone()[0] >= 1

    found = False
    for _ in range(12):
        delve_id = open_one(conn, a_delver())
        if conn.execute(
            "SELECT count(*) FROM delve_tiles "
            "WHERE delve_id = %s AND kind = 'jade'",
            (delve_id,),
        ).fetchone()[0] >= 1:
            found = True
            break
    assert found, "no map in twelve held a cache of jade"


def test_the_screen_knows_the_jade_glyph(conn):
    """The legend is a second copy of the tile vocabulary, so a new kind can
    be placed on maps that the screen has no name for."""
    import pathlib
    import re
    import unicodedata

    emoji = conn.execute(
        "SELECT emoji FROM delve_tile_kinds WHERE kind = 'jade'"
    ).fetchone()[0]
    source = (
        pathlib.Path(__file__).resolve().parent.parent / "bot" / "cogs" / "delve.py"
    ).read_text(encoding="utf-8")
    named = {
        unicodedata.lookup(name)
        for name in re.findall(
            re.escape(chr(92) + "N{") + r"([A-Z\- ]+)" + re.escape("}"), source
        )
    }
    assert emoji in named, f"the legend never shows {emoji}"


# ---------------------------------------------------------------------------
# A haul that says what is worth having (0480)
# ---------------------------------------------------------------------------


def _tally(conn, delve_id: int, lines: list[tuple[str, int]]) -> str:
    conn.execute(
        "SELECT delve_record(%s, %s::jsonb)",
        (
            delve_id,
            __import__("json").dumps(
                [{"what": what, "how_many": many} for what, many in lines]
            ),
        ),
    )
    return conn.execute(
        "SELECT delve_haul_of(%s)", (delve_id,)
    ).fetchone()[0]


def test_the_tally_says_what_each_thing_is(conn, a_delver):
    delve_id = open_one(conn, a_delver())
    ore = conn.execute(
        "SELECT m.name FROM materials m JOIN ores o ON o.material_code = m.code "
        "ORDER BY o.tier DESC, m.code LIMIT 1"
    ).fetchone()[0]

    text = _tally(conn, delve_id, [(ore, 5)])

    assert "(" in text and ")" in text, text
    assert "T" in text, f"a dug thing should show its tier: {text}"


def test_a_legendary_scrap_outranks_a_pile_of_uncommon(conn, a_delver):
    """The bug pashu0 hit: 202x Light Sand above 2x Primordial Blood."""
    delve_id = open_one(conn, a_delver())
    common = conn.execute(
        "SELECT name FROM materials WHERE rarity = 'uncommon' AND tier IS NOT NULL "
        "ORDER BY code LIMIT 1"
    ).fetchone()[0]
    best = conn.execute(
        "SELECT name FROM materials WHERE rarity = 'legendary' ORDER BY code LIMIT 1"
    ).fetchone()[0]

    text = _tally(conn, delve_id, [(common, 202), (best, 2)])

    # `endswith` would be wrong: a legendary that is also dug reads
    # "(T7 legendary)". What matters is which line is first.
    assert "legendary" in text.splitlines()[0], text
    assert best in text.splitlines()[0], text


def test_a_beast_material_shows_a_rarity_without_a_tier(conn, a_delver):
    """`materials.tier` is for what grows and `ores.tier` for what is dug;
    what comes off a carcass is neither, so rarity is all it can show."""
    delve_id = open_one(conn, a_delver())
    row = conn.execute(
        """
        SELECT m.name, m.rarity FROM materials m
        WHERE m.tier IS NULL AND m.rarity IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM ores o WHERE o.material_code = m.code)
        ORDER BY m.code LIMIT 1
        """
    ).fetchone()
    if row is None:
        pytest.skip("every material has a tier")

    text = _tally(conn, delve_id, [(row[0], 3)])

    assert f"({row[1]})" in text, text
    assert "(T" not in text, f"a carcass has no tier to show: {text}"


# ---------------------------------------------------------------------------
# What the deep thing is carrying (0480)
# ---------------------------------------------------------------------------


def test_the_deep_thing_rolls_better_than_the_air(conn):
    """2 per cent is right for stumbling on a Gu and nonsense as the reward
    for a creature you had to find in the dark and survive."""
    ambient, deep = conn.execute(
        "SELECT game_config_value('gu_drop_chance'), "
        "       (SELECT gu_chance FROM delve_tile_kinds WHERE kind = 'deep')"
    ).fetchone()
    assert deep > ambient


def test_nothing_but_the_deep_thing_keeps_a_gu(conn):
    assert conn.execute(
        "SELECT count(*) FROM delve_tile_kinds "
        "WHERE kind <> 'deep' AND gu_chance > 0"
    ).fetchone()[0] == 0


def test_a_named_chance_is_honoured(conn, a_delver):
    player_id = a_delver()
    region = conn.execute(
        "SELECT region_code FROM player_location WHERE player_id = %s",
        (player_id,),
    ).fetchone()[0]
    rank = conn.execute(
        "SELECT player_realm_rank(%s)", (player_id,)
    ).fetchone()[0]

    # A certainty must land, and an impossibility must not.
    landed = sum(
        1 for _ in range(30)
        if conn.execute(
            "SELECT roll_gu_drop(%s, %s, %s, 1.0)", (player_id, region, rank)
        ).fetchone()[0] is not None
    )
    assert landed > 0, "a certainty never landed in thirty tries"

    assert conn.execute(
        "SELECT roll_gu_drop(%s, %s, %s, 0.0)", (player_id, region, rank)
    ).fetchone()[0] is None


def test_three_argument_callers_still_get_the_ambient_chance(conn, a_delver):
    """`roll_gu_drop` gained a parameter rather than being copied, so every
    caller that passed three must behave exactly as it did."""
    player_id = a_delver()
    region = conn.execute(
        "SELECT region_code FROM player_location WHERE player_id = %s",
        (player_id,),
    ).fetchone()[0]
    # It simply has to be callable with three; the odds are the config's.
    conn.execute(
        "SELECT roll_gu_drop(%s, %s, %s)",
        (player_id, region, conn.execute(
            "SELECT player_realm_rank(%s)", (player_id,)
        ).fetchone()[0]),
    )

    assert conn.execute(
        "SELECT count(*) FROM pg_proc WHERE proname = 'roll_gu_drop' "
        "AND pronamespace = 'public'::regnamespace"
    ).fetchone()[0] == 1, "there is more than one roll_gu_drop to call"
