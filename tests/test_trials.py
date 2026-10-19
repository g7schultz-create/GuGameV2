"""Peer Trials: the party, the map it walks, and the fight on it.

The thing these tests mostly guard is the SCOPE. 0452 gave the Trial a room of
its own and handed that room's name to machinery written when a dungeon was
the only room there was, and three separate places had a list of rooms in them
that nobody updated. Two of those were latent crashes that no amount of playing
an all-attacker party would ever have found.
"""

from decimal import Decimal

import psycopg
import pytest


# ---------------------------------------------------------------------------
# A party of peers, built the long way so each test can bend one piece of it
# ---------------------------------------------------------------------------


@pytest.fixture
def make_peer(conn, make_player, make_technique):
    """A cultivator with a realm, a body and something to throw."""

    def _make(name: str, rank: int = 4, *, strength: int = 1000,
              max_hp: int = 10_000, technique_id: int | None = None) -> int:
        player_id = make_player(name)
        realm_id = conn.execute(
            "SELECT realm_id FROM realms WHERE rank = %s", (rank,)
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
            VALUES (%s, %s, %s, %s, %s)
            ON CONFLICT (player_id) DO UPDATE
            SET max_hp = EXCLUDED.max_hp, current_hp = EXCLUDED.current_hp,
                strength = EXCLUDED.strength, defense = EXCLUDED.defense
            """,
            (player_id, max_hp, max_hp, strength, strength // 4),
        )
        if technique_id is None:
            technique_id = make_technique(f"trial_move_{player_id}",
                                          name="Test Strike")
        conn.execute(
            "INSERT INTO player_techniques (player_id, technique_id) "
            "VALUES (%s, %s) ON CONFLICT DO NOTHING",
            (player_id, technique_id),
        )
        return player_id

    return _make


@pytest.fixture
def sealed_party(conn, make_peer):
    """Three peers of one realm, sealed and ready to walk in."""

    def _make(rank: int = 4, size: int = 3) -> tuple[int, list[int]]:
        peers = [make_peer(f"Peer{i}", rank) for i in range(size)]
        party_id = conn.execute(
            "SELECT trial_party_open(%s)", (peers[0],)
        ).fetchone()[0]
        for other in peers[1:]:
            conn.execute("SELECT trial_party_invite(%s, %s)", (peers[0], other))
            conn.execute(
                "SELECT trial_party_answer(%s, %s, TRUE)", (other, party_id)
            )
        conn.execute("SELECT trial_party_seal(%s)", (peers[0],))
        return party_id, peers

    return _make


# ---------------------------------------------------------------------------
# The scope. Every one of these would have thrown in a live fight.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "scope", ["battle", "dungeon", "boss", "horde", "gauntlet",
              "trial", "rehearsal"]
)
def test_every_room_that_swings_may_write_an_effect(conn, make_player, scope):
    """A scope the table refuses is a round that throws, not a dud technique.

    `trial` and `rehearsal` were both missing until 0456, and both are reached
    by `player_swing`, so either one would have killed a fight mid-round the
    first time somebody threw something that applies.
    """
    player_id = make_player("Caster")
    conn.execute(
        """
        INSERT INTO battle_effects
            (scope, scope_id, player_id, effect_code, magnitude, turns_left)
        VALUES (%s, -1, %s, 'regen', 0.1, 1)
        """,
        (scope, player_id),
    )


def test_a_rally_in_a_trial_reaches_the_whole_party(conn, sealed_party,
                                                    make_technique):
    """`target: party` must mean the party, in whichever room it is shouted.

    Before 0456 `technique_cast_effects` named `dungeon` and nothing else, so a
    Trial fell down the self path: the caster was healed, the round reported
    the threat covered, and the other peers got nothing.
    """
    party_id, peers = sealed_party()
    rally = make_technique(
        "trial_rally_test", name="Test Rally", category="support",
    )
    conn.execute(
        "UPDATE techniques SET effects = %s WHERE technique_id = %s",
        ('{"apply": [{"code": "regen", "turns": 2, "target": "party",'
         ' "magnitude": 0.10}]}', rally),
    )
    run_id = conn.execute(
        "SELECT run_id FROM trial_begin(%s)", (peers[0],)
    ).fetchone()[0]

    conn.execute(
        "SELECT technique_cast_effects(%s, %s, 'trial', %s)",
        (peers[0], rally, run_id),
    )

    reached = conn.execute(
        "SELECT count(DISTINCT player_id) FROM battle_effects "
        "WHERE scope = 'trial' AND scope_id = %s AND effect_code = 'regen'",
        (run_id,),
    ).fetchone()[0]
    assert reached == len(peers)


def test_the_dungeon_still_gathers_its_own_room(conn):
    """The patch added an arm; it must not have replaced one."""
    source = conn.execute(
        "SELECT prosrc FROM pg_proc WHERE proname = 'technique_cast_effects' "
        "AND pronamespace = 'public'::regnamespace"
    ).fetchone()[0]
    assert "dungeon_raiders" in source
    assert "trial_raiders" in source


# ---------------------------------------------------------------------------
# Sizing
# ---------------------------------------------------------------------------


def test_a_rehearsal_leaves_nothing_behind(conn, sealed_party):
    """It runs the real swing, so it writes what the real swing writes.

    All of which must be rolled back, or sizing a Trial would slowly fill
    `battle_effects` with the ghosts of fights that never happened.
    """
    party_id, peers = sealed_party()
    species_id = conn.execute(
        "SELECT species_id FROM dungeons WHERE realm_rank = "
        "(SELECT realm_rank FROM trial_parties WHERE party_id = %s) LIMIT 1",
        (party_id,),
    ).fetchone()[0]

    before = conn.execute("SELECT count(*) FROM battle_effects").fetchone()[0]
    conn.execute("SELECT trial_rehearse(%s, %s)", (party_id, species_id))
    after = conn.execute("SELECT count(*) FROM battle_effects").fetchone()[0]

    assert after == before


def test_the_creature_is_sized_against_what_the_party_does(conn, sealed_party):
    """The pool is the rehearsal times the rounds wanted, not a ratio.

    0453 fitted twenty damage per point of sinew to one party and was wrong by
    nearly double on the next one, because crit_damage rather than sinew
    governs what a party puts out.
    """
    party_id, peers = sealed_party()
    species_id = conn.execute(
        "SELECT species_id FROM dungeons WHERE realm_rank = "
        "(SELECT realm_rank FROM trial_parties WHERE party_id = %s) LIMIT 1",
        (party_id,),
    ).fetchone()[0]

    a_round = conn.execute(
        "SELECT trial_rehearse(%s, %s)", (party_id, species_id)
    ).fetchone()[0]
    pool = conn.execute(
        "SELECT trial_boss_hp(%s, %s)", (party_id, species_id)
    ).fetchone()[0]

    # The floor can lift it, but it can never be worth less than a few rounds.
    assert pool >= a_round * 3


def test_a_scaled_creature_is_a_smaller_creature(conn, sealed_party):
    """One fight, three sizes: a beast, the Trial, a warden."""
    party_id, peers = sealed_party()
    species_id = conn.execute(
        "SELECT species_id FROM dungeons WHERE realm_rank = "
        "(SELECT realm_rank FROM trial_parties WHERE party_id = %s) LIMIT 1",
        (party_id,),
    ).fetchone()[0]

    beast, trial, warden = (
        conn.execute(
            "SELECT trial_boss_hp(%s, %s, %s)", (party_id, species_id, scale)
        ).fetchone()[0]
        for scale in ("0.35", "1.0", "1.9")
    )
    assert beast < trial < warden


def test_only_one_trial_boss_hp_remains(conn):
    """0454 replaced the two-argument form rather than shadowing it."""
    how_many = conn.execute(
        "SELECT count(*) FROM pg_proc WHERE proname = 'trial_boss_hp' "
        "AND pronamespace = 'public'::regnamespace"
    ).fetchone()[0]
    assert how_many == 1


# ---------------------------------------------------------------------------
# The map
# ---------------------------------------------------------------------------


def test_a_map_is_whole_and_has_one_way_out(conn, sealed_party):
    party_id, peers = sealed_party()
    map_id = conn.execute(
        "SELECT trial_map_open(%s)", (peers[0],)
    ).fetchone()[0]

    width, height = conn.execute(
        "SELECT width, height FROM trial_maps WHERE map_id = %s", (map_id,)
    ).fetchone()
    tiles = conn.execute(
        "SELECT count(*) FROM trial_map_tiles WHERE map_id = %s", (map_id,)
    ).fetchone()[0]
    gates = conn.execute(
        "SELECT count(*) FROM trial_map_tiles WHERE map_id = %s AND kind = 'gate'",
        (map_id,),
    ).fetchone()[0]

    assert tiles == width * height
    assert gates == 1


def test_the_party_cannot_walk_off_the_map(conn, sealed_party):
    """And a refused move must not quietly eat a step."""
    party_id, peers = sealed_party()
    map_id = conn.execute("SELECT trial_map_open(%s)", (peers[0],)).fetchone()[0]
    before = conn.execute(
        "SELECT steps_left FROM trial_maps WHERE map_id = %s", (map_id,)
    ).fetchone()[0]

    moved, steps = conn.execute(
        "SELECT moved, steps_left FROM trial_map_move(%s, 'down')", (peers[0],)
    ).fetchone()

    assert moved is False
    assert steps == before


def test_a_peer_without_the_turn_cannot_walk_the_party(conn, sealed_party):
    """Was `test_only_the_leader_chooses_the_way` until 0463 passed the right
    to step around the party. The rule it guards is narrower now - not the
    leader, but whoever currently holds the way."""
    party_id, peers = sealed_party()
    map_id = conn.execute(
        "SELECT trial_map_open(%s)", (peers[0],)
    ).fetchone()[0]
    whose = conn.execute(
        "SELECT trial_map_mover(%s)", (map_id,)
    ).fetchone()[0]
    waiting = next(p for p in peers if p != whose)
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute("SELECT * FROM trial_map_move(%s, 'up')", (waiting,))


def test_the_budget_is_short_of_the_whole_map(conn):
    """If a party can sweep every tile, nothing on the map is a choice."""
    steps, width, height = conn.execute(
        "SELECT game_config_value('trial_map_steps'), "
        "       game_config_value('trial_map_width'), "
        "       game_config_value('trial_map_height')"
    ).fetchone()
    assert steps < width * height


def test_a_warden_never_blocks_the_only_straight_line(conn, sealed_party):
    """It is optional, which is the only reason it is allowed to be that big."""
    party_id, peers = sealed_party()
    map_id = conn.execute("SELECT trial_map_open(%s)", (peers[0],)).fetchone()[0]
    in_the_way = conn.execute(
        """
        SELECT count(*) FROM trial_map_tiles t
        JOIN trial_maps m ON m.map_id = t.map_id
        WHERE t.map_id = %s AND t.kind = 'warden' AND t.x = m.at_x
        """,
        (map_id,),
    ).fetchone()[0]
    assert in_the_way == 0


def test_a_cache_mends_the_party_and_is_spent(conn, sealed_party):
    party_id, peers = sealed_party()
    map_id = conn.execute("SELECT trial_map_open(%s)", (peers[0],)).fetchone()[0]

    # Put a cache where the party is about to step, and hurt everybody first.
    at_x, at_y = conn.execute(
        "SELECT at_x, at_y FROM trial_maps WHERE map_id = %s", (map_id,)
    ).fetchone()
    conn.execute(
        "UPDATE trial_map_tiles SET kind = 'cache', spent = FALSE "
        "WHERE map_id = %s AND x = %s AND y = %s",
        (map_id, at_x, at_y - 1),
    )
    conn.execute(
        "UPDATE trial_map_bodies SET current_hp = 1 WHERE map_id = %s", (map_id,)
    )

    kind = conn.execute(
        "SELECT kind FROM trial_map_move(%s, 'up')", (peers[0],)
    ).fetchone()[0]

    assert kind == "cache"
    assert conn.execute(
        "SELECT bool_and(current_hp > 1) FROM trial_map_bodies WHERE map_id = %s",
        (map_id,),
    ).fetchone()[0]
    assert conn.execute(
        "SELECT spent FROM trial_map_tiles WHERE map_id = %s AND x = %s AND y = %s",
        (map_id, at_x, at_y - 1),
    ).fetchone()[0]


def test_a_beast_opens_a_smaller_fight_than_the_gate(conn, sealed_party):
    """One fight in this game, scaled - not a second fight engine."""
    party_id, peers = sealed_party()
    map_id = conn.execute("SELECT trial_map_open(%s)", (peers[0],)).fetchone()[0]
    at_x, at_y = conn.execute(
        "SELECT at_x, at_y FROM trial_maps WHERE map_id = %s", (map_id,)
    ).fetchone()
    conn.execute(
        "UPDATE trial_map_tiles SET kind = 'beast', spent = FALSE "
        "WHERE map_id = %s AND x = %s AND y = %s",
        (map_id, at_x, at_y - 1),
    )

    run_id = conn.execute(
        "SELECT run_id FROM trial_map_move(%s, 'up')", (peers[0],)
    ).fetchone()[0]
    assert run_id is not None

    tile_kind, pool = conn.execute(
        "SELECT tile_kind, boss_max_hp FROM trial_runs WHERE run_id = %s",
        (run_id,),
    ).fetchone()
    unscaled = conn.execute(
        "SELECT trial_boss_hp(%s, (SELECT species_id FROM trial_runs "
        "WHERE run_id = %s))", (party_id, run_id)
    ).fetchone()[0]

    assert tile_kind == "beast"
    assert pool < unscaled
    assert conn.execute(
        "SELECT status FROM trial_maps WHERE map_id = %s", (map_id,)
    ).fetchone()[0] == "fighting"


def test_the_party_walks_in_at_the_body_it_is_carrying(conn, sealed_party):
    """Health across the map is the only thing that makes the route matter."""
    party_id, peers = sealed_party()
    map_id = conn.execute("SELECT trial_map_open(%s)", (peers[0],)).fetchone()[0]
    at_x, at_y = conn.execute(
        "SELECT at_x, at_y FROM trial_maps WHERE map_id = %s", (map_id,)
    ).fetchone()
    conn.execute(
        "UPDATE trial_map_tiles SET kind = 'beast', spent = FALSE "
        "WHERE map_id = %s AND x = %s AND y = %s",
        (map_id, at_x, at_y - 1),
    )
    conn.execute(
        "UPDATE trial_map_bodies SET current_hp = 7 WHERE map_id = %s", (map_id,)
    )

    run_id = conn.execute(
        "SELECT run_id FROM trial_map_move(%s, 'up')", (peers[0],)
    ).fetchone()[0]

    assert conn.execute(
        "SELECT bool_and(current_hp = 7) FROM trial_raiders WHERE run_id = %s",
        (run_id,),
    ).fetchone()[0]


def test_losing_a_tile_ends_the_map(conn, sealed_party):
    """There is no second attempt at a tile that already beat you."""
    party_id, peers = sealed_party()
    map_id = conn.execute("SELECT trial_map_open(%s)", (peers[0],)).fetchone()[0]
    at_x, at_y = conn.execute(
        "SELECT at_x, at_y FROM trial_maps WHERE map_id = %s", (map_id,)
    ).fetchone()
    conn.execute(
        "UPDATE trial_map_tiles SET kind = 'beast', spent = FALSE "
        "WHERE map_id = %s AND x = %s AND y = %s",
        (map_id, at_x, at_y - 1),
    )
    run_id = conn.execute(
        "SELECT run_id FROM trial_map_move(%s, 'up')", (peers[0],)
    ).fetchone()[0]

    conn.execute(
        "UPDATE trial_runs SET status = 'done', outcome = 'wiped', "
        "ended_at = now(), coming = NULL WHERE run_id = %s",
        (run_id,),
    )
    conn.execute("SELECT * FROM trial_map_settle(%s)", (map_id,))

    status, outcome = conn.execute(
        "SELECT status, outcome FROM trial_maps WHERE map_id = %s", (map_id,)
    ).fetchone()
    assert (status, outcome) == ("done", "wiped")


def test_clearing_the_gate_ends_the_map_as_a_win(conn, sealed_party):
    party_id, peers = sealed_party()
    map_id = conn.execute("SELECT trial_map_open(%s)", (peers[0],)).fetchone()[0]
    at_x, at_y = conn.execute(
        "SELECT at_x, at_y FROM trial_maps WHERE map_id = %s", (map_id,)
    ).fetchone()
    conn.execute(
        "UPDATE trial_map_tiles SET kind = 'gate', spent = FALSE "
        "WHERE map_id = %s AND x = %s AND y = %s",
        (map_id, at_x, at_y - 1),
    )
    run_id = conn.execute(
        "SELECT run_id FROM trial_map_move(%s, 'up')", (peers[0],)
    ).fetchone()[0]

    conn.execute(
        "UPDATE trial_runs SET status = 'done', outcome = 'cleared', "
        "ended_at = now(), coming = NULL WHERE run_id = %s",
        (run_id,),
    )
    conn.execute("SELECT * FROM trial_map_settle(%s)", (map_id,))

    assert conn.execute(
        "SELECT outcome FROM trial_maps WHERE map_id = %s", (map_id,)
    ).fetchone()[0] == "cleared"


def test_running_out_of_light_strands_the_party(conn, sealed_party):
    """A party that loots too long goes home without the Trial."""
    party_id, peers = sealed_party()
    map_id = conn.execute("SELECT trial_map_open(%s)", (peers[0],)).fetchone()[0]
    conn.execute(
        "UPDATE trial_maps SET steps_left = 1 WHERE map_id = %s", (map_id,)
    )
    at_x, at_y = conn.execute(
        "SELECT at_x, at_y FROM trial_maps WHERE map_id = %s", (map_id,)
    ).fetchone()
    conn.execute(
        "UPDATE trial_map_tiles SET kind = 'way' "
        "WHERE map_id = %s AND x = %s AND y = %s",
        (map_id, at_x, at_y - 1),
    )

    conn.execute("SELECT * FROM trial_map_move(%s, 'up')", (peers[0],))

    status, outcome = conn.execute(
        "SELECT status, outcome FROM trial_maps WHERE map_id = %s", (map_id,)
    ).fetchone()
    assert (status, outcome) == ("done", "stranded")


def test_the_caches_are_still_empty(conn):
    """Deliberate: the fight has to be worth walking into first."""
    assert conn.execute(
        "SELECT count(*) FROM trial_cache_spoils"
    ).fetchone()[0] == 0


def test_the_map_renders_a_row_per_rank(conn, sealed_party):
    party_id, peers = sealed_party()
    map_id = conn.execute("SELECT trial_map_open(%s)", (peers[0],)).fetchone()[0]
    grid, height = conn.execute(
        "SELECT trial_map_render(%s), height FROM trial_maps WHERE map_id = %s",
        (map_id, map_id),
    ).fetchone()
    assert len(grid.splitlines()) == height


# ---------------------------------------------------------------------------
# The dark (0458)
# ---------------------------------------------------------------------------


def test_a_new_map_is_dark_but_for_the_ground_underfoot(conn, sealed_party):
    party_id, peers = sealed_party()
    map_id = conn.execute("SELECT trial_map_open(%s)", (peers[0],)).fetchone()[0]

    seen = conn.execute(
        "SELECT count(*) FROM trial_map_tiles WHERE map_id = %s AND seen",
        (map_id,),
    ).fetchone()[0]
    assert seen == 1

    assert conn.execute(
        """
        SELECT t.seen FROM trial_map_tiles t
        JOIN trial_maps m ON m.map_id = t.map_id
        WHERE t.map_id = %s AND t.x = m.at_x AND t.y = m.at_y
        """,
        (map_id,),
    ).fetchone()[0]


def test_the_dark_map_names_nothing_that_is_on_it(conn, sealed_party):
    """The point of the whole change: the grid must not leak the contents."""
    party_id, peers = sealed_party()
    map_id = conn.execute("SELECT trial_map_open(%s)", (peers[0],)).fetchone()[0]
    grid = conn.execute(
        "SELECT trial_map_render(%s)", (map_id,)
    ).fetchone()[0]

    for glyph in ("\N{DIAMOND SHAPE WITH A DOT INSIDE}", "\N{FIRE}",
                  "\N{JAPANESE OGRE}", "\N{DRAGON}"):
        assert glyph not in grid, f"the dark map is showing {glyph}"

    width, height = conn.execute(
        "SELECT width, height FROM trial_maps WHERE map_id = %s", (map_id,)
    ).fetchone()
    assert grid.count("\N{BLACK LARGE SQUARE}") == width * height - 1


def test_one_step_lights_one_tile(conn, sealed_party):
    party_id, peers = sealed_party()
    map_id = conn.execute("SELECT trial_map_open(%s)", (peers[0],)).fetchone()[0]
    at_x, at_y = conn.execute(
        "SELECT at_x, at_y FROM trial_maps WHERE map_id = %s", (map_id,)
    ).fetchone()
    # Open ground, so the step cannot start a fight and end the walk.
    conn.execute(
        "UPDATE trial_map_tiles SET kind = 'way' "
        "WHERE map_id = %s AND x = %s AND y = %s",
        (map_id, at_x, at_y - 1),
    )

    conn.execute("SELECT * FROM trial_map_move(%s, 'up')", (peers[0],))

    assert conn.execute(
        "SELECT count(*) FROM trial_map_tiles WHERE map_id = %s AND seen",
        (map_id,),
    ).fetchone()[0] == 2


def test_a_refused_step_lights_nothing(conn, sealed_party):
    """Walking into the edge must not reveal what is past it."""
    party_id, peers = sealed_party()
    map_id = conn.execute("SELECT trial_map_open(%s)", (peers[0],)).fetchone()[0]

    conn.execute("SELECT * FROM trial_map_move(%s, 'down')", (peers[0],))

    assert conn.execute(
        "SELECT count(*) FROM trial_map_tiles WHERE map_id = %s AND seen",
        (map_id,),
    ).fetchone()[0] == 1


def test_the_trail_survives_being_walked_off(conn, sealed_party):
    """A lit tile stays lit. The trail is the only thing the grid is for."""
    party_id, peers = sealed_party()
    map_id = conn.execute("SELECT trial_map_open(%s)", (peers[0],)).fetchone()[0]
    at_x, at_y = conn.execute(
        "SELECT at_x, at_y FROM trial_maps WHERE map_id = %s", (map_id,)
    ).fetchone()
    for x, y in ((at_x, at_y - 1), (at_x, at_y)):
        conn.execute(
            "UPDATE trial_map_tiles SET kind = 'way' "
            "WHERE map_id = %s AND x = %s AND y = %s",
            (map_id, x, y),
        )

    # Since 0463 the way goes round, so each step is taken by whoever holds
    # it rather than by the leader twice.
    for direction in ("up", "down"):
        whose = conn.execute(
            "SELECT trial_map_mover(%s)", (map_id,)
        ).fetchone()[0]
        conn.execute(
            "SELECT * FROM trial_map_move(%s, %s)", (whose, direction)
        )

    grid = conn.execute("SELECT trial_map_render(%s)", (map_id,)).fetchone()[0]
    # Where the party stood a moment ago is open ground it can still see.
    assert "\N{LARGE BLUE SQUARE}" in grid


def test_the_screen_names_the_glyphs_the_map_draws(conn, sealed_party):
    """One definition, not two.

    The legend on the walking screen is a second copy of the tile vocabulary,
    written in Python against a table of emoji written in SQL. If somebody
    changes the cache glyph in `trial_map_kinds` and not in the cog, the
    screen starts explaining a symbol that is no longer on the map.
    """
    import pathlib
    import re
    import unicodedata

    source = pathlib.Path("bot/cogs/trial.py").read_text(encoding="utf-8")
    legend = source[source.index('name="What is out there"'):]
    legend = legend[:legend.index("inline=False")]
    named = {
        unicodedata.lookup(name)
        for name in re.findall(
            re.escape(chr(92) + "N{") + r"([A-Z ]+)" + re.escape("}"),
            legend,
        )
    }

    drawn = {
        row[0] for row in conn.execute(
            "SELECT emoji FROM trial_map_kinds"
        ).fetchall()
    }

    missing = drawn - named
    assert not missing, f"the map draws {missing} and the screen never says so"


# ---------------------------------------------------------------------------
# The role kit (0459)
#
# The Trial asks the party to pull, harden or mend. Until 0459 the earliest
# pull in the game sat at rank 5 and wanted Master attainment, so a party below
# realm 5 could not answer `fixes_on_one` by any route at any price - and that
# is the threat that takes 55% off the weakest raider.
# ---------------------------------------------------------------------------


ANSWER_EFFECTS = {
    "pull": ("taunt",),
    "mend": ("regen",),
    "harden": ("defence_up", "block_up"),
}


@pytest.mark.parametrize("rank", range(1, 10))
@pytest.mark.parametrize("answer", sorted(ANSWER_EFFECTS))
def test_every_realm_can_reach_every_answer(conn, rank, answer):
    """No rank may be without a basic technique for any of the three answers.

    This is the whole content of 0459, and it is parametrised rather than
    written as one query so a regression names the rank and the answer that
    broke rather than just failing.
    """
    found = conn.execute(
        """
        SELECT count(DISTINCT t.technique_id)
        FROM techniques t
        CROSS JOIN LATERAL jsonb_array_elements(
            COALESCE(t.effects -> 'apply', '[]'::jsonb)) e
        WHERE t.created_by IS NULL
          AND t.grade = 'basic'
          AND t.rank <= %s
          AND e ->> 'code' = ANY (%s)
        """,
        (rank, list(ANSWER_EFFECTS[answer])),
    ).fetchone()[0]
    assert found > 0, f"realm {rank} cannot learn a {answer}"


@pytest.mark.parametrize("answer", sorted(ANSWER_EFFECTS))
def test_the_lowest_rung_of_each_answer_asks_for_no_attainment(conn, answer):
    """A rank 1 technique needs tier 0, which is no specialisation at all.

    That is what makes the kit reachable by somebody who has not committed to
    a path yet, which is most of the people a Trial will ask to cover a threat.
    """
    lowest = conn.execute(
        """
        SELECT min(t.rank)
        FROM techniques t
        CROSS JOIN LATERAL jsonb_array_elements(
            COALESCE(t.effects -> 'apply', '[]'::jsonb)) e
        WHERE t.created_by IS NULL AND t.grade = 'basic'
          AND e ->> 'code' = ANY (%s)
        """,
        (list(ANSWER_EFFECTS[answer]),),
    ).fetchone()[0]
    assert lowest == 1


def test_the_new_kit_walks_paths_people_actually_hold(conn):
    """A technique in a path nobody walks is unreachable however cheap it is.

    The nine seeded in 0459 went into the paths the live roster actually holds
    attainment in; this guards the weaker property that each of them walks some
    path at all, since a technique with no path row never reaches a shelf.
    """
    orphans = conn.execute(
        """
        SELECT t.code FROM techniques t
        WHERE t.code IN ('step_into_the_gap', 'bared_edge', 'the_struck_bell',
                         'first_to_draw_the_sky', 'heaven_marks_the_standing',
                         'even_breath', 'hands_that_knit', 'a_moment_returned',
                         'rime_guard')
          AND NOT EXISTS (SELECT 1 FROM technique_paths tp
                          WHERE tp.technique_id = t.technique_id)
        """
    ).fetchall()
    assert orphans == []


def test_a_pull_holds_more_attention_the_higher_it_goes(conn):
    """A dungeon weights its target by taunt magnitude, so the rungs must rise.

    `dungeon_resolve_round` picks with `-ln(random()) / (1 + taunt)`. A Trial
    only asks whether a pull was applied, so without this the rank 1 pull would
    be strictly as good as the rank 6 one everywhere it mattered.
    """
    rungs = conn.execute(
        """
        SELECT t.rank, (e ->> 'magnitude')::numeric
        FROM techniques t
        CROSS JOIN LATERAL jsonb_array_elements(
            COALESCE(t.effects -> 'apply', '[]'::jsonb)) e
        WHERE t.code IN ('step_into_the_gap', 'bared_edge', 'the_struck_bell',
                         'first_to_draw_the_sky', 'heaven_marks_the_standing')
          AND e ->> 'code' = 'taunt'
        ORDER BY t.rank
        """
    ).fetchall()
    assert len(rungs) == 5
    magnitudes = [m for _, m in rungs]
    assert magnitudes == sorted(magnitudes)
    assert len(set(magnitudes)) == len(magnitudes)


def test_a_party_that_brings_a_pull_answers_the_worst_threat(conn,
                                                             sealed_party,
                                                             make_peer):
    """End to end: the cheapest pull in the game covers `fixes_on_one`.

    The point of the whole kit. If this fails, somebody owns a taunt and the
    round still says nobody pulled.
    """
    party_id, peers = sealed_party()
    pull = conn.execute(
        "SELECT technique_id FROM techniques WHERE code = 'step_into_the_gap'"
    ).fetchone()[0]
    conn.execute(
        "INSERT INTO player_techniques (player_id, technique_id) "
        "VALUES (%s, %s) ON CONFLICT DO NOTHING",
        (peers[0], pull),
    )

    run_id = conn.execute(
        "SELECT run_id FROM trial_begin(%s)", (peers[0],)
    ).fetchone()[0]
    # Force the threat that has never been answered in this game.
    conn.execute(
        "UPDATE trial_runs SET coming = 'fixes_on_one' WHERE run_id = %s",
        (run_id,),
    )
    conn.execute("SELECT trial_choose(%s, %s)", (peers[0], pull))

    answered, threat = conn.execute(
        "SELECT answered, threat FROM trial_resolve_round(%s)", (run_id,)
    ).fetchone()

    assert threat == "fixes_on_one"
    assert answered is True


# ---------------------------------------------------------------------------
# Finding the kit (0460)
# ---------------------------------------------------------------------------


def test_technique_trial_answers_names_what_a_technique_covers(conn):
    for code, answer in (
        ("step_into_the_gap", "pull"),
        ("even_breath", "mend"),
        ("rime_guard", "harden"),
    ):
        answers = conn.execute(
            "SELECT technique_trial_answers(technique_id) "
            "FROM techniques WHERE code = %s",
            (code,),
        ).fetchone()[0]
        assert answer in answers, f"{code} should answer {answer}, got {answers}"


def test_a_plain_attack_answers_nothing(conn):
    """Or the shelf filter would just show the whole catalogue again."""
    miscounted = conn.execute(
        """
        SELECT count(*) FROM techniques t
        WHERE t.category = 'attack' AND NOT (t.effects ? 'apply')
          AND array_length(technique_trial_answers(t.technique_id), 1) > 0
        """
    ).fetchone()[0]
    assert miscounted == 0


def test_the_party_screen_and_the_shelf_agree_about_a_person(conn,
                                                             sealed_party):
    """Two sources, one meaning.

    `trial_party_roster` keeps its own CASE over effect codes and the shelf
    uses `technique_trial_answers`. They are allowed to be separate; they are
    not allowed to disagree about whether a given cultivator can pull.
    """
    party_id, peers = sealed_party()
    pull = conn.execute(
        "SELECT technique_id FROM techniques WHERE code = 'step_into_the_gap'"
    ).fetchone()[0]
    conn.execute(
        "INSERT INTO player_techniques (player_id, technique_id) "
        "VALUES (%s, %s) ON CONFLICT DO NOTHING",
        (peers[0], pull),
    )

    disagreements = conn.execute(
        """
        SELECT ros.discord_name
        FROM trial_party_roster(%s) ros
        CROSS JOIN LATERAL (
            SELECT COALESCE(array_agg(DISTINCT a), ARRAY[]::text[]) AS answers
            FROM player_techniques pt
            CROSS JOIN LATERAL unnest(
                technique_trial_answers(pt.technique_id)) AS u (a)
            WHERE pt.player_id = ros.player_id
        ) mine
        WHERE ros.can_pull   <> ('pull'   = ANY (mine.answers))
           OR ros.can_mend   <> ('mend'   = ANY (mine.answers))
           OR ros.can_shield <> ('harden' = ANY (mine.answers))
        """,
        (party_id,),
    ).fetchall()
    assert disagreements == []


def test_the_shelf_offers_a_way_to_find_the_kit(conn):
    """The filter exists, and the query behind it carries what it reads.

    0459 is only useful if a player can find nine rows in two hundred and
    forty. If the filter is dropped or the column stops being selected, the
    kit goes back to being unfindable without anything else failing.
    """
    import pathlib

    source = pathlib.Path("bot/cogs/techniques.py").read_text(encoding="utf-8")
    assert '"answers"' in source, "the Trial-answers filter is gone"
    assert "technique_trial_answers(s.technique_id)" in source, (
        "the shelf query no longer carries what the filter reads"
    )


def test_the_shelf_filter_keeps_only_answering_techniques(conn):
    """Exercised through the cog's own predicate, not a reimplementation."""
    from bot.cogs.techniques import SHELF_FILTERS

    keep = next(f for code, _, f in SHELF_FILTERS if code == "answers")

    assert keep({"answers": ["pull"]}) is True
    assert keep({"answers": []}) is False
    # A screen built before 0460 has no such key and must not explode.
    assert keep({}) is False


# ---------------------------------------------------------------------------
# Forging something that is not pure damage (0461, 0462)
# ---------------------------------------------------------------------------


@pytest.fixture
def forged(conn, make_peer):
    """Run one real forge to completion, with the dice held still.

    `forge_take` is the only thing that builds a technique, so the tests drive
    it rather than a reimplementation of it. What they pin is the quality - so
    effects are certainly drawn - and the stance roll, so the branch under test
    is the branch taken.
    """

    def _make(*, stance: bool, quality: str = "dao") -> dict:
        # Rank 10 is Dewberry Immortal, which is where forging begins. A
        # Dao-realm cultivator is refused before the branch under test runs.
        player_id = make_peer("Forger", 10)
        conn.execute(
            "UPDATE game_config SET value = %s WHERE key = 'enlighten_stance_chance'",
            (1.0 if stance else 0.0,),
        )
        conn.execute(
            "DELETE FROM player_cooldowns WHERE player_id = %s "
            "AND action = 'forge_technique'",
            (player_id,),
        )
        forge_id = conn.execute(
            "SELECT forge_begin(%s, NULL)", (player_id,)
        ).fetchone()[0]
        # A quality that certainly carries effects; without one there is
        # nothing for a stance to commit to and the branch is unreachable.
        conn.execute(
            "UPDATE technique_forges SET quality = %s WHERE forge_id = %s",
            (quality, forge_id),
        )

        done = False
        while not done:
            pick = conn.execute(
                "SELECT e ->> 'code' FROM jsonb_array_elements(forge_offer(%s)) e "
                "ORDER BY random() LIMIT 1",
                (forge_id,),
            ).fetchone()[0]
            done, technique_id = conn.execute(
                "SELECT done, technique_id FROM forge_take(%s, %s)",
                (forge_id, pick),
            ).fetchone()[:2]

        row = conn.execute(
            "SELECT technique_id, name, category, base_power, effects, "
            "       cooldown_turns, description "
            "FROM techniques WHERE technique_id = %s",
            (technique_id,),
        ).fetchone()
        return dict(zip(
            ("technique_id", "name", "category", "base_power", "effects",
             "cooldown_turns", "description"), row))

    return _make


def test_a_forge_can_produce_something_that_is_not_an_attack(forged):
    """The whole point of 0461. Every forged technique used to be an attack."""
    tech = forged(stance=True)
    assert tech["category"] != "attack"
    assert tech["category"] in ("support", "defense", "utility")


def test_a_stance_trades_damage_for_what_it_leaves_behind(conn, forged):
    """It keeps some damage. A technique that throws the turn away is one
    nobody picks, so the trade has to stay a trade."""
    stance = forged(stance=True)
    strike = forged(stance=False)

    assert stance["base_power"] > 0
    assert stance["base_power"] < strike["base_power"]
    assert "stance rather than a strike" in stance["description"]


def test_a_stance_never_exceeds_an_effect_cap(conn, forged):
    """Tripling - now 1.8x - is clamped by each kind's own ceiling."""
    tech = forged(stance=True)
    # Read the effects back by id rather than handing the dict psycopg just
    # decoded straight back to it as a parameter.
    over = conn.execute(
        """
        SELECT e ->> 'code', (e ->> 'magnitude')::numeric, b.cap
        FROM techniques t
        CROSS JOIN LATERAL jsonb_array_elements(t.effects -> 'apply') e
        JOIN battle_effect_kinds b ON b.code = e ->> 'code'
        WHERE t.technique_id = %s AND (e ->> 'magnitude')::numeric > b.cap
        """,
        (tech["technique_id"],),
    ).fetchall()
    assert over == []


def test_a_plain_forge_is_still_an_attack(forged):
    """0461 must not have turned the forge into a support factory."""
    tech = forged(stance=False)
    assert tech["category"] == "attack"


def test_a_forged_stance_can_answer_a_trial_threat(conn, forged):
    """The reason any of this was asked for.

    A stance built out of regen, warding or a pull has to register as an
    answer through the same function the shelf and the party screen use.
    """
    for _ in range(6):
        tech = forged(stance=True)
        answers = conn.execute(
            "SELECT technique_trial_answers(%s)", (tech["technique_id"],)
        ).fetchone()[0]
        if answers:
            assert set(answers) <= {"pull", "mend", "harden"}
            return
    pytest.fail("six dao-quality stances and not one answered a threat")


def test_a_stance_is_not_automatically_the_best_one(conn):
    """0462. The draw already reached cap x 0.65, so tripling it clamped every
    stance a competent cultivator forged to the ceiling - which made the forge
    quality and the choices in it stop mattering."""
    mult = conn.execute(
        "SELECT game_config_value('enlighten_stance_effect_multiple')"
    ).fetchone()[0]

    for code, cap in conn.execute(
        "SELECT code, cap FROM battle_effect_kinds"
    ).fetchall():
        weakest = cap * Decimal("0.25") * Decimal("1.0") * Decimal("0.7") * mult
        best = cap * Decimal("0.25") * Decimal("2.0") * Decimal("1.3") * mult
        assert weakest < cap, f"the weakest {code} stance already sits at the cap"
        assert best >= cap, f"no {code} stance can ever reach its cap"


# ---------------------------------------------------------------------------
# Taking turns with the map (0463)
#
# The leader used to be the only one who moved, which made a Trial a thing one
# person played while the others waited to pick a technique.
# ---------------------------------------------------------------------------


@pytest.fixture
def open_map(conn, sealed_party):
    """A sealed party on a map of nothing but open ground.

    Every tile is flattened so a step can never start a fight, which is what
    lets these tests count turns rather than fights.
    """

    def _make(size: int = 3):
        party_id, peers = sealed_party(size=size)
        map_id = conn.execute(
            "SELECT trial_map_open(%s)", (peers[0],)
        ).fetchone()[0]
        conn.execute(
            "UPDATE trial_map_tiles SET kind = 'way' WHERE map_id = %s",
            (map_id,),
        )
        return party_id, peers, map_id

    return _make


def mover(conn, map_id: int) -> int:
    return conn.execute(
        "SELECT trial_map_mover(%s)", (map_id,)
    ).fetchone()[0]


def test_the_leader_takes_the_first_step(conn, open_map):
    party_id, peers, map_id = open_map()
    leader = conn.execute(
        "SELECT leader_id FROM trial_parties WHERE party_id = %s", (party_id,)
    ).fetchone()[0]
    assert mover(conn, map_id) == leader


def test_nobody_may_move_out_of_turn(conn, open_map):
    party_id, peers, map_id = open_map()
    waiting = next(p for p in peers if p != mover(conn, map_id))
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute("SELECT * FROM trial_map_move(%s, 'up')", (waiting,))


def test_the_refusal_names_whose_turn_it_is(conn, open_map):
    """A refusal that does not say who to wait for is a refusal that reads as
    a bug."""
    party_id, peers, map_id = open_map()
    whose = mover(conn, map_id)
    name = conn.execute(
        "SELECT discord_name FROM players WHERE player_id = %s", (whose,)
    ).fetchone()[0]
    waiting = next(p for p in peers if p != whose)

    with pytest.raises(psycopg.errors.CheckViolation) as caught:
        conn.execute("SELECT * FROM trial_map_move(%s, 'up')", (waiting,))
    assert name in str(caught.value)


def test_the_way_goes_round_the_whole_party(conn, open_map):
    party_id, peers, map_id = open_map()
    seen = []
    for i in range(len(peers)):
        whose = mover(conn, map_id)
        seen.append(whose)
        conn.execute(
            "SELECT * FROM trial_map_move(%s, %s)",
            (whose, "up" if i % 2 == 0 else "down"),
        )

    assert sorted(seen) == sorted(peers)
    # And it comes back round rather than running off the end.
    assert mover(conn, map_id) == seen[0]


def test_bouncing_off_the_edge_does_not_pass_the_turn(conn, open_map):
    """0455 made a refused move cost no step. It must cost no turn either, or
    the way to grief a party is to walk into a wall."""
    party_id, peers, map_id = open_map()
    before = mover(conn, map_id)

    moved = conn.execute(
        "SELECT moved FROM trial_map_move(%s, 'down')", (before,)
    ).fetchone()[0]

    assert moved is False
    assert mover(conn, map_id) == before


def test_a_fallen_peer_is_skipped(conn, open_map):
    party_id, peers, map_id = open_map()
    down = mover(conn, map_id)
    conn.execute(
        "UPDATE trial_map_bodies SET current_hp = 0 "
        "WHERE map_id = %s AND player_id = %s",
        (map_id, down),
    )

    assert mover(conn, map_id) != down
    # And they stay out of it rather than coming round again next lap.
    for i in range(len(peers)):
        whose = mover(conn, map_id)
        assert whose != down
        conn.execute(
            "SELECT * FROM trial_map_move(%s, %s)",
            (whose, "up" if i % 2 == 0 else "down"),
        )


def test_a_fallen_party_still_has_somebody_to_move(conn, open_map):
    """Otherwise a wipe would refuse every move until somebody noticed, rather
    than resolving through the ordinary path."""
    party_id, peers, map_id = open_map()
    conn.execute(
        "UPDATE trial_map_bodies SET current_hp = 0 WHERE map_id = %s",
        (map_id,),
    )
    assert mover(conn, map_id) is not None


def test_the_fight_is_still_the_leaders_to_call(conn):
    """Only the map rotates. A round resolving on a rotating button would mean
    whoever happened to hold it could end the turn for everybody."""
    import pathlib

    source = pathlib.Path("bot/cogs/trial.py").read_text(encoding="utf-8")
    assert "if is_leader:\n                self.add_item(ResolveButton" in source


# ---------------------------------------------------------------------------
# Greed (0464)
# ---------------------------------------------------------------------------


@pytest.fixture
def in_a_fight(conn, sealed_party):
    """A sealed party already swinging at something."""

    def _make():
        party_id, peers = sealed_party()
        run_id = conn.execute(
            "SELECT run_id FROM trial_begin(%s)", (peers[0],)
        ).fetchone()[0]
        return party_id, peers, run_id

    return _make


def test_a_looted_round_deals_nothing(conn, in_a_fight):
    """The cost of greed is the round, which is the only thing holding it in
    check - 0454 sizes the creature off what the party deals while attacking."""
    party_id, peers, run_id = in_a_fight()
    before = conn.execute(
        "SELECT boss_hp FROM trial_runs WHERE run_id = %s", (run_id,)
    ).fetchone()[0]

    for p in peers:
        conn.execute("SELECT * FROM trial_loot(%s)", (p,))
    dealt = conn.execute(
        "SELECT dealt FROM trial_resolve_round(%s)", (run_id,)
    ).fetchone()[0]

    after = conn.execute(
        "SELECT boss_hp FROM trial_runs WHERE run_id = %s", (run_id,)
    ).fetchone()[0]
    assert dealt == 0
    assert after == before


def test_looting_actually_finds_something(conn, in_a_fight):
    party_id, peers, run_id = in_a_fight()
    before = conn.execute(
        "SELECT COALESCE(sum(quantity), 0) FROM player_materials "
        "WHERE player_id = %s",
        (peers[0],),
    ).fetchone()[0]

    conn.execute("SELECT * FROM trial_loot(%s)", (peers[0],))
    conn.execute("SELECT * FROM trial_resolve_round(%s)", (run_id,))

    after = conn.execute(
        "SELECT COALESCE(sum(quantity), 0) FROM player_materials "
        "WHERE player_id = %s",
        (peers[0],),
    ).fetchone()[0]
    assert after > before


def test_the_room_runs_out(conn, in_a_fight):
    """Without a cap a party could decline to fight, ride the round limit to
    `outlasted`, and farm the spoils of a creature it never hurt."""
    party_id, peers, run_id = in_a_fight()
    cap = conn.execute(
        "SELECT game_config_value('trial_loot_limit')::int"
    ).fetchone()[0]

    for _ in range(cap):
        conn.execute("SELECT * FROM trial_loot(%s)", (peers[0],))
        conn.execute("SELECT * FROM trial_resolve_round(%s)", (run_id,))

    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute("SELECT * FROM trial_loot(%s)", (peers[0],))


def test_choosing_a_technique_puts_the_bag_down(conn, in_a_fight):
    party_id, peers, run_id = in_a_fight()
    move = conn.execute(
        "SELECT technique_id FROM player_techniques WHERE player_id = %s LIMIT 1",
        (peers[0],),
    ).fetchone()[0]

    conn.execute("SELECT * FROM trial_loot(%s)", (peers[0],))
    conn.execute("SELECT trial_choose(%s, %s)", (peers[0], move))

    looting, intent = conn.execute(
        "SELECT looting, intent_id FROM trial_raiders "
        "WHERE run_id = %s AND player_id = %s",
        (run_id, peers[0]),
    ).fetchone()
    assert looting is False
    assert intent == move


def test_the_bag_goes_down_when_the_round_ends(conn, in_a_fight):
    party_id, peers, run_id = in_a_fight()
    conn.execute("SELECT * FROM trial_loot(%s)", (peers[0],))
    conn.execute("SELECT * FROM trial_resolve_round(%s)", (run_id,))

    assert conn.execute(
        "SELECT count(*) FROM trial_raiders WHERE run_id = %s AND looting",
        (run_id,),
    ).fetchone()[0] == 0


def test_a_raider_who_is_down_cannot_loot(conn, in_a_fight):
    party_id, peers, run_id = in_a_fight()
    conn.execute(
        "UPDATE trial_raiders SET current_hp = 0 "
        "WHERE run_id = %s AND player_id = %s",
        (run_id, peers[0]),
    )
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute("SELECT * FROM trial_loot(%s)", (peers[0],))


def test_a_raider_must_have_decided_something_to_have_decided_when(
    conn, in_a_fight
):
    """`chose_at` meant "picked a technique" until looting became a third kind
    of choice. The widened invariant still has to refuse nonsense."""
    party_id, peers, run_id = in_a_fight()
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute(
            "UPDATE trial_raiders SET intent_id = NULL, looting = FALSE, "
            "chose_at = now() WHERE run_id = %s AND player_id = %s",
            (run_id, peers[0]),
        )


def test_looting_does_not_answer_a_threat(conn, in_a_fight):
    """Greed covers nothing. A party that all loots eats the threat in full."""
    party_id, peers, run_id = in_a_fight()
    conn.execute(
        "UPDATE trial_runs SET coming = 'wide_sweep' WHERE run_id = %s",
        (run_id,),
    )
    for p in peers:
        conn.execute("SELECT * FROM trial_loot(%s)", (p,))

    answered = conn.execute(
        "SELECT answered FROM trial_resolve_round(%s)", (run_id,)
    ).fetchone()[0]
    assert answered is False


# ---------------------------------------------------------------------------
# The fight screen
# ---------------------------------------------------------------------------


def test_the_screen_says_what_answers_the_threat(conn):
    """It used to telegraph a threat and never say what covered it, which made
    the telegraph decoration unless you had the table memorised."""
    from bot.cogs.trial import COVERS

    wanted = {
        row[0] for row in conn.execute(
            "SELECT DISTINCT answers_with FROM trial_threats"
        ).fetchall()
    }
    assert wanted <= set(COVERS), f"the screen cannot explain {wanted - set(COVERS)}"


def test_the_fight_screen_stays_inside_discords_budget():
    """Row 1 now holds Loot, Go and the redraw."""
    import discord
    from bot.cogs.trial import TrialView

    view = TrialView(1, None)
    view.map = {"leader_id": 1, "status": "fighting", "mover_id": 1}
    view.run = {"answers_with": "pull", "loot_limit": 2}
    view.raiders = [{"player_id": 1, "current_hp": 10, "max_hp": 10,
                     "intent": None, "looting": False, "loots_taken": 0}]
    view.moves = [{"technique_id": 5, "name": "A", "covers": ["pull"],
                   "path_name": "Human Path", "answers": True}]
    view.build()

    rows: dict[int, int] = {}
    for item in view.children:
        rows[item.row] = rows.get(item.row, 0) + 1
    assert all(n <= 5 for n in rows.values()), rows
    assert len(view.children) <= 25


def test_what_answers_this_round_is_offered_first():
    """The telegraph and the menu have to agree about what matters."""
    from bot.cogs.trial import MoveSelect

    moves = [
        {"technique_id": 1, "name": "Big Hit", "covers": [],
         "path_name": "Fire Path", "answers": False},
        {"technique_id": 2, "name": "Rooted Stance", "covers": ["harden"],
         "path_name": "Earth Path", "answers": True},
        {"technique_id": 3, "name": "Step Into the Gap", "covers": ["pull"],
         "path_name": "Human Path", "answers": True},
    ]
    select = MoveSelect(None, moves, None, "pull")
    labels = [o.label for o in select.options]

    assert labels[0] == "Step Into the Gap"
    # Then the one that answers something else, then the plain attack.
    assert labels.index("Rooted Stance") < labels.index("Big Hit")
