#Requires -Version 7
<#
.SYNOPSIS
    Seeds the TOPH database with reproducible, representative data.
#>
[CmdletBinding()]
param(
    [int]$Port = 5433,
    [string]$Database = "toph",
    [string]$PgBin = "C:\Program Files\PostgreSQL\17\bin"
)

$ErrorActionPreference = "Stop"
$psql = Join-Path $PgBin "psql.exe"
$seedFile = Join-Path $PSScriptRoot "seed.sql"

Write-Host "Seeding database $Database on port $Port ..."
& $psql -X -h 127.0.0.1 -p $Port -U postgres -d $Database -v ON_ERROR_STOP=1 -f $seedFile
if ($LASTEXITCODE -ne 0) { throw "psql seed failed with exit code $LASTEXITCODE" }
Write-Host "Seeding complete."
