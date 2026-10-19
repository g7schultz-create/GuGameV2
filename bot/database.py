"""Async access to the same database `db/` migrates.

The migration runner and the tests are synchronous and short-lived, so they
open a connection and close it. The bot is neither: it is one long-lived
process serving many interactions at once on a single event loop, where a
blocking `psycopg.connect` would stall every other command in flight. Hence a
pool of async connections here rather than reusing `db.connection.connect`.

What is *not* duplicated is the URL: `database_url()` still normalises it in
exactly one place, so a change to how Railway's scheme is handled reaches the
bot without being written twice.
"""

import logging
from typing import Any, Callable, Iterable

import psycopg
from psycopg.rows import dict_row
from psycopg_pool import AsyncConnectionPool

from db.connection import database_url

log = logging.getLogger("gu.db")

_pool: AsyncConnectionPool | None = None


async def open_pool() -> AsyncConnectionPool:
    """Open the pool and prove the database is reachable.

    `open()` alone is lazy - it would let the bot log in to Discord, announce
    itself as ready and only then fail on the first command. Connecting once
    here turns a bad DATABASE_URL into a startup failure instead.
    """
    global _pool
    if _pool is None:
        _pool = AsyncConnectionPool(
            database_url(),
            min_size=1,
            max_size=8,
            kwargs={"row_factory": dict_row},
            open=False,
        )
        await _pool.open(wait=True, timeout=15)
    return _pool


async def close_pool() -> None:
    global _pool
    if _pool is not None:
        await _pool.close()
        _pool = None


def pool() -> AsyncConnectionPool:
    if _pool is None:
        raise RuntimeError("the connection pool is not open")
    return _pool


# ---------------------------------------------------------------------------
# Query helpers
#
# Each takes a connection from the pool, runs one statement and gives the
# connection straight back. Anything needing several statements to be atomic
# takes a connection itself with `pool().connection()` instead - psycopg opens
# a transaction on the block and commits it on a clean exit.
# ---------------------------------------------------------------------------


async def _run(sql: str, params: Iterable[Any], harvest: Callable | None) -> Any:
    """One statement, with one retry when a migration moves the ground.

    psycopg prepares a statement on the server after it has been run a few
    times, and a prepared `SELECT *` remembers the shape of what it returned.
    Migrations here are forward-only and get applied while the bot is running,
    so a view gaining a column - 0224 adding `seconds_left` to `horde_board` -
    makes Postgres refuse every later run of that plan with "cached plan must
    not change result type". Pooled connections are long-lived, so it refuses
    for as long as the process lives. It took down the horde tick during the
    first live tide and only a restart brought it back.

    `rollback()` is psycopg's own reset for this: it clears the prepared cache
    and deallocates on the server. So take that path once and run the statement
    again. Retrying is safe because nothing else has happened in this
    transaction yet - the failing statement is the first one on the connection.
    """
    async with pool().connection() as conn:
        try:
            cur = await conn.execute(sql, params)
        except psycopg.errors.FeatureNotSupported as exc:
            if "cached plan" not in str(exc):
                raise
            log.info("a migration changed a result shape; replanning")
            await conn.rollback()
            cur = await conn.execute(sql, params)
        return await harvest(cur) if harvest else None


async def fetch_one(sql: str, params: Iterable[Any] = ()) -> dict | None:
    return await _run(sql, params, lambda cur: cur.fetchone())


async def fetch_all(sql: str, params: Iterable[Any] = ()) -> list[dict]:
    return await _run(sql, params, lambda cur: cur.fetchall())


async def fetch_value(sql: str, params: Iterable[Any] = ()) -> Any:
    """The first column of the first row, or None. For counts and lookups."""
    row = await fetch_one(sql, params)
    if row is None:
        return None
    return next(iter(row.values()))


async def execute(sql: str, params: Iterable[Any] = ()) -> None:
    await _run(sql, params, None)
