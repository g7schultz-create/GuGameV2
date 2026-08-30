"""Single place that knows how to reach Postgres.

Everything else in the project asks for a connection here rather than reading
DATABASE_URL itself, so the URL normalisation below happens exactly once.
"""

import os

import psycopg
from dotenv import load_dotenv

load_dotenv()


def database_url() -> str:
    """The connection string, normalised for psycopg.

    Railway (and Heroku before it) hand out URLs with a `postgres://` scheme.
    psycopg only accepts `postgresql://`, so translate rather than making every
    caller remember. Raises rather than defaulting to localhost: silently
    connecting to the wrong database is far worse than failing to start.
    """
    url = os.getenv("DATABASE_URL")
    if not url:
        raise RuntimeError(
            "DATABASE_URL is not set. Copy .env.example to .env and fill it in, "
            "or add the Postgres addon in Railway."
        )
    if url.startswith("postgres://"):
        url = "postgresql://" + url[len("postgres://") :]
    return url


def connect(*, autocommit: bool = False) -> psycopg.Connection:
    """Open a new connection. Caller owns closing it (use as a context manager)."""
    return psycopg.connect(database_url(), autocommit=autocommit)
