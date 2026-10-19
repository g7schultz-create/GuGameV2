# Deploying to Railway

Written for whoever runs this bot — you, mostly, six months from now.

## Before anything: the repo is nearly empty

Railway deploys what is **committed**, and this repository is an early snapshot:

| | on disk | committed |
| --- | --- | --- |
| migrations | 585 | **8** |
| `bot/` | 49 extensions, ~31k lines | **0 files** |

Pushing as-is would deploy a bot with no bot in it and a schema stuck at 0008.
`.gitignore` is correct — it excludes `.env`, `__pycache__` and logs, and nothing
else — so everything missing is merely *untracked* and `git add` picks it up.

```sh
git add -A
git commit -m "Add the bot, the cogs and migrations 0009-0585"
```

**Check `.env` is not in that commit** before pushing. It holds a real Discord
token; if it ever lands in a commit, the token is burned and must be reset in
the Developer Portal — removing the file in a later commit does not help,
because the old commit still has it.

```sh
git show --stat --name-only HEAD | grep -x ".env" && echo "STOP - secret staged"
```

## The services

Two, in one Railway project:

1. **Postgres** — Railway's own. Add it first; it publishes `DATABASE_URL`.
2. **The bot** — deployed from this repo.

## Variables on the bot service

| name | value |
| --- | --- |
| `DISCORD_TOKEN` | from the Developer Portal → Bot → Reset Token |
| `DATABASE_URL` | `${{Postgres.DATABASE_URL}}` — a reference, not a paste |
| `GUILD_ID` | your server's id. **Set this.** |
| `BOSS_CHANNEL_ID` | optional; where a slain world beast is announced |
| `HORDE_CHANNEL_ID` | optional; where a Beast Horde runs |
| `DEV_COMMANDS` | leave unset |

Use the `${{Postgres.DATABASE_URL}}` reference rather than copying the string:
Railway rotates credentials, and a pasted URL silently stops working. The
*internal* URL is the right one here — the bot runs inside the same project.
`DATABASE_PUBLIC_URL` is for reaching the database from your own machine.

`GUILD_ID` matters more than it looks. Set, commands register to that one
server and appear immediately. Unset, they register globally and can take an
hour to propagate — which reads exactly like a broken deploy.

## Start and pre-deploy commands

**Set these in the service settings, not in the `Procfile`.** The `Procfile`
here is kept as documentation of intent, but Railway's handling of it is not
dependable: community reports have `worker:` failing with *command not found*
and `release:` never running at all. The dashboard fields are the supported
mechanism.

- **Settings → Deploy → Custom Start Command:** `python -m bot`
- **Settings → Deploy → Pre-Deploy Command:** `python -m db.migrate up`

The pre-deploy command is not optional. The bot opens its pool and queries
immediately; against an unmigrated database it fails on the first interaction.
Migrations are forward-only and each runs in one transaction with its own
probes, so re-running `up` on an already-current database prints *"Nothing to
do"* and changes nothing — it is safe on every deploy.

After the first deploy, confirm it actually ran:

```
python -m db.migrate status     # in the Railway shell, or check the deploy log
```

If the pre-deploy field is empty or silently skipped, the bot's log will show a
Postgres error about a missing relation rather than `database pool open`.

## Python version

`.python-version` pins **3.14**, matching local. `runtime.txt` says the same for
the older Nixpacks builder, in case the project is not on Railpack.

The floor is **3.12**: `bot/__main__.py` passes `loop_factory=` to
`asyncio.run`, which does not exist before then. So if the build cannot get
3.14, 3.13 is a safe fall-back and 3.11 is not.

## No port, and no healthcheck

This is a worker: it makes an outbound gateway connection to Discord and listens
on nothing. Do not give it a domain, and leave the healthcheck path empty — a
healthcheck against a service with no HTTP server fails forever and Railway
will keep restarting a bot that is working perfectly.

## What to look for in the log

A good start looks like this, in this order:

```
database pool open
loaded 48 extension(s)
synced 99 command(s) to guild <id>
logged in as <bot>#<disc>
```

- **99, not 100** — `/dev` is gated behind `DEV_COMMANDS` and that is deliberate;
  the tree is at Discord's hundred-command ceiling with one slot spare.
- **`loaded 48`, not 49** — `bot.cogs.dev` is the one not loaded.
- A **`PrivilegedIntentsRequired`** warning instead of a crash means MESSAGE
  CONTENT is off in the portal. Slash commands are unaffected; only the
  `I hunt` prefix form stops working. The bot deliberately starts without it.

## The database that already exists

The live world — 34 players, 585 migrations — is in **local** Postgres, not on
Railway. Deploying gives you an empty world, not this one. Moving it across is a
`pg_dump` / `pg_restore` job and a separate decision: the characters in it are
real, and a half-finished copy is worse than a clean start.

```sh
# the shape of it, when you decide to
pg_dump  --no-owner --no-privileges "<local url>"   > world.sql
psql "<railway DATABASE_PUBLIC_URL>"               < world.sql
```

Run the migrations on the Railway database **or** restore the dump, not both —
a restore carries `schema_migrations` with it, so a dump of a current database
lands already at 0585.
