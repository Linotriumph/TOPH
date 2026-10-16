# TOPH — Ride-Hailing MVP: API Design & Schema Proof

TOPH is an on-demand urban ride-hailing platform design (starting in Lagos and Abuja, Nigeria). This repository contains the API design document, the PostgreSQL schema implementing it, and a reproducible verification harness that proves the database rejects every invalid state.

Full design write-up: [DOCUMENTATION.md](DOCUMENTATION.md).

## What's Inside

| Path | Purpose |
| :--- | :--- |
| `DOCUMENTATION.md` | Product requirements, entity model, 7 hard design questions, API contracts, trade-offs |
| `db/migrations/0001_init_schema.sql` | Complete schema: 6 tables, partial unique indexes, state-machine guards |
| `db/setup_cluster.ps1` | Creates/start an isolated local PostgreSQL 17 cluster on port `5433` |
| `db/migrate.ps1` | Creates the `toph` database and applies migrations transactionally |
| `db/seed.ps1` | Seeds 102 riders, 52 drivers, 52 vehicles, 316 trips, 301 payments, 151 reviews |
| `db/queries.sql` | The 5 primary user-action queries |
| `db/invalid_operations.sql` | Operations the schema must reject (with positive controls) |
| `db/run_proofs.ps1` | Runs everything and writes evidence to `evidence/` |
| `evidence/` | Captured proof: query plans, schema inventory, rejection errors |

## Data Model

Six entities: `riders`, `drivers`, `vehicles`, `trips`, `payments`, `reviews` — with a 5-state trip lifecycle (`requested → accepted → in_progress → completed | cancelled`).

Integrity is enforced in the database itself, not only the API:

- **One active trip per rider/driver** — partial unique indexes (`SQLSTATE 23505`)
- **Legal state transitions only** — `trg_trips_transition_guard` blocks backwards jumps (`SQLSTATE 23514`)
- **Immutable fare snapshots** — agreed fare frozen at request time; driver rate changes never reprice history
- **Payments must equal the fare** — composite FK `payments(trip_id, amount_minor, currency) → trips(id, fare_minor, currency)`
- **Reviews only for completed trips by the actual rider** — `trg_reviews_guard`
- **Money as integer minor units (kobo)** — floats are mathematically impossible

## Prerequisites

- Windows with PowerShell 7 (`pwsh`)
- PostgreSQL 17 binaries at `C:\Program Files\PostgreSQL\17\bin`

## Quick Start

```powershell
pwsh -ExecutionPolicy Bypass -File db/setup_cluster.ps1   # cluster on 127.0.0.1:5433
pwsh -ExecutionPolicy Bypass -File db/migrate.ps1         # apply schema
pwsh -ExecutionPolicy Bypass -File db/seed.ps1            # load test data
pwsh -ExecutionPolicy Bypass -File db/run_proofs.ps1      # run proofs -> evidence/
```

Stop the sandbox cluster when done:

```powershell
& "C:\Program Files\PostgreSQL\17\bin\pg_ctl.exe" -D .pgdata stop
```

## Verified Results

- Available-trips FIFO queue: index scan on `trips_available_idx`, **0.131 ms**
- Rider trip history: bitmap index scan on `trips_rider_history_idx`, **0.350 ms**
- Duplicate active trip, review on an incomplete trip, and `completed → in_progress` are all rejected with full error evidence in `evidence/invalid_operations.txt`

## Notes

The sandbox cluster (`.pgdata/`, port 5433, trust auth) exists because the host machine's PostgreSQL service on port 5432 is not available to this project. It is disposable and git-ignored.
