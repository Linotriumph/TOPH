#Requires -Version 7
<#
.SYNOPSIS
    Creates and starts an isolated local PostgreSQL cluster for the TOPH schema proof.

.DESCRIPTION
    The machine already runs a PostgreSQL 17 service on port 5432 whose superuser
    password is not available to this project, so the proof uses its own cluster:
      - data directory: <repo>\.pgdata   (disposable, git-ignored)
      - listens on 127.0.0.1 only, port 5433
      - local trust authentication (sandbox only; never use for real data)
    Idempotent: re-runs only start the server when it is not already running.
#>
[CmdletBinding()]
param(
    [string]$DataDir = (Join-Path (Split-Path -Parent $PSScriptRoot) ".pgdata"),
    [int]$Port = 5433,
    [string]$PgBin = "C:\Program Files\PostgreSQL\17\bin"
)

$ErrorActionPreference = "Stop"

$initdb = Join-Path $PgBin "initdb.exe"
$pgctl  = Join-Path $PgBin "pg_ctl.exe"
$ready  = Join-Path $PgBin "pg_isready.exe"

foreach ($exe in @($initdb, $pgctl, $ready)) {
    if (-not (Test-Path -LiteralPath $exe)) { throw "PostgreSQL binary not found: $exe" }
}

if (-not (Test-Path -LiteralPath (Join-Path $DataDir "PG_VERSION"))) {
    Write-Host "Initialising new cluster at $DataDir ..."
    & $initdb -D $DataDir -U postgres -A trust -E UTF8 --locale=C
    if ($LASTEXITCODE -ne 0) { throw "initdb failed with exit code $LASTEXITCODE" }

    Add-Content -LiteralPath (Join-Path $DataDir "postgresql.conf") -Value @"

# --- TOPH local sandbox overrides ---
listen_addresses = 'localhost'
port = $Port
"@
    Write-Host "Cluster initialised."
} else {
    Write-Host "Cluster already initialised at $DataDir"
}

& $ready -h 127.0.0.1 -p $Port -d postgres -U postgres | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Starting cluster on port $Port ..."
    # Start detached (Start-Process) so the server survives this script and its
    # parent shell; stop it later with: pg_ctl -D <DataDir> stop
    $postgres = Join-Path $PgBin "postgres.exe"
    Start-Process -FilePath $postgres -ArgumentList @("-D", $DataDir, "-p", "$Port") `
        -RedirectStandardOutput (Join-Path $DataDir "server.out.log") `
        -RedirectStandardError  (Join-Path $DataDir "server.err.log") `
        -WindowStyle Hidden

    $deadline = (Get-Date).AddSeconds(30)
    $readyOk = $false
    while ((Get-Date) -lt $deadline) {
        & $ready -h 127.0.0.1 -p $Port -d postgres -U postgres | Out-Null
        if ($LASTEXITCODE -eq 0) { $readyOk = $true; break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $readyOk) { throw "Cluster did not become ready within 30s; see $DataDir\server.err.log" }
} else {
    Write-Host "Cluster already running on port $Port"
}

Write-Host "Local TOPH cluster ready: host=127.0.0.1 port=$Port user=postgres (trust)"
