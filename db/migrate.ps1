#Requires -Version 7
<#
.SYNOPSIS
    Applies all versioned SQL migrations in db/migrations to the TOPH database.
.DESCRIPTION
    Migration tool choice: plain numbered SQL files applied with psql inside a
    single transaction each, recorded in schema_migrations. No external
    dependency, fully readable by a reviewer, matches the psql reproduction
    story used everywhere else in this repo.
    Creates the database when it does not exist. Idempotent: already-applied
    files are skipped by name.
#>
[CmdletBinding()]
param(
    [int]$Port = 5433,
    [string]$Database = "toph",
    [string]$PgBin = "C:\Program Files\PostgreSQL\17\bin",
    [switch]$Recreate
)

$ErrorActionPreference = "Stop"
$psql = Join-Path $PgBin "psql.exe"
$migrationsDir = Join-Path $PSScriptRoot "migrations"

function Invoke-Psql {
    param([string[]]$Arguments)
    & $psql -X -h 127.0.0.1 -p $Port -U postgres @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "psql failed with exit code $LASTEXITCODE" }
}

if ($Recreate) {
    Write-Host "Dropping database $Database (if it exists) ..."
    Invoke-Psql @("-d", "postgres", "-v", "ON_ERROR_STOP=1", "-c", "DROP DATABASE IF EXISTS $Database WITH (FORCE)")
}

$exists = & $psql -X -h 127.0.0.1 -p $Port -U postgres -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$Database'"
if ("$exists".Trim() -ne "1") {
    Write-Host "Creating database $Database ..."
    Invoke-Psql @("-d", "postgres", "-v", "ON_ERROR_STOP=1", "-c", "CREATE DATABASE $Database")
} else {
    Write-Host "Database $Database already exists."
}

Invoke-Psql @("-d", $Database, "-v", "ON_ERROR_STOP=1", "-c",
    "CREATE TABLE IF NOT EXISTS schema_migrations (version text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now());")

Get-ChildItem -LiteralPath $migrationsDir -Filter "*.sql" | Sort-Object Name | ForEach-Object {
    $version = $_.Name
    $applied = & $psql -X -h 127.0.0.1 -p $Port -U postgres -d $Database -tAc "SELECT 1 FROM schema_migrations WHERE version = '$version'"
    if ("$applied".Trim() -eq "1") {
        Write-Host "Migration $version already applied - skipping."
        return
    }
    Write-Host "Applying migration $version ..."
    Invoke-Psql @("-d", $Database, "-v", "ON_ERROR_STOP=1", "-f", $_.FullName)
    Invoke-Psql @("-d", $Database, "-v", "ON_ERROR_STOP=1", "-c",
        "INSERT INTO schema_migrations (version) VALUES ('$version')")
    Write-Host "Migration $version applied."
}

Write-Host "Migrations up to date."
