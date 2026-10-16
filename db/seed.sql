-- ============================================================================
-- TOPH ride-hailing MVP — Reproducible Seed Dataset
-- Generates deterministic, representative data for query planning and testing.
-- Run with: psql -h 127.0.0.1 -p 5433 -U postgres -d toph -f db/seed.sql
-- ============================================================================

BEGIN;

-- Clean existing data
TRUNCATE TABLE reviews, payments, trips, vehicles, drivers, riders CASCADE;

-- ----------------------------------------------------------------------------
-- 1. Known fixed actors for deterministic testing & queries
-- ----------------------------------------------------------------------------
-- Fixed Rider 1 (Primary test rider)
INSERT INTO riders (id, full_name, email, phone, created_at, updated_at)
VALUES (
    '11111111-1111-4111-8111-111111111111',
    'Amaka Eze',
    'amaka.eze@example.com',
    '+2348011112222',
    now() - interval '30 days',
    now() - interval '30 days'
);

-- Fixed Rider 2 (Second test rider)
INSERT INTO riders (id, full_name, email, phone, created_at, updated_at)
VALUES (
    '22222222-2222-4222-8222-222222222222',
    'Babajide Cole',
    'babajide.cole@example.com',
    '+2348022223333',
    now() - interval '25 days',
    now() - interval '25 days'
);

-- Fixed Driver 1 (Primary test driver)
INSERT INTO drivers (id, full_name, phone, licence_number, base_fare_minor, per_km_rate_minor, per_minute_rate_minor, rate_currency, created_at, updated_at)
VALUES (
    '33333333-3333-4333-8333-333333333333',
    'Chinedu Okeke',
    '+2348033334444',
    'DRV-LAG-1092',
    50000,   -- 500.00 NGN base
    15000,   -- 150.00 NGN / km
    3000,    -- 30.00 NGN / min
    'NGN',
    now() - interval '60 days',
    now() - interval '60 days'
);

-- Fixed Driver 2
INSERT INTO drivers (id, full_name, phone, licence_number, base_fare_minor, per_km_rate_minor, per_minute_rate_minor, rate_currency, created_at, updated_at)
VALUES (
    '44444444-4444-4444-8444-444444444444',
    'Damilola Adeleke',
    '+2348044445555',
    'DRV-ABJ-8821',
    60000,
    18000,
    3500,
    'NGN',
    now() - interval '45 days',
    now() - interval '45 days'
);

-- Fixed Vehicle 1 (assigned to Driver 1)
INSERT INTO vehicles (id, driver_id, registration, make, model, colour, manufacture_year, is_active, created_at, updated_at)
VALUES (
    '55555555-5555-4555-8555-555555555555',
    '33333333-3333-4333-8333-333333333333',
    'KJA-102-AA',
    'Toyota',
    'Corolla',
    'Silver',
    2018,
    true,
    now() - interval '50 days',
    now() - interval '50 days'
);

-- Fixed Vehicle 2 (assigned to Driver 2)
INSERT INTO vehicles (id, driver_id, registration, make, model, colour, manufacture_year, is_active, created_at, updated_at)
VALUES (
    '66666666-6666-4666-8666-666666666666',
    '44444444-4444-4444-8444-444444444444',
    'RSH-409-BB',
    'Hyundai',
    'Elantra',
    'Midnight Blue',
    2020,
    true,
    now() - interval '40 days',
    now() - interval '40 days'
);

-- ----------------------------------------------------------------------------
-- 2. Bulk Seed: Riders (100 riders)
-- ----------------------------------------------------------------------------
INSERT INTO riders (id, full_name, email, phone, created_at, updated_at)
SELECT
    gen_random_uuid(),
    'Rider ' || i,
    'rider' || i || '@example.com',
    '+23481' || lpad(i::text, 8, '0'),
    now() - (interval '1 day' * (100 - i)),
    now() - (interval '1 day' * (100 - i))
FROM generate_series(3, 102) AS i;

-- ----------------------------------------------------------------------------
-- 3. Bulk Seed: Drivers and Vehicles (50 drivers with 1 active vehicle each)
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    v_driver_id uuid;
    v_idx integer;
BEGIN
    FOR v_idx IN 5..54 LOOP
        v_driver_id := gen_random_uuid();
        INSERT INTO drivers (id, full_name, phone, licence_number, base_fare_minor, per_km_rate_minor, per_minute_rate_minor, rate_currency, created_at, updated_at)
        VALUES (
            v_driver_id,
            'Driver ' || v_idx,
            '+23489' || lpad(v_idx::text, 8, '0'),
            'LIC-' || lpad(v_idx::text, 5, '0'),
            50000 + (v_idx * 500),
            15000 + (v_idx * 100),
            3000 + (v_idx * 50),
            'NGN',
            now() - interval '90 days',
            now() - interval '90 days'
        );

        INSERT INTO vehicles (id, driver_id, registration, make, model, colour, manufacture_year, is_active, created_at, updated_at)
        VALUES (
            gen_random_uuid(),
            v_driver_id,
            'REG-' || lpad(v_idx::text, 4, '0'),
            'Toyota',
            'Camry',
            'Black',
            2019,
            true,
            now() - interval '85 days',
            now() - interval '85 days'
        );
    END LOOP;
END $$;

-- ----------------------------------------------------------------------------
-- 4. Seed Historical Completed Trips with Payments and Reviews
-- ----------------------------------------------------------------------------
-- Fixed Completed Trip 1 for Rider 1 with Driver 1
INSERT INTO trips (
    id, rider_id, driver_id, vehicle_id, status,
    pickup_location, dropoff_location,
    fare_minor, currency, fare_base_minor, fare_per_km_minor, fare_per_minute_minor,
    estimated_distance_km, estimated_duration_minutes,
    driver_name_snapshot, vehicle_registration_snapshot,
    idempotency_key,
    accepted_at, started_at, completed_at, created_at, updated_at
)
VALUES (
    '77777777-7777-4777-8777-777777777777',
    '11111111-1111-4111-8111-111111111111',
    '33333333-3333-4333-8333-333333333333',
    '55555555-5555-4555-8555-555555555555',
    'completed',
    '14 Admiralty Way, Lekki Phase 1, Lagos',
    'Ozone Cinemas, Commercial Ave, Yaba, Lagos',
    350000, 'NGN', 50000, 15000, 3000,
    14.50, 42,
    'Chinedu Okeke', 'KJA-102-AA',
    'idem-trip-completed-001',
    now() - interval '5 days' + interval '2 minutes',
    now() - interval '5 days' + interval '10 minutes',
    now() - interval '5 days' + interval '52 minutes',
    now() - interval '5 days',
    now() - interval '5 days' + interval '52 minutes'
);

-- Payment for Completed Trip 1
INSERT INTO payments (
    id, trip_id, amount_minor, currency, method, status,
    provider_reference, idempotency_key, processed_at, created_at, updated_at
)
VALUES (
    '88888888-8888-4888-8888-888888888888',
    '77777777-7777-4777-8777-777777777777',
    350000, 'NGN', 'card', 'successful',
    'pay_ref_flw_991823719', 'idem-pay-001',
    now() - interval '5 days' + interval '53 minutes',
    now() - interval '5 days' + interval '52 minutes',
    now() - interval '5 days' + interval '53 minutes'
);

-- Review for Completed Trip 1
INSERT INTO reviews (
    id, trip_id, rider_id, driver_id, rating, comment, created_at, updated_at
)
VALUES (
    '99999999-9999-4999-8999-999999999999',
    '77777777-7777-4777-8777-777777777777',
    '11111111-1111-4111-8111-111111111111',
    '33333333-3333-4333-8333-333333333333',
    5,
    'Excellent driving, very polite and took the quickest route via the link bridge.',
    now() - interval '5 days' + interval '55 minutes',
    now() - interval '5 days' + interval '55 minutes'
);

-- ----------------------------------------------------------------------------
-- 5. Bulk Completed Historical Trips (300 trips to ensure index use on query plans)
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    v_riders uuid[];
    v_drivers uuid[];
    v_r_id uuid;
    v_d_id uuid;
    v_v_id uuid;
    v_d_name text;
    v_v_reg text;
    v_trip_id uuid;
    v_fare integer;
    v_created timestamptz;
    i integer;
BEGIN
    SELECT array_agg(id) INTO v_riders FROM riders;
    SELECT array_agg(id) INTO v_drivers FROM drivers WHERE id <> '33333333-3333-4333-8333-333333333333';

    FOR i IN 1..300 LOOP
        v_r_id := v_riders[1 + (i % array_length(v_riders, 1))];
        v_d_id := v_drivers[1 + (i % array_length(v_drivers, 1))];

        SELECT id, registration INTO v_v_id, v_v_reg FROM vehicles WHERE driver_id = v_d_id LIMIT 1;
        SELECT full_name INTO v_d_name FROM drivers WHERE id = v_d_id;

        v_trip_id := gen_random_uuid();
        v_fare := 250000 + (i * 1000);
        v_created := now() - (interval '1 hour' * (350 - i));

        INSERT INTO trips (
            id, rider_id, driver_id, vehicle_id, status,
            pickup_location, dropoff_location,
            fare_minor, currency, fare_base_minor, fare_per_km_minor, fare_per_minute_minor,
            estimated_distance_km, estimated_duration_minutes,
            driver_name_snapshot, vehicle_registration_snapshot,
            idempotency_key,
            accepted_at, started_at, completed_at, created_at, updated_at
        )
        VALUES (
            v_trip_id, v_r_id, v_d_id, v_v_id, 'completed',
            'Pickup Spot ' || i || ', Lagos', 'Dropoff Spot ' || i || ', Lagos',
            v_fare, 'NGN', 50000, 15000, 3000,
            10.0 + (i % 20), 20 + (i % 40),
            v_d_name, v_v_reg,
            'idem-hist-trip-' || i,
            v_created + interval '2 minutes',
            v_created + interval '8 minutes',
            v_created + interval '35 minutes',
            v_created,
            v_created + interval '35 minutes'
        );

        -- Payment
        INSERT INTO payments (
            id, trip_id, amount_minor, currency, method, status,
            provider_reference, idempotency_key, processed_at, created_at, updated_at
        )
        VALUES (
            gen_random_uuid(), v_trip_id, v_fare, 'NGN', 'card', 'successful',
            'ref_hist_' || i, 'idem-hist-pay-' || i,
            v_created + interval '36 minutes', v_created + interval '35 minutes', v_created + interval '36 minutes'
        );

        -- Review for ~50% of completed trips
        IF i % 2 = 0 THEN
            INSERT INTO reviews (
                id, trip_id, rider_id, driver_id, rating, comment, created_at, updated_at
            )
            VALUES (
                gen_random_uuid(), v_trip_id, v_r_id, v_d_id,
                4 + (i % 2), 'Smooth ride #' || i,
                v_created + interval '40 minutes', v_created + interval '40 minutes'
            );
        END IF;
    END LOOP;
END $$;

-- ----------------------------------------------------------------------------
-- 6. Current Pending Trips in 'requested' state (Available pool for Action 2)
-- ----------------------------------------------------------------------------
-- 15 requested trips currently available in FIFO order
DO $$
DECLARE
    v_riders uuid[];
    i integer;
BEGIN
    -- Select riders without an active trip, excluding fixed test actors
    SELECT array_agg(id) INTO v_riders FROM riders
    WHERE id NOT IN ('11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222222')
      AND id NOT IN (SELECT rider_id FROM trips WHERE status IN ('requested','accepted','in_progress'));

    FOR i IN 1..15 LOOP
        INSERT INTO trips (
            id, rider_id, status,
            pickup_location, dropoff_location,
            fare_minor, currency, fare_base_minor, fare_per_km_minor, fare_per_minute_minor,
            estimated_distance_km, estimated_duration_minutes,
            idempotency_key, created_at, updated_at
        )
        VALUES (
            gen_random_uuid(),
            v_riders[i],
            'requested',
            'Victoria Island Location #' || i || ', Lagos',
            'Ikeja Mall Location #' || i || ', Lagos',
            320000 + (i * 5000), 'NGN', 50000, 15000, 3000,
            12.5 + (i * 0.5), 35 + i,
            'idem-req-pool-' || i,
            now() - (interval '1 minute' * (30 - i)),
            now() - (interval '1 minute' * (30 - i))
        );
    END LOOP;
END $$;

COMMIT;
