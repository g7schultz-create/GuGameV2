"""Forward-only SQL migration runner.

The .sql files in db/migrations/ are the source of truth for the schema. There
is no ORM and no autogeneration: you write the DDL, this applies it once, in
order, and records that it did.

    python -m db.migrate status      # what is applied, what is pending
    python -m db.migrate up          # apply everything pending
    python -m db.migrate new <name>  # scaffold the next numbered file
    python -m db.migrate verify      # check applied files have not been edited

Railway runs `up` automatically on deploy via the `release` line in Procfile.
"""

import hashlib
import pathlib
import re
import sys
import time

import psycopg

from .connection import connect

MIGRATIONS_DIR = pathlib.Path(__file__).parent / "migrations"

# 0001_some_name.sql -- the numeric prefix is the version and defines apply order.
FILENAME_RE = re.compile(r"^(\d{4})_([a-z0-9_]+)\.sql$")

# Guards against two Railway instances deploying at once and both trying to
# migrate. Any arbitrary constant works as long as nothing else in the app uses
# it. This is a *session* lock, not a transaction one, because the run below
# spans many transactions and the lock has to outlive all of them.
LOCK_KEY = 0x67754741  # "guGA"


class Migration:
    def __init__(self, path: pathlib.Path, version: str, name: str):
        self.path = path
        self.version = version
        self.name = name
        self.sql = path.read_text(encoding="utf-8")
        self.checksum = hashlib.sha256(self.sql.encode("utf-8")).hexdigest()[:16]

    def __repr__(self) -> str:
        return f"{self.version}_{self.name}"


def discover() -> list[Migration]:
    """Every migration on disk, in apply order.

    A file that does not match FILENAME_RE is an error rather than a skip: a
    typo in a filename that silently never runs is the worst outcome here.
    """
    if not MIGRATIONS_DIR.is_dir():
        raise RuntimeError(f"No migrations directory at {MIGRATIONS_DIR}")

    migrations: list[Migration] = []
    seen: dict[str, str] = {}
    for path in sorted(MIGRATIONS_DIR.glob("*.sql")):
        match = FILENAME_RE.match(path.name)
        if not match:
            raise RuntimeError(
                f"Bad migration filename {path.name!r}: "
                "expected NNNN_lower_snake_case.sql"
            )
        version, name = match.group(1), match.group(2)
        if version in seen:
            raise RuntimeError(
                f"Duplicate migration version {version}: {seen[version]} and {path.name}"
            )
        seen[version] = path.name
        migrations.append(Migration(path, version, name))
    return migrations


def ensure_ledger(conn: psycopg.Connection) -> None:
    """Create the bookkeeping table.

    Bootstrapped in code rather than as migration 0000 for the obvious reason:
    the runner needs somewhere to record 0000. IF NOT EXISTS makes it a no-op on
    every run after the first.
    """
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version     TEXT        PRIMARY KEY,
            name        TEXT        NOT NULL,
            checksum    TEXT        NOT NULL,
            applied_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
            duration_ms INTEGER     NOT NULL
        )
        """
    )


def applied_map(conn: psycopg.Connection) -> dict[str, tuple[str, str]]:
    """version -> (name, checksum) for everything already run."""
    rows = conn.execute("SELECT version, name, checksum FROM schema_migrations").fetchall()
    return {version: (name, checksum) for version, name, checksum in rows}


def check_drift(
    migrations: list[Migration], applied: dict[str, tuple[str, str]]
) -> list[str]:
    """Applied migrations whose file has been edited since.

    Editing an already-applied migration means the repo and the database have
    silently diverged: the file says one thing, the live schema is whatever the
    old version of it did. The fix is always a new migration, never an edit, so
    this surfaces loudly instead of rotting.
    """
    problems = []
    for migration in migrations:
        record = applied.get(migration.version)
        if record and record[1] != migration.checksum:
            problems.append(
                f"  {migration}: file changed after it was applied "
                f"(recorded {record[1]}, file is now {migration.checksum})"
            )
    return problems


def cmd_status() -> int:
    migrations = discover()
    with connect(autocommit=True) as conn:
        ensure_ledger(conn)
        applied = applied_map(conn)

    if not migrations:
        print("No migrations on disk.")
        return 0

    print(f"{'':2} {'VERSION':8} {'NAME':40} STATUS")
    pending = 0
    for migration in migrations:
        if migration.version in applied:
            mark, status = "*", "applied"
        else:
            mark, status = " ", "pending"
            pending += 1
        print(f"{mark:2} {migration.version:8} {migration.name:40} {status}")

    orphans = set(applied) - {m.version for m in migrations}
    for version in sorted(orphans):
        print(f"?  {version:8} {applied[version][0]:40} applied, but no file on disk")

    print(f"\n{len(migrations) - pending} applied, {pending} pending")

    drift = check_drift(migrations, applied)
    if drift:
        print("\nWARNING - applied migrations have been edited:")
        print("\n".join(drift))
    return 0


def cmd_verify() -> int:
    """Non-zero exit if the live schema does not match the repo. CI-friendly."""
    migrations = discover()
    with connect(autocommit=True) as conn:
        ensure_ledger(conn)
        applied = applied_map(conn)

    drift = check_drift(migrations, applied)
    if drift:
        print("Checksum mismatch - these files changed after being applied:")
        print("\n".join(drift))
        print("\nFix by reverting the edit and writing a new migration instead.")
        return 1

    missing = [m for m in migrations if m.version not in applied]
    if missing:
        print(f"{len(missing)} migration(s) pending: {', '.join(map(str, missing))}")
        return 1

    print(f"OK - {len(migrations)} migration(s) applied, no drift.")
    return 0


def cmd_up() -> int:
    migrations = discover()

    # autocommit at the connection level so each migration below can open its
    # own explicit transaction. Postgres DDL is transactional, so a migration
    # that fails half way leaves nothing behind - and the ones before it stay
    # applied rather than being rolled back along with it.
    with connect(autocommit=True) as conn:
        ensure_ledger(conn)
        conn.execute("SELECT pg_advisory_lock(%s)", (LOCK_KEY,))
        try:
            applied = applied_map(conn)

            drift = check_drift(migrations, applied)
            if drift:
                print("Refusing to migrate - applied migrations have been edited:")
                print("\n".join(drift))
                return 1

            pending = [m for m in migrations if m.version not in applied]
            if not pending:
                print("Nothing to do - schema is up to date.")
                return 0

            print(f"Applying {len(pending)} migration(s)...")
            for migration in pending:
                started = time.monotonic()
                try:
                    with conn.transaction():
                        conn.execute(migration.sql)
                        conn.execute(
                            """
                            INSERT INTO schema_migrations
                                (version, name, checksum, duration_ms)
                            VALUES (%s, %s, %s, %s)
                            """,
                            (
                                migration.version,
                                migration.name,
                                migration.checksum,
                                int((time.monotonic() - started) * 1000),
                            ),
                        )
                except psycopg.Error as exc:
                    print(f"  FAILED  {migration}")
                    print(f"          {exc}")
                    print(f"\n{migration} was rolled back. Earlier ones are still applied.")
                    return 1
                print(
                    f"  ok      {migration}  "
                    f"({int((time.monotonic() - started) * 1000)} ms)"
                )
        finally:
            conn.execute("SELECT pg_advisory_unlock(%s)", (LOCK_KEY,))

    print("Done.")
    return 0


def cmd_new(name: str) -> int:
    slug = re.sub(r"[^a-z0-9]+", "_", name.lower()).strip("_")
    if not slug:
        print("Give the migration a name, e.g. `python -m db.migrate new add_guilds`")
        return 1

    migrations = discover()
    next_version = f"{(int(migrations[-1].version) + 1) if migrations else 1:04d}"
    path = MIGRATIONS_DIR / f"{next_version}_{slug}.sql"
    path.write_text(
        f"-- {next_version}_{slug}\n"
        "--\n"
        "-- Forward-only. Once this has run anywhere, do not edit it - write a new\n"
        "-- migration instead (the runner checksums applied files and will refuse).\n\n",
        encoding="utf-8",
    )
    print(f"Created {path}")
    return 0


def main(argv: list[str]) -> int:
    command = argv[1] if len(argv) > 1 else "status"

    handlers = {
        "status": cmd_status,
        "up": cmd_up,
        "verify": cmd_verify,
    }

    try:
        if command == "new":
            return cmd_new(" ".join(argv[2:]))
        if command in handlers:
            return handlers[command]()
    except (RuntimeError, psycopg.OperationalError) as exc:
        # Misconfiguration and "the database is not reachable" are ordinary
        # operator errors, not bugs - a traceback here just buries the message.
        print(f"error: {exc}", file=sys.stderr)
        return 1

    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
