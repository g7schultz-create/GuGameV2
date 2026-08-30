"""Tests for the cultivation and physique pillars (migration 0006)."""

import psycopg
import pytest


# ---------------------------------------------------------------------------
# The realm ladder
# ---------------------------------------------------------------------------

def test_realm_ladder_is_nine_ranks_of_three_stages(conn):
    total, ranks = conn.execute(
        "SELECT count(*), count(DISTINCT rank) FROM realms"
    ).fetchone()
    assert (total, ranks) == (27, 9)


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
    """The point of storing cumulative requirements: one indexed range scan."""
    realm_id, name = conn.execute(
        """
        SELECT realm_id, name FROM realms
        WHERE cultivation_required <= %s
        ORDER BY cultivation_required DESC
        LIMIT 1
        """,
        (100_000,),
    ).fetchone()
    assert name == "Rank 3 Peak"
    assert realm_id == 9


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
