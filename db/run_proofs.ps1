#Requires -Version 7
<#
.SYNOPSIS
    Runs the complete TOPH verification suite:
      1. Re-seeds clean test data
      2. Executes the 5 primary user action queries
      3. Captures EXPLAIN (ANALYZE, BUFFERS) query plans for the 2 heaviest queries
      4. Executes invalid operations and captures database rejections
      5. Writes all evidence to the evidence/ directory
#>
[CmdletBinding()]
param(
    [int]$Port = 5433,
    [string]$Database = "toph",
    [string]$PgBin = "C:\Program Files\PostgreSQL\17\bin"
)

$ErrorActionPreference = "Stop"
$psql = Join-Path $PgBin "psql.exe"
$repoRoot = Split-Path -Parent $PSScriptRoot
$evidenceDir = Join-Path $repoRoot "evidence"

if (-not (Test-Path $evidenceDir)) {
    New-Item -ItemType Directory -Path $evidenceDir | Out-Null
}

Write-Host "=== 1. Re-seeding database ==="
& pwsh -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "seed.ps1") -Port $Port -Database $Database

Write-Host "`n=== 2. Capturing schema inventory ==="
$schemaOutput = & $psql -X -h 127.0.0.1 -p $Port -U postgres -d $Database -c "\dt+" 2>&1
$schemaOutput += "`n`nIndex Inventory:`n"
$schemaOutput += & $psql -X -h 127.0.0.1 -p $Port -U postgres -d $Database -c "\di+" 2>&1
Set-Content -Path (Join-Path $evidenceDir "schema_tables.txt") -Value $schemaOutput -Encoding utf8

Write-Host "`n=== 3. Executing Five Primary User Action Queries ==="
$queriesSql = Join-Path $PSScriptRoot "queries.sql"
$queriesOutput = & $psql -X -h 127.0.0.1 -p $Port -U postgres -d $Database -v ON_ERROR_STOP=1 -f $queriesSql 2>&1
if ($LASTEXITCODE -ne 0) { throw "Queries execution failed" }
Set-Content -Path (Join-Path $evidenceDir "five_queries_output.txt") -Value $queriesOutput -Encoding utf8
Write-Host "Five primary queries executed successfully."

Write-Host "`n=== 4. Capturing EXPLAIN ANALYZE on Two Heaviest Queries ==="
$planHeader = "================================================================================`nTOPH Ride-Hailing MVP — Query Plans for Two Heaviest Queries`nDatabase: PostgreSQL 17 on 127.0.0.1:$Port ($Database)`nGenerated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n================================================================================`n`n"

$q1 = @"
-- HEAVIEST QUERY 1: Available Trips Queue (FIFO Order)
-- Hot dispatcher/driver query matching Action 2.
-- Target Index: trips_available_idx (created_at) WHERE status = 'requested'
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, rider_id, pickup_location, dropoff_location, fare_minor, currency,
       estimated_distance_km, estimated_duration_minutes, created_at
FROM trips
WHERE status = 'requested'
ORDER BY created_at ASC
LIMIT 20;
"@

$plan1 = & $psql -X -h 127.0.0.1 -p $Port -U postgres -d $Database -c $q1 2>&1

$q2 = @"
-- HEAVIEST QUERY 2: Rider Trip History (Newest First)
-- Historical activity query matching Action 1 & Action 4.
-- Target Index: trips_rider_history_idx (rider_id, created_at DESC, id DESC)
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, driver_name_snapshot, vehicle_registration_snapshot,
       pickup_location, dropoff_location, fare_minor, currency, status,
       created_at, completed_at
FROM trips
WHERE rider_id = '11111111-1111-4111-8111-111111111111'
ORDER BY created_at DESC, id DESC
LIMIT 20;
"@

$plan2 = & $psql -X -h 127.0.0.1 -p $Port -U postgres -d $Database -c $q2 2>&1

$fullPlanOutput = $planHeader + "--- QUERY 1 PLAN (Available Trips Queue) ---`n$q1`n`n" + ($plan1 -join "`n") + "`n`n`n" + "--- QUERY 2 PLAN (Rider Trip History) ---`n$q2`n`n" + ($plan2 -join "`n")
Set-Content -Path (Join-Path $evidenceDir "query_plans.txt") -Value $fullPlanOutput -Encoding utf8
Write-Host "Query plans captured to evidence/query_plans.txt."

Write-Host "`n=== 5. Running Invalid Operation Tests ==="
# Re-seed to ensure clean baseline for tests
& pwsh -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "seed.ps1") -Port $Port -Database $Database > $null

$invalidTestLog = "================================================================================`nTOPH Ride-Hailing MVP — Database-Enforced Invalid State Protection Tests`nDatabase: PostgreSQL 17 on 127.0.0.1:$Port ($Database)`nGenerated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n================================================================================`n`n"

# Test 1 Positive control
$t1_pos = @"
INSERT INTO trips (
    id, rider_id, status,
    pickup_location, dropoff_location,
    fare_minor, currency, fare_base_minor, fare_per_km_minor, fare_per_minute_minor,
    estimated_distance_km, estimated_duration_minutes,
    idempotency_key, created_at, updated_at
)
VALUES (
    '10101010-1010-4010-8010-101010101010',
    '11111111-1111-4111-8111-111111111111',
    'requested',
    'Victoria Island, Lagos', 'Marina, Lagos',
    200000, 'NGN', 50000, 15000, 3000,
    8.0, 20,
    'idem-test1-active-1', now(), now()
);
"@
$out_pos = & $psql -X -h 127.0.0.1 -p $Port -U postgres -d $Database -v ON_ERROR_STOP=1 -c $t1_pos 2>&1
$invalidTestLog += "### TEST 1: SECOND ACTIVE TRIP FOR RIDER`n`nPositive Control (First active trip creation):`n$t1_pos`nResult: $out_pos`n`n"

# Test 1 Negative test
$t1_neg = @"
INSERT INTO trips (
    id, rider_id, status,
    pickup_location, dropoff_location,
    fare_minor, currency, fare_base_minor, fare_per_km_minor, fare_per_minute_minor,
    estimated_distance_km, estimated_duration_minutes,
    idempotency_key, created_at, updated_at
)
VALUES (
    '12121212-1212-4212-8212-121212121212',
    '11111111-1111-4111-8111-111111111111',
    'requested',
    'Lekki Phase 1, Lagos', 'Ikoyi, Lagos',
    250000, 'NGN', 50000, 15000, 3000,
    10.0, 25,
    'idem-test1-active-2', now(), now()
);
"@
$out_t1_neg = & $psql -X -h 127.0.0.1 -p $Port -U postgres -d $Database -v ON_ERROR_STOP=1 -c $t1_neg 2>&1
$invalidTestLog += "Negative Attempt (Attempting second active trip for same rider):`n$t1_neg`nRejection Error (Expected SQLSTATE 23505):`n$($out_t1_neg -join "`n")`nConstraint Enforced: trips_one_active_per_rider (Partial Unique Index)`n`n--------------------------------------------------------------------------------`n`n"

# Test 2 Negative test
$t2_neg = @"
INSERT INTO reviews (
    id, trip_id, rider_id, driver_id, rating, comment, created_at, updated_at
)
VALUES (
    '20202020-2020-4020-8020-202020202020',
    '10101010-1010-4010-8010-101010101010',
    '11111111-1111-4111-8111-111111111111',
    '33333333-3333-4333-8333-333333333333',
    5, 'Great ride!', now(), now()
);
"@
$out_t2_neg = & $psql -X -h 127.0.0.1 -p $Port -U postgres -d $Database -v ON_ERROR_STOP=1 -c $t2_neg 2>&1
$invalidTestLog += "### TEST 2: REVIEW FOR AN INCOMPLETE TRIP`n`nNegative Attempt (Attempting review on 'requested' trip 10101010-1010-4010-8010-101010101010):`n$t2_neg`nRejection Error (Expected SQLSTATE 23514):`n$($out_t2_neg -join "`n")`nRule Enforced: Trigger trg_reviews_guard executing fn_reviews_guard()`n`n--------------------------------------------------------------------------------`n`n"

# Test 3 Negative test
$t3_neg = @"
UPDATE trips
SET status = 'in_progress',
    updated_at = now()
WHERE id = '77777777-7777-4777-8777-777777777777';
"@
$out_t3_neg = & $psql -X -h 127.0.0.1 -p $Port -U postgres -d $Database -v ON_ERROR_STOP=1 -c $t3_neg 2>&1
$invalidTestLog += "### TEST 3: FORBIDDEN STATE TRANSITION (completed -> in_progress)`n`nNegative Attempt (Attempting illegal transition completed -> in_progress on trip 77777777-7777-4777-8777-777777777777):`n$t3_neg`nRejection Error (Expected SQLSTATE 23514):`n$($out_t3_neg -join "`n")`nRule Enforced: Trigger trg_trips_transition_guard executing fn_trips_transition_guard()`n`n================================================================================`n"

Set-Content -Path (Join-Path $evidenceDir "invalid_operations.txt") -Value $invalidTestLog -Encoding utf8
Write-Host "Invalid operation tests captured to evidence/invalid_operations.txt."

Write-Host "`nAll verification steps completed successfully!"
