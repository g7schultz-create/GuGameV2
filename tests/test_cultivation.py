"""Tests for the cultivation and physique pillars (migration 0006)."""

import psycopg
import pytest


# ---------------------------------------------------------------------------
# The realm ladder
# ---------------------------------------------------------------------------

def test_realm_ladder_is_nine_great_realms(conn):
    """Nine great realms, four stages each - except Spirit Severing, which is
    three severings rather than four stages, the way the source material has
    it.

    0334 put nine Gu Immortal ranks above them, four stages each and no
    exceptions, so the ladder is 35 mortal realms and 36 immortal ones. Rank
    1-9 is still what every gate in the game keys off; the immortal ranks are
    deliberately outside all of them."""
    total, ranks = conn.execute(
        "SELECT count(*), count(DISTINCT rank) FROM realms"
    ).fetchone()
    assert (total, ranks) == (71, 18)

    mortal, mortal_ranks = conn.execute(
        "SELECT count(*), count(DISTINCT rank) FROM realms WHERE rank <= 9"
    ).fetchone()
    assert (mortal, mortal_ranks) == (35, 9)

    per_rank = dict(
        conn.execute("SELECT rank, count(*) FROM realms GROUP BY rank").fetchall()
    )
    assert per_rank[5] == 3, "Spirit Severing is three severings"
    assert all(n == 4 for r, n in per_rank.items() if r != 5)


def test_every_great_realm_is_named_not_numbered(conn):
    """"Rank 3 Middle" is a spreadsheet heading."""
    numbered = conn.execute(
        "SELECT name FROM realms WHERE name LIKE 'Rank %'"
    ).fetchall()
    assert numbered == []
    assert conn.execute(
        "SELECT name FROM realms WHERE realm_id = 1"
    ).fetchone()[0] == "Qi Condensation — Early"


def test_realm_ladder_never_goes_backwards(conn):
    """Cumulative requirements and caps must rise monotonically.

    A dip would make a realm unreachable, or reachable and then lost - the kind
    of bug that only shows up when a player is standing on that exact step.
    """
    regressions = conn.execute(
        """
        SELECT r.realm_id
        FROM realms r
        JOIN realms prev ON prev.realm_id = r.realm_id - 1
        WHERE r.cultivation_required <= prev.cultivation_required
           OR r.essence_capacity < prev.essence_capacity
           OR r.qi_capacity < prev.qi_capacity
           OR r.rank < prev.rank
        """
    ).fetchall()
    assert regressions == []


def test_realm_is_derivable_from_a_cultivation_total(conn):
    """The point of storing cumulative requirements: one indexed range scan.

    Asked of the whole ladder rather than of one number. This used to assert
    that 100,000 was Core Formation - Peak, which is a fact about the balance
    rather than about the lookup, and 0184 moved that stage to 120,672.
    """
    for realm_id, name, needs in conn.execute(
        "SELECT realm_id, name, cultivation_required FROM realms ORDER BY realm_id"
    ).fetchall():
        found_id, found_name = conn.execute(
            """
            SELECT realm_id, name FROM realms
            WHERE cultivation_required <= %s
            ORDER BY cultivation_required DESC
            LIMIT 1
            """,
            (needs,),
        ).fetchone()
        assert (found_id, found_name) == (realm_id, name), (
            f"{needs} resolved to {found_name}, not {name}"
        )


def test_technique_rank_gating_uses_realm_rank(conn, make_player, make_technique):
    """Spec section 9: cultivation determines which ranks are usable at all."""
    player_id = make_player()
    conn.execute(
        "INSERT INTO player_cultivation (player_id, realm_id) VALUES (%s, 9)",
        (player_id,),  # Rank 3 Peak
    )
    make_technique("rank2_move", base_power=50)
    conn.execute("UPDATE techniques SET rank = 2 WHERE code = 'rank2_move'")
    make_technique("rank6_move", base_power=5000)
    conn.execute("UPDATE techniques SET rank = 6 WHERE code = 'rank6_move'")

    usable = conn.execute(
        """
        SELECT t.code
        FROM techniques t
        JOIN player_cultivation pc ON pc.player_id = %s
        JOIN realms r ON r.realm_id = pc.realm_id
        WHERE t.rank <= r.rank AND t.code IN ('rank2_move', 'rank6_move')
        """,
        (player_id,),
    ).fetchall()
    assert [row[0] for row in usable] == ["rank2_move"]


# ---------------------------------------------------------------------------
# Physique
# ---------------------------------------------------------------------------

def test_named_physiques_from_the_design_doc_exist(conn):
    rows = dict(
        conn.execute(
            "SELECT code, affinity_path FROM physiques WHERE affinity_path IS NOT NULL"
        ).fetchall()
    )
    assert rows["great_strength_true_martial"] == "strength"
    assert rows["northern_dark_ice_soul"] == "ice"


def test_affinity_bonus_without_a_path_is_rejected(conn):
    """A bonus with nothing to apply to is a data-entry mistake, not a valid row."""
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute(
            "INSERT INTO physiques (code, name, affinity_path, affinity_bonus) "
            "VALUES ('broken', 'Broken', NULL, 1.5)"
        )


def test_hp_cannot_exceed_max(conn, make_player):
    """Overhealing is a bug that hides itself, so it is made impossible."""
    player_id = make_player()
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute(
            "INSERT INTO player_physique (player_id, max_hp, current_hp) "
            "VALUES (%s, 100, 101)",
            (player_id,),
        )


def test_a_physique_in_use_cannot_be_deleted(conn, make_player):
    player_id = make_player()
    physique_id = conn.execute(
        "SELECT physique_id FROM physiques WHERE code = 'mortal_body'"
    ).fetchone()[0]
    conn.execute(
        "INSERT INTO player_physique (player_id, physique_id) VALUES (%s, %s)",
        (player_id, physique_id),
    )

    with pytest.raises(psycopg.errors.ForeignKeyViolation):
        conn.execute("DELETE FROM physiques WHERE physique_id = %s", (physique_id,))


# ---------------------------------------------------------------------------
# Training sessions
# ---------------------------------------------------------------------------

def _start_session(conn, player_id, *, kind="cultivation", path=None, hours=8):
    return conn.execute(
        """
        INSERT INTO training_sessions (player_id, kind, path_code, ends_at)
        VALUES (%s, %s, %s, now() + make_interval(hours => %s))
        RETURNING session_id
        """,
        (player_id, kind, path, hours),
    ).fetchone()[0]


def test_only_one_training_session_can_be_active(conn, make_player):
    """Without this, two racing commands both pay out for the same wall-clock hours."""
    player_id = make_player()
    _start_session(conn, player_id)

    with pytest.raises(psycopg.errors.UniqueViolation):
        _start_session(conn, player_id, kind="physique")


def test_a_resolved_session_frees_the_slot(conn, make_player):
    player_id = make_player()
    session_id = _start_session(conn, player_id)
    conn.execute(
        """
        UPDATE training_sessions
        SET resolved_at = now(), xp_granted = 2450, insight_granted = 0,
            dao_marks_granted = 0
        WHERE session_id = %s
        """,
        (session_id,),
    )

    _start_session(conn, player_id, kind="physique")  # must not raise


def test_resolution_cannot_be_half_finished(conn, make_player):
    """Half-resolved rows are what quietly double-pay."""
    player_id = make_player()
    session_id = _start_session(conn, player_id)

    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute(
            "UPDATE training_sessions SET resolved_at = now(), xp_granted = 100 "
            "WHERE session_id = %s",
            (session_id,),
        )


def test_pure_training_cannot_grant_path_insight(conn, make_player):
    """path_code NULL means pure: full XP, no insight (spec section 10)."""
    player_id = make_player()
    session_id = _start_session(conn, player_id, path=None)

    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute(
            """
            UPDATE training_sessions
            SET resolved_at = now(), xp_granted = 2450, insight_granted = 500,
                dao_marks_granted = 0
            WHERE session_id = %s
            """,
            (session_id,),
        )


def test_path_focused_training_grants_insight(conn, make_player):
    """The spec's own example: /cultivate path:strength duration:8h."""
    player_id = make_player()
    session_id = _start_session(conn, player_id, path="strength")

    conn.execute(
        """
        UPDATE training_sessions
        SET resolved_at = now(), xp_granted = 2450, insight_granted = 480,
            dao_marks_granted = 3
        WHERE session_id = %s
        """,
        (session_id,),
    )

    row = conn.execute(
        "SELECT path_code, insight_granted, dao_marks_granted "
        "FROM training_sessions WHERE session_id = %s",
        (session_id,),
    ).fetchone()
    assert row == ("strength", 480, 3)


def test_session_must_end_after_it_starts(conn, make_player):
    player_id = make_player()
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute(
            "INSERT INTO training_sessions (player_id, kind, ends_at) "
            "VALUES (%s, 'cultivation', now() - interval '1 hour')",
            (player_id,),
        )


def test_path_training_rates_are_configured(conn):
    """Spec sections 10 and 11: focused training trades XP for insight."""
    rates = dict(
        conn.execute(
            "SELECT key, value FROM game_config WHERE key LIKE 'path_%_xp_rate'"
        ).fetchall()
    )
    assert float(rates["path_cultivation_xp_rate"]) == 0.85
    assert float(rates["path_physique_xp_rate"]) == 0.80

def test_every_route_up_the_immortal_ladder_pays_the_drag(conn):
    """0396. Everything that grants cultivation up here is a SHARE of the stage
    it is climbing - meditation is a percentage of it, a realm costs a flat 110
    essence of its own rank, and 0382 set the passive floor at a flat thirty
    days per stage on purpose. So the ladder was flat, and realm 18 took
    exactly as long as realm 10.

    `realm_climb_drag` is the one number that bends it. A fourth route added
    later that does not divide by it would instantly become the only route
    anybody takes, so this counts the call sites rather than trusting them.
    """
    routes = {"meditate", "absorb_essence", "cultivation_per_hour"}
    reading = {
        r[0] for r in conn.execute(
            """
            SELECT p.proname FROM pg_proc p
            WHERE p.pronamespace = 'public'::regnamespace
              AND p.prosrc LIKE '%realm_climb_drag%'
            """
        ).fetchall()
    }
    assert routes <= reading, f"these do not pay the drag: {routes - reading}"


def test_the_drag_is_flat_below_the_line_and_climbs_above_it(conn):
    """Four of the six immortals in this game are at realm 10. Nothing about
    their climb may change, or a fix aimed at the top of the ladder is a nerf
    aimed at the people furthest from it."""
    line = int(
        conn.execute(
            "SELECT game_config_value('realm_drag_from_rank')"
        ).fetchone()[0]
    )
    rows = conn.execute(
        "SELECT g.rank, realm_climb_drag(g.rank::smallint) "
        "FROM generate_series(1, 18) AS g(rank) ORDER BY g.rank"
    ).fetchall()

    below = [float(d) for rank, d in rows if rank < line]
    above = [float(d) for rank, d in rows if rank >= line]

    assert below and set(below) == {1.0}, below
    assert above == sorted(above) and len(set(above)) == len(above), above
    assert above[0] > 1.0, "the first dragged realm is not dragged"

def test_qi_comes_back_on_the_settle_tick(conn, make_player):
    """0397. Health had returned on every tick since `settle_passive_cultivation`
    was written. Qi never did - the only four things in the schema that put it
    back were a pill, a guarded round, a horde wave, and spending it.

    Every cultivator in the game was at under two per cent of their aperture
    and not one of them could pay for a single technique. It was reported as
    "my destiny technique stopped working after a breakthrough", because a
    technique costs a share of the aperture and the aperture quadruples with
    the realm - crossing did not break it, it made it impossible to miss.
    """
    who = make_player("Dry")
    conn.execute(
        "INSERT INTO player_cultivation (player_id, realm_id, qi) VALUES (%s, 1, 0)",
        (who,),
    )
    # The settle tick grants physique XP too, and refuses a body it cannot find.
    conn.execute(
        "INSERT INTO player_physique (player_id, physique_id) VALUES "
        "(%s, (SELECT physique_id FROM physiques ORDER BY physique_id LIMIT 1))",
        (who,),
    )
    pool = conn.execute("SELECT player_max_qi(%s)", (who,)).fetchone()[0]

    conn.execute(
        "UPDATE player_cultivation SET qi = 0, last_tick_at = now() - interval '1 hour' "
        "WHERE player_id = %s",
        (who,),
    )
    conn.execute("SELECT settle_passive_cultivation(%s)", (who,))

    after = conn.execute(
        "SELECT qi FROM player_cultivation WHERE player_id = %s", (who,)
    ).fetchone()[0]
    assert after > 0, "an hour of rest returned no qi at all"
    assert after <= pool, f"the aperture overfilled: {after} of {pool}"

    # And it stops at the brim rather than running past it.
    conn.execute(
        "UPDATE player_cultivation SET last_tick_at = now() - interval '100 hours' "
        "WHERE player_id = %s",
        (who,),
    )
    conn.execute("SELECT settle_passive_cultivation(%s)", (who,))
    assert conn.execute(
        "SELECT qi FROM player_cultivation WHERE player_id = %s", (who,)
    ).fetchone()[0] == pool


def test_a_crossing_leaves_you_able_to_act(conn, make_player):
    """The aperture is remade on a breakthrough, so it comes out full. Before
    0397 you watched your pool quadruple, kept whatever qi you were holding,
    and emerged from the best moment in the game unable to throw anything."""
    who = make_player("Crossing")
    conn.execute(
        "INSERT INTO player_cultivation (player_id, realm_id, qi) VALUES (%s, 1, 0)",
        (who,),
    )
    conn.execute(
        "INSERT INTO player_physique (player_id, physique_id) VALUES "
        "(%s, (SELECT physique_id FROM physiques ORDER BY physique_id LIMIT 1))",
        (who,),
    )
    conn.execute(
        """
        UPDATE player_cultivation pc SET cultivation =
            (SELECT r.cultivation_required FROM realms r
             WHERE r.realm_id = pc.realm_id + 1), qi = 0
        WHERE pc.player_id = %s
        """,
        (who,),
    )
    conn.execute("SELECT breakthrough(%s)", (who,))

    qi, pool = conn.execute(
        "SELECT pc.qi, player_max_qi(pc.player_id) FROM player_cultivation pc "
        "WHERE pc.player_id = %s",
        (who,),
    ).fetchone()
    assert qi == pool, f"a crossing left the aperture at {qi} of {pool}"
