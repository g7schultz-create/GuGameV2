"""Static checks on the migration files. Needs no database.

Parses every migration with libpg_query - the actual PostgreSQL parser, via
pglast - so a syntax error is caught here rather than half way through a Railway
deploy. This validates grammar only: it will not catch a reference to a column
that does not exist, which still needs a real `migrate up`.

    python -m db.lint
"""

import pathlib
import sys

try:
    import pglast
except ImportError:
    print("error: pglast is not installed. `pip install -r requirements-dev.txt`", file=sys.stderr)
    raise SystemExit(1)

from .migrate import discover


def main() -> int:
    try:
        migrations = discover()
    except RuntimeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if not migrations:
        print("No migrations to check.")
        return 0

    failures = 0
    for migration in migrations:
        # A migration that parses to zero statements is almost always a
        # scaffold from `migrate new` that was never filled in - applying it
        # would record a version having done nothing at all.
        try:
            statements = pglast.parse_sql(migration.sql)
        except pglast.parser.ParseError as exc:
            print(f"FAIL  {migration}: {exc}")
            failures += 1
            continue

        if not statements:
            print(f"FAIL  {migration}: contains no statements (unfilled scaffold?)")
            failures += 1
            continue

        print(f"ok    {migration}: {len(statements)} statement(s)")

    print()
    if failures:
        print(f"{failures} of {len(migrations)} migration(s) failed.")
        return 1
    print(f"All {len(migrations)} migration(s) parse cleanly.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
