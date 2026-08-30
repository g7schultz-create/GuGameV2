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
    [string]$Command = 'status'
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
