<#
.SYNOPSIS
    Drives the local development PostgreSQL instance.

.DESCRIPTION
    A portable PostgreSQL 17 lives in ..\localpg (outside this repo, and not
    tracked). It is not a Windows service and needs no admin rights - it runs
    only while started, on port 55432 so it cannot collide with a real install.

    Trust authentication, listening on 127.0.0.1 only. Fine for a scratch
    database on a dev machine; never expose it.

.EXAMPLE
    .\tools\localpg.ps1 start
    .\tools\localpg.ps1 psql
    .\tools\localpg.ps1 reset     # drop and recreate gugame_dev, then migrate
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet('start', 'stop', 'status', 'psql', 'reset', 'log')]
    [string]$Command = 'status',

    # Only meaningful for `reset`: wipe the database even though real players
    # exist in it.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$PgRoot = Join-Path (Split-Path -Parent $Root) 'localpg'
$Bin = Join-Path $PgRoot 'pgsql\bin'
$Data = Join-Path $PgRoot 'data'
$Log = Join-Path $PgRoot 'pg.log'
$Port = 55432
$Db = 'gugame_dev'

if (-not (Test-Path $Bin)) {
    Write-Error "No local PostgreSQL at $PgRoot. See the README's local setup section."
}

switch ($Command) {
    'start' {
        & "$Bin\pg_ctl.exe" -D $Data -l $Log -o "-p $Port -c listen_addresses=127.0.0.1" -w start
    }
    'stop' {
        & "$Bin\pg_ctl.exe" -D $Data -m fast stop
    }
    'status' {
        & "$Bin\pg_ctl.exe" -D $Data status
    }
    'psql' {
        & "$Bin\psql.exe" -h 127.0.0.1 -p $Port -U postgres -d $Db
    }
    'log' {
        Get-Content $Log -Tail 40
    }
    'reset' {
        # Refuse to drop a database that has players in it.
        #
        # `reset` is for a scratch database, and it stops being scratch the
        # moment somebody registers a character through the bot. Wiping their
        # progress to re-run an edited migration is never the right trade: the
        # migrations are forward-only, so the fix is a NEW migration, not a
        # rebuild. -Force is there for when the wipe is genuinely intended.
        $players = (& "$Bin\psql.exe" -h 127.0.0.1 -p $Port -U postgres -d $Db `
            -tAc "SELECT count(*) FROM players;" 2>$null)
        if (-not $Force -and $players -and [int]$players -gt 0) {
            Write-Error @"
$Db holds $players player(s). Refusing to drop it.

Those are real characters - resetting deletes them and they cannot be
recovered. If you edited an already-applied migration, write a new one
instead; that is what forward-only means.

Re-run with -Force if you genuinely mean to wipe them.
"@
        }

        # Terminate stragglers first: DROP DATABASE fails outright if anything
        # still holds a connection, and a leftover psql is the usual culprit.
        & "$Bin\psql.exe" -h 127.0.0.1 -p $Port -U postgres -d postgres -c `
            "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$Db' AND pid <> pg_backend_pid();" | Out-Null
        & "$Bin\psql.exe" -h 127.0.0.1 -p $Port -U postgres -d postgres -c "DROP DATABASE IF EXISTS $Db;"
        & "$Bin\psql.exe" -h 127.0.0.1 -p $Port -U postgres -d postgres -c "CREATE DATABASE $Db;"
        Push-Location $Root
        try {
            $env:DATABASE_URL = "postgresql://postgres@127.0.0.1:$Port/$Db"
            python -m db.migrate up
        }
        finally { Pop-Location }
    }
}
