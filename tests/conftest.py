"""Test fixtures.

Every test runs inside a transaction that is rolled back afterwards, so tests
share one migrated database without seeing each other's writes and without the
cost of rebuilding the schema per test.

Point DATABASE_URL at a SCRATCH database - the session fixture migrates it, and
the tests write to it. Never point it at anything you care about.
"""

import os

import psycopg
import pytest

from db.connection import connect
from db.migrate import cmd_up


@pytest.fixture(scope="session", autouse=True)
def migrated_database():
    """Bring the target database up to date once per test session."""
    if not os.getenv("DATABASE_URL"):
        pytest.skip("DATABASE_URL is not set; skipping schema tests")
    if cmd_up() != 0:
        pytest.fail("migrations failed to apply")


@pytest.fixture
def conn():
    """A connection whose work is always rolled back.

    Not autocommit: the implicit transaction is what makes the rollback in the
    teardown able to undo everything the test did.
    """
    connection = connect()
    try:
        yield connection
    finally:
        connection.rollback()
        connection.close()


# ---------------------------------------------------------------------------
# Builders. Each returns the new row's id so tests can wire records together
# without repeating the same INSERT boilerplate.
#
# `code` is UNIQUE table-wide, and seeded canonical content shares that
# namespace - so a fixture must not reuse a code a migration already claims
# (`blood_blade`, `nine_distortion_wolf`, ...) or it collides the moment that
# content is applied. Suffix fixture codes rather than naming them after the
# content they stand in for.
# ---------------------------------------------------------------------------

_next_discord_id = iter(range(900_000_000_000_000_000, 999_999_999_999_999_999))


@pytest.fixture
def make_player(conn):
    def _make(name: str = "Tester") -> int:
        return conn.execute(
            "INSERT INTO players (discord_id, discord_name) VALUES (%s, %s) "
            "RETURNING player_id",
            (next(_next_discord_id), name),
        ).fetchone()[0]

    return _make


@pytest.fixture
def make_technique(conn):
    def _make(
        code: str | None = None,
        *,
        name: str = "Test Technique",
        paths: dict[str, str] | None = None,
        created_by: int | None = None,
        category: str = "attack",
        base_power: int = 100,
    ) -> int:
        technique_id = conn.execute(
            """
            INSERT INTO techniques (code, name, category, base_power, created_by)
            VALUES (%s, %s, %s, %s, %s)
            RETURNING technique_id
            """,
            (code, name, category, base_power, created_by),
        ).fetchone()[0]

        for path_code, weight in (paths or {"fire": "1.0"}).items():
            conn.execute(
                "INSERT INTO technique_paths (technique_id, path_code, weight) "
                "VALUES (%s, %s, %s)",
                (technique_id, path_code, weight),
            )
        return technique_id

    return _make


@pytest.fixture
def make_species(conn):
    def _make(
        code: str,
        *,
        name: str = "Test Beast",
        paths: list[str] | None = None,
        base_hp: int = 1000,
    ) -> int:
        species_id = conn.execute(
            "INSERT INTO creature_species (code, name, base_hp) VALUES (%s, %s, %s) "
            "RETURNING species_id",
            (code, name, base_hp),
        ).fetchone()[0]

        for index, path_code in enumerate(paths or []):
            conn.execute(
                "INSERT INTO creature_paths (species_id, path_code, is_primary) "
                "VALUES (%s, %s, %s)",
                (species_id, path_code, index == 0),
            )
        return species_id

    return _make


@pytest.fixture
def force_deferred_checks(conn):
    """Fire DEFERRABLE constraints now instead of at COMMIT.

    Tests roll back rather than commit, so a deferred trigger would otherwise
    never run and its test would pass vacuously.
    """

    def _force():
        conn.execute("SET CONSTRAINTS ALL IMMEDIATE")

    return _force
