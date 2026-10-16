-- ============================================================================
-- TOPH ride-hailing MVP — schema migration 0001
-- Target: PostgreSQL 17 (works on 13+; gen_random_uuid() is core since PG13)
--
-- Implements the data model documented in DOCUMENTATION.md:
--   entities: riders, drivers, vehicles, trips, payments, reviews
--   every constraint named here is documented in section 3.6 of that document.
--
-- Conventions:
--   * money            integer minor units + ISO-4217 currency code (never float)
--   * ids              UUID v4 via gen_random_uuid() (non-sequential, unguessable)
--   * time             timestamptz, stored UTC
--   * created_at/updated_at on every entity; deleted_at only where soft deletion
--     is a supported lifecycle (riders, drivers, vehicles, reviews)
--
-- Applied automatically by db/migrate.ps1 inside a single transaction.
-- Safe to run once against an empty database.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- riders
-- ----------------------------------------------------------------------------
CREATE TABLE riders (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    full_name   text        NOT NULL,
    email       text        NOT NULL,
    phone       text        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    deleted_at  timestamptz,

    CONSTRAINT riders_email_key             UNIQUE (email),
    CONSTRAINT riders_phone_key             UNIQUE (phone),
    CONSTRAINT riders_full_name_shape       CHECK (length(btrim(full_name)) BETWEEN 2 AND 120),
    CONSTRAINT riders_email_lowercase       CHECK (email = lower(email)),
    CONSTRAINT riders_email_shape           CHECK (email ~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'),
    CONSTRAINT riders_phone_e164            CHECK (phone ~ '^\+[1-9][0-9]{7,14}$'),
    CONSTRAINT riders_deleted_after_created CHECK (deleted_at IS NULL OR deleted_at >= created_at)
);

-- ----------------------------------------------------------------------------
-- drivers
-- Driver rate fields are the driver's own (future) earnings rates. They are
-- NOT used to re-price historical trips; see the fare snapshot on trips and
-- DOCUMENTATION.md sections 3.1 and 3.2.
-- ----------------------------------------------------------------------------
CREATE TABLE drivers (
    id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    full_name             text        NOT NULL,
    phone                 text        NOT NULL,
    licence_number        text        NOT NULL,
    base_fare_minor       integer     NOT NULL,
    per_km_rate_minor     integer     NOT NULL,
    per_minute_rate_minor integer     NOT NULL,
    rate_currency         text        NOT NULL DEFAULT 'NGN',
    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now(),
    deleted_at            timestamptz,

    CONSTRAINT drivers_phone_key             UNIQUE (phone),
    CONSTRAINT drivers_licence_key           UNIQUE (licence_number),
    CONSTRAINT drivers_full_name_shape       CHECK (length(btrim(full_name)) BETWEEN 2 AND 120),
    CONSTRAINT drivers_phone_e164            CHECK (phone ~ '^\+[1-9][0-9]{7,14}$'),
    CONSTRAINT drivers_licence_shape         CHECK (licence_number ~ '^[A-Z0-9-]{3,20}$'),
    CONSTRAINT drivers_base_fare_nonnegative CHECK (base_fare_minor >= 0),
    CONSTRAINT drivers_per_km_nonnegative    CHECK (per_km_rate_minor >= 0),
    CONSTRAINT drivers_per_minute_nonnegative CHECK (per_minute_rate_minor >= 0),
    CONSTRAINT drivers_rate_currency_iso4217 CHECK (rate_currency ~ '^[A-Z]{3}$'),
    CONSTRAINT drivers_deleted_after_created CHECK (deleted_at IS NULL OR deleted_at >= created_at)
);

-- ----------------------------------------------------------------------------
-- vehicles
-- A driver may register several vehicles over time; at most one ACTIVE
-- (non-deleted) vehicle per driver (partial unique index below). A trip
-- snapshots the vehicle registration at acceptance, so later vehicle edits
-- cannot change historical trip records.
-- ----------------------------------------------------------------------------
CREATE TABLE vehicles (
    id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    driver_id        uuid        NOT NULL REFERENCES drivers (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    registration     text        NOT NULL,
    make             text        NOT NULL,
    model            text        NOT NULL,
    colour           text,
    manufacture_year integer     NOT NULL,
    is_active        boolean     NOT NULL DEFAULT true,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    deleted_at       timestamptz,

    -- Plain unique: a registration plate is unique for the lifetime of the
    -- database, including soft-deleted rows (documented trade-off: re-plating
    -- a sold vehicle requires a retention-approved hard delete).
    CONSTRAINT vehicles_registration_key UNIQUE (registration),
    -- Redundant against the PK but required as the target of the
    -- trips (vehicle_id, driver_id) composite FK that proves the assigned
    -- vehicle actually belongs to the assigned driver.
    CONSTRAINT vehicles_id_driver_key    UNIQUE (id, driver_id),
    CONSTRAINT vehicles_registration_shape CHECK (registration ~ '^[A-Z0-9-]{3,12}$'),
    CONSTRAINT vehicles_make_shape         CHECK (length(btrim(make))  BETWEEN 1 AND 60),
    CONSTRAINT vehicles_model_shape        CHECK (length(btrim(model)) BETWEEN 1 AND 60),
    CONSTRAINT vehicles_colour_shape       CHECK (colour IS NULL OR length(btrim(colour)) BETWEEN 1 AND 40),
    CONSTRAINT vehicles_year_range         CHECK (manufacture_year BETWEEN 1980 AND 2100),
    CONSTRAINT vehicles_deleted_after_created CHECK (deleted_at IS NULL OR deleted_at >= created_at)
);

CREATE UNIQUE INDEX vehicles_one_active_per_driver
    ON vehicles (driver_id)
    WHERE is_active AND deleted_at IS NULL;

-- ----------------------------------------------------------------------------
-- trips
-- The central entity. Status lifecycle:
--   requested -> accepted -> in_progress -> completed
--   requested -> cancelled, accepted -> cancelled
-- Transition legality is enforced by trigger trg_trips_transition_guard
-- (a CHECK constraint can only restrict values, not transitions).
--
-- Fare snapshot: fare_minor/currency plus the quote components are copied onto
-- the row when the trip is requested and are immutable afterwards (trigger).
-- Price history never depends on current driver rates.
-- ----------------------------------------------------------------------------
CREATE TABLE trips (
    id                          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    rider_id                    uuid        NOT NULL REFERENCES riders (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    driver_id                   uuid        REFERENCES drivers (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    vehicle_id                  uuid,
    status                      text        NOT NULL DEFAULT 'requested',
    pickup_location             text        NOT NULL,
    dropoff_location            text        NOT NULL,
    fare_minor                  integer     NOT NULL,
    currency                    text        NOT NULL DEFAULT 'NGN',
    fare_base_minor             integer     NOT NULL,
    fare_per_km_minor           integer     NOT NULL,
    fare_per_minute_minor       integer     NOT NULL,
    estimated_distance_km       numeric(7,2) NOT NULL,
    estimated_duration_minutes  integer     NOT NULL,
    driver_name_snapshot        text,
    vehicle_registration_snapshot text,
    idempotency_key             text,
    accepted_at                 timestamptz,
    started_at                  timestamptz,
    completed_at                timestamptz,
    cancelled_at                timestamptz,
    cancellation_reason         text,
    created_at                  timestamptz NOT NULL DEFAULT now(),
    updated_at                  timestamptz NOT NULL DEFAULT now(),

    -- Lets payments carry a composite FK (trip_id, amount_minor, currency) so
    -- the database itself proves a payment amount equals the agreed fare.
    CONSTRAINT trips_id_fare_currency_key UNIQUE (id, fare_minor, currency),

    -- Composite FK: the assigned vehicle must belong to the assigned driver.
    CONSTRAINT trips_vehicle_driver_fkey
        FOREIGN KEY (vehicle_id, driver_id)
        REFERENCES vehicles (id, driver_id) ON UPDATE RESTRICT ON DELETE RESTRICT,

    CONSTRAINT trips_idempotency_key_key UNIQUE (idempotency_key),

    CONSTRAINT trips_status_allowed CHECK (status IN ('requested','accepted','in_progress','completed','cancelled')),

    CONSTRAINT trips_fare_nonnegative           CHECK (fare_minor >= 0),
    CONSTRAINT trips_fare_base_nonnegative      CHECK (fare_base_minor >= 0),
    CONSTRAINT trips_fare_per_km_nonnegative    CHECK (fare_per_km_minor >= 0),
    CONSTRAINT trips_fare_per_minute_nonnegative CHECK (fare_per_minute_minor >= 0),
    CONSTRAINT trips_currency_iso4217           CHECK (currency ~ '^[A-Z]{3}$'),

    CONSTRAINT trips_pickup_shape   CHECK (length(btrim(pickup_location))  BETWEEN 3 AND 500),
    CONSTRAINT trips_dropoff_shape  CHECK (length(btrim(dropoff_location)) BETWEEN 3 AND 500),

    CONSTRAINT trips_estimate_sane
        CHECK (estimated_distance_km > 0 AND estimated_distance_km <= 1000
               AND estimated_duration_minutes BETWEEN 1 AND 1440),

    CONSTRAINT trips_idempotency_key_shape
        CHECK (idempotency_key IS NULL OR length(idempotency_key) BETWEEN 8 AND 128),

    CONSTRAINT trips_timestamps_ordered
        CHECK ((accepted_at  IS NULL OR accepted_at  >= created_at)
               AND (started_at  IS NULL OR (accepted_at  IS NOT NULL AND started_at  >= accepted_at))
               AND (completed_at IS NULL OR (started_at   IS NOT NULL AND completed_at >= started_at))
               AND (cancelled_at IS NULL OR cancelled_at >= created_at)),

    CONSTRAINT trips_cancellation_reason_shape
        CHECK (cancellation_reason IS NULL
               OR (status = 'cancelled' AND length(btrim(cancellation_reason)) BETWEEN 1 AND 500)),

    -- The single source of truth for which combination of status, assignment
    -- fields and lifecycle timestamps is legal on a row.
    CONSTRAINT trips_state_consistency CHECK (
        CASE status
            WHEN 'requested' THEN
                driver_id IS NULL AND vehicle_id IS NULL
                AND accepted_at IS NULL AND started_at IS NULL
                AND completed_at IS NULL AND cancelled_at IS NULL
                AND driver_name_snapshot IS NULL AND vehicle_registration_snapshot IS NULL
            WHEN 'accepted' THEN
                driver_id IS NOT NULL AND vehicle_id IS NOT NULL
                AND accepted_at IS NOT NULL AND started_at IS NULL
                AND completed_at IS NULL AND cancelled_at IS NULL
                AND driver_name_snapshot IS NOT NULL AND vehicle_registration_snapshot IS NOT NULL
            WHEN 'in_progress' THEN
                driver_id IS NOT NULL AND vehicle_id IS NOT NULL
                AND accepted_at IS NOT NULL AND started_at IS NOT NULL
                AND completed_at IS NULL AND cancelled_at IS NULL
                AND driver_name_snapshot IS NOT NULL AND vehicle_registration_snapshot IS NOT NULL
            WHEN 'completed' THEN
                driver_id IS NOT NULL AND vehicle_id IS NOT NULL
                AND accepted_at IS NOT NULL AND started_at IS NOT NULL
                AND completed_at IS NOT NULL AND cancelled_at IS NULL
                AND driver_name_snapshot IS NOT NULL AND vehicle_registration_snapshot IS NOT NULL
            WHEN 'cancelled' THEN
                completed_at IS NULL AND cancelled_at IS NOT NULL
                AND ((driver_id IS NULL AND vehicle_id IS NULL
                      AND driver_name_snapshot IS NULL AND vehicle_registration_snapshot IS NULL)
                     OR
                     (driver_id IS NOT NULL AND vehicle_id IS NOT NULL
                      AND driver_name_snapshot IS NOT NULL AND vehicle_registration_snapshot IS NOT NULL)
                     AND accepted_at IS NOT NULL)
            ELSE false
        END
    )
);

-- "Active" is defined consistently as requested | accepted | in_progress.
CREATE UNIQUE INDEX trips_one_active_per_rider
    ON trips (rider_id)
    WHERE status IN ('requested','accepted','in_progress');

CREATE UNIQUE INDEX trips_one_active_per_driver
    ON trips (driver_id)
    WHERE driver_id IS NOT NULL AND status IN ('requested','accepted','in_progress');

-- ----------------------------------------------------------------------------
-- payments
-- A trip can have many payment attempts; at most one may be successful
-- (partial unique index). Attempt amount must equal the trip's agreed fare:
-- enforced by the composite FK to trips (id, fare_minor, currency).
-- Transitions (pending -> successful | failed; terminal afterwards) are
-- enforced by trigger trg_payments_transition_guard.
-- ----------------------------------------------------------------------------
CREATE TABLE payments (
    id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    trip_id            uuid        NOT NULL,
    amount_minor       integer     NOT NULL,
    currency           text        NOT NULL DEFAULT 'NGN',
    method             text        NOT NULL,
    status             text        NOT NULL DEFAULT 'pending',
    provider_reference text,
    failure_reason     text,
    idempotency_key    text        NOT NULL,
    processed_at       timestamptz,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT payments_trip_amount_fkey
        FOREIGN KEY (trip_id, amount_minor, currency)
        REFERENCES trips (id, fare_minor, currency) ON UPDATE RESTRICT ON DELETE RESTRICT,

    CONSTRAINT payments_idempotency_key_key UNIQUE (idempotency_key),

    CONSTRAINT payments_status_allowed CHECK (status IN ('pending','successful','failed')),
    CONSTRAINT payments_method_allowed CHECK (method IN ('card','bank_transfer','cash')),
    CONSTRAINT payments_amount_nonnegative CHECK (amount_minor >= 0),
    CONSTRAINT payments_currency_iso4217    CHECK (currency ~ '^[A-Z]{3}$'),
    CONSTRAINT payments_idempotency_key_shape CHECK (length(idempotency_key) BETWEEN 8 AND 128),
    CONSTRAINT payments_provider_reference_shape
        CHECK (provider_reference IS NULL OR length(btrim(provider_reference)) BETWEEN 1 AND 128),
    CONSTRAINT payments_failure_reason_shape
        CHECK (failure_reason IS NULL OR length(btrim(failure_reason)) BETWEEN 1 AND 500),
    -- A failed attempt must say why; only failed attempts carry a reason.
    CONSTRAINT payments_failure_reason_consistency
        CHECK ((status = 'failed') = (failure_reason IS NOT NULL)),
    -- processed_at is null while pending and set exactly once on settlement.
    CONSTRAINT payments_processed_at_consistency
        CHECK ((status = 'pending') = (processed_at IS NULL))
);

CREATE UNIQUE INDEX payments_one_success_per_trip
    ON payments (trip_id)
    WHERE status = 'successful';

-- ----------------------------------------------------------------------------
-- reviews
-- At most one review per trip (UNIQUE). Rider and driver must match the trip
-- and the trip must be completed: enforced by trigger trg_reviews_guard.
-- ----------------------------------------------------------------------------
CREATE TABLE reviews (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    trip_id    uuid        NOT NULL REFERENCES trips (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    rider_id   uuid        NOT NULL REFERENCES riders (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    driver_id  uuid        NOT NULL REFERENCES drivers (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    rating     smallint    NOT NULL,
    comment    text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,

    CONSTRAINT reviews_trip_key UNIQUE (trip_id),
    CONSTRAINT reviews_rating_range CHECK (rating BETWEEN 1 AND 5),
    CONSTRAINT reviews_comment_shape CHECK (comment IS NULL OR length(comment) <= 2000),
    CONSTRAINT reviews_deleted_after_created CHECK (deleted_at IS NULL OR deleted_at >= created_at)
);

-- ----------------------------------------------------------------------------
-- Supporting indexes (justified against the five primary actions in
-- DOCUMENTATION.md section 3.7; do not add more without a measured query).
-- ----------------------------------------------------------------------------

-- Action 2: list available trip requests in FIFO order.
CREATE INDEX trips_available_idx
    ON trips (created_at)
    WHERE status = 'requested';

-- Action 1/4: a rider's trip history, newest first.
CREATE INDEX trips_rider_history_idx
    ON trips (rider_id, created_at DESC, id DESC);

-- Action 2/3: a driver's own assigned/completed trips, newest first.
CREATE INDEX trips_driver_history_idx
    ON trips (driver_id, created_at DESC, id DESC)
    WHERE driver_id IS NOT NULL;

-- Action 4: payment attempts for one trip, newest first.
CREATE INDEX payments_trip_idx
    ON payments (trip_id, created_at DESC, id DESC);

-- Driver profile: rating aggregate (GET /api/v1/drivers/{driverId}).
CREATE INDEX reviews_driver_idx
    ON reviews (driver_id, created_at DESC);

-- ----------------------------------------------------------------------------
-- updated_at maintenance
-- ----------------------------------------------------------------------------
CREATE FUNCTION fn_set_updated_at() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_riders_touch   BEFORE UPDATE ON riders   FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_drivers_touch  BEFORE UPDATE ON drivers  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_vehicles_touch BEFORE UPDATE ON vehicles FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_trips_touch    BEFORE UPDATE ON trips    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_payments_touch BEFORE UPDATE ON payments FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_reviews_touch  BEFORE UPDATE ON reviews  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- ----------------------------------------------------------------------------
-- trips: state-transition and immutability guard
-- ----------------------------------------------------------------------------
CREATE FUNCTION fn_trips_transition_guard() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_allowed text[] := ARRAY[
        'requested>accepted',
        'requested>cancelled',
        'accepted>in_progress',
        'accepted>cancelled',
        'in_progress>completed'
    ];
BEGIN
    -- Core terms of the agreement are immutable for the lifetime of the row.
    IF NEW.id IS DISTINCT FROM OLD.id
       OR NEW.rider_id IS DISTINCT FROM OLD.rider_id
       OR NEW.pickup_location IS DISTINCT FROM OLD.pickup_location
       OR NEW.dropoff_location IS DISTINCT FROM OLD.dropoff_location
       OR NEW.fare_minor IS DISTINCT FROM OLD.fare_minor
       OR NEW.currency IS DISTINCT FROM OLD.currency
       OR NEW.fare_base_minor IS DISTINCT FROM OLD.fare_base_minor
       OR NEW.fare_per_km_minor IS DISTINCT FROM OLD.fare_per_km_minor
       OR NEW.fare_per_minute_minor IS DISTINCT FROM OLD.fare_per_minute_minor
       OR NEW.estimated_distance_km IS DISTINCT FROM OLD.estimated_distance_km
       OR NEW.estimated_duration_minutes IS DISTINCT FROM OLD.estimated_duration_minutes
       OR NEW.created_at IS DISTINCT FROM OLD.created_at
       OR NEW.idempotency_key IS DISTINCT FROM OLD.idempotency_key
    THEN
        RAISE EXCEPTION
            'trip %: the agreement (rider, route, agreed fare snapshot, idempotency key) is immutable',
            OLD.id
            USING ERRCODE = '23514';
    END IF;

    -- Assignment (driver, vehicle, snapshots) may only be set on acceptance.
    IF NEW.driver_id IS DISTINCT FROM OLD.driver_id
       OR NEW.vehicle_id IS DISTINCT FROM OLD.vehicle_id
       OR NEW.driver_name_snapshot IS DISTINCT FROM OLD.driver_name_snapshot
       OR NEW.vehicle_registration_snapshot IS DISTINCT FROM OLD.vehicle_registration_snapshot
    THEN
        IF NOT (OLD.status = 'requested' AND NEW.status = 'accepted') THEN
            RAISE EXCEPTION
                'trip %: driver/vehicle assignment is only allowed on requested -> accepted',
                OLD.id
                USING ERRCODE = '23514';
        END IF;
    END IF;

    IF NEW.status IS DISTINCT FROM OLD.status THEN
        IF NOT ((OLD.status || '>' || NEW.status) = ANY (v_allowed)) THEN
            RAISE EXCEPTION
                'trip %: invalid trip status transition from % to %',
                OLD.id, OLD.status, NEW.status
                USING ERRCODE = '23514';
        END IF;
    ELSE
        -- Lifecycle timestamps move only together with a status transition.
        IF NEW.accepted_at IS DISTINCT FROM OLD.accepted_at
           OR NEW.started_at IS DISTINCT FROM OLD.started_at
           OR NEW.completed_at IS DISTINCT FROM OLD.completed_at
           OR NEW.cancelled_at IS DISTINCT FROM OLD.cancelled_at
           OR NEW.cancellation_reason IS DISTINCT FROM OLD.cancellation_reason
        THEN
            RAISE EXCEPTION
                'trip %: lifecycle timestamps/reason change only with a status transition',
                OLD.id
                USING ERRCODE = '23514';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trips_transition_guard
    BEFORE UPDATE ON trips
    FOR EACH ROW EXECUTE FUNCTION fn_trips_transition_guard();

-- ----------------------------------------------------------------------------
-- payments: state-transition guard (pending -> successful | failed; terminal)
-- ----------------------------------------------------------------------------
CREATE FUNCTION fn_payments_transition_guard() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_allowed text[] := ARRAY['pending>successful', 'pending>failed'];
BEGIN
    IF NEW.id IS DISTINCT FROM OLD.id
       OR NEW.trip_id IS DISTINCT FROM OLD.trip_id
       OR NEW.amount_minor IS DISTINCT FROM OLD.amount_minor
       OR NEW.currency IS DISTINCT FROM OLD.currency
       OR NEW.method IS DISTINCT FROM OLD.method
       OR NEW.idempotency_key IS DISTINCT FROM OLD.idempotency_key
       OR NEW.created_at IS DISTINCT FROM OLD.created_at
    THEN
        RAISE EXCEPTION
            'payment %: core fields (trip, amount, currency, method, idempotency key) are immutable',
            OLD.id
            USING ERRCODE = '23514';
    END IF;

    IF OLD.status <> 'pending' THEN
        RAISE EXCEPTION
            'payment % is terminal (%): a % payment cannot be changed',
            OLD.id, OLD.status, OLD.status
            USING ERRCODE = '23514';
    END IF;

    IF NEW.status IS DISTINCT FROM OLD.status
       AND NOT ((OLD.status || '>' || NEW.status) = ANY (v_allowed))
    THEN
        RAISE EXCEPTION
            'payment %: invalid payment status transition from % to %',
            OLD.id, OLD.status, NEW.status
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_payments_transition_guard
    BEFORE UPDATE ON payments
    FOR EACH ROW EXECUTE FUNCTION fn_payments_transition_guard();

-- ----------------------------------------------------------------------------
-- payments: an attempt may only be recorded against a completed trip.
-- The row lock (FOR SHARE) also serialises this check against a concurrent
-- trip completion/cancellation of the same trip.
-- ----------------------------------------------------------------------------
CREATE FUNCTION fn_payments_trip_guard() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_status text;
BEGIN
    SELECT t.status INTO v_status
    FROM trips t
    WHERE t.id = NEW.trip_id
    FOR SHARE;

    IF NOT FOUND THEN
        RETURN NEW; -- the composite FK will reject the row with a clearer error
    END IF;

    IF v_status <> 'completed' THEN
        RAISE EXCEPTION
            'payment: trip % is % - a payment can only be recorded for a completed trip',
            NEW.trip_id, v_status
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_payments_trip_guard
    BEFORE INSERT ON payments
    FOR EACH ROW EXECUTE FUNCTION fn_payments_trip_guard();

-- ----------------------------------------------------------------------------
-- reviews: only the trip's rider, only for a completed trip, links immutable.
-- ----------------------------------------------------------------------------
CREATE FUNCTION fn_reviews_guard() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_status    text;
    v_rider_id  uuid;
    v_driver_id uuid;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW.trip_id IS DISTINCT FROM OLD.trip_id
           OR NEW.rider_id IS DISTINCT FROM OLD.rider_id
           OR NEW.driver_id IS DISTINCT FROM OLD.driver_id
        THEN
            RAISE EXCEPTION
                'review %: trip/rider/driver links are immutable',
                OLD.id
                USING ERRCODE = '23514';
        END IF;
    END IF;

    SELECT t.status, t.rider_id, t.driver_id
    INTO v_status, v_rider_id, v_driver_id
    FROM trips t
    WHERE t.id = NEW.trip_id;

    IF NOT FOUND THEN
        RETURN NEW; -- FK reports the missing trip
    END IF;

    IF v_status <> 'completed' THEN
        RAISE EXCEPTION
            'review: trip % is % - a review requires a completed trip',
            NEW.trip_id, v_status
            USING ERRCODE = '23514';
    END IF;

    IF v_rider_id <> NEW.rider_id THEN
        RAISE EXCEPTION
            'review: rider % does not match trip %''s rider %',
            NEW.rider_id, NEW.trip_id, v_rider_id
            USING ERRCODE = '23514';
    END IF;

    IF v_driver_id <> NEW.driver_id THEN
        RAISE EXCEPTION
            'review: driver % does not match trip %''s driver %',
            NEW.driver_id, NEW.trip_id, v_driver_id
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_reviews_guard
    BEFORE INSERT OR UPDATE ON reviews
    FOR EACH ROW EXECUTE FUNCTION fn_reviews_guard();

COMMIT;
