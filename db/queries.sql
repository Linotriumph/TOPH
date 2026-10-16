-- ============================================================================
-- TOPH ride-hailing MVP — Five Primary User Action Queries
-- Demonstrates the exact queries serving the five core requirements.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- ACTION 1: A rider requests a trip (and views their trip history)
-- ----------------------------------------------------------------------------
-- 1a. Insert new trip request
INSERT INTO trips (
    id, rider_id, status,
    pickup_location, dropoff_location,
    fare_minor, currency, fare_base_minor, fare_per_km_minor, fare_per_minute_minor,
    estimated_distance_km, estimated_duration_minutes,
    idempotency_key, created_at, updated_at
)
VALUES (
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    '22222222-2222-4222-8222-222222222222',
    'requested',
    'Plot 12, Victoria Island, Lagos',
    'Muritala Muhammed Airport Terminal 2, Ikeja, Lagos',
    480000, 'NGN', 60000, 18000, 3500,
    24.50, 55,
    'idem-trip-action1-001',
    now(), now()
);

-- 1b. Query rider's trip history (newest first, paging)
-- Serviced by index: trips_rider_history_idx ON trips (rider_id, created_at DESC, id DESC)
SELECT id, status, pickup_location, dropoff_location, fare_minor, currency,
       driver_name_snapshot, vehicle_registration_snapshot, created_at
FROM trips
WHERE rider_id = '22222222-2222-4222-8222-222222222222'
ORDER BY created_at DESC, id DESC
LIMIT 20;


-- ----------------------------------------------------------------------------
-- ACTION 2: A driver views available trip requests and accepts one
-- ----------------------------------------------------------------------------
-- 2a. Driver views available trip requests in FIFO order
-- Serviced by index: trips_available_idx ON trips (created_at) WHERE status = 'requested'
SELECT id, rider_id, pickup_location, dropoff_location, fare_minor, currency,
       estimated_distance_km, estimated_duration_minutes, created_at
FROM trips
WHERE status = 'requested'
ORDER BY created_at ASC
LIMIT 20;

-- 2b. Driver accepts the trip (atomic assignment with driver & vehicle snapshot)
-- Note: Vehicle ID '66666666-6666-4666-8666-666666666666' belongs to Driver '44444444-4444-4444-8444-444444444444'
UPDATE trips
SET status = 'accepted',
    driver_id = '44444444-4444-4444-8444-444444444444',
    vehicle_id = '66666666-6666-4666-8666-666666666666',
    driver_name_snapshot = 'Damilola Adeleke',
    vehicle_registration_snapshot = 'RSH-409-BB',
    accepted_at = now(),
    updated_at = now()
WHERE id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
  AND status = 'requested';


-- ----------------------------------------------------------------------------
-- ACTION 3: A driver starts and completes an accepted trip
-- ----------------------------------------------------------------------------
-- 3a. Driver starts the trip
UPDATE trips
SET status = 'in_progress',
    started_at = now(),
    updated_at = now()
WHERE id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
  AND status = 'accepted'
  AND driver_id = '44444444-4444-4444-8444-444444444444';

-- 3b. Driver completes the trip
UPDATE trips
SET status = 'completed',
    completed_at = now(),
    updated_at = now()
WHERE id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
  AND status = 'in_progress'
  AND driver_id = '44444444-4444-4444-8444-444444444444';


-- ----------------------------------------------------------------------------
-- ACTION 4: A rider records and views a payment for a trip
-- ----------------------------------------------------------------------------
-- 4a. Record payment attempt against completed trip
-- Trip fare is 480000 NGN; composite FK (trip_id, amount_minor, currency) ensures exact match
INSERT INTO payments (
    id, trip_id, amount_minor, currency, method, status,
    provider_reference, idempotency_key, processed_at, created_at, updated_at
)
VALUES (
    'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    480000, 'NGN', 'card', 'successful',
    'pay_ref_test_action4_001',
    'idem-pay-action4-001',
    now(), now(), now()
);

-- 4b. View payment history for the trip
-- Serviced by index: payments_trip_idx ON payments (trip_id, created_at DESC, id DESC)
SELECT id, trip_id, amount_minor, currency, method, status, provider_reference, processed_at
FROM payments
WHERE trip_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
ORDER BY created_at DESC, id DESC;


-- ----------------------------------------------------------------------------
-- ACTION 5: A rider submits a review for a completed trip
-- ----------------------------------------------------------------------------
-- 5a. Rider submits review
-- Enforced by trigger trg_reviews_guard (rider must match trip, driver must match, trip completed)
INSERT INTO reviews (
    id, trip_id, rider_id, driver_id, rating, comment, created_at, updated_at
)
VALUES (
    'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    '22222222-2222-4222-8222-222222222222',
    '44444444-4444-4444-8444-444444444444',
    5,
    'Fast arrival and smooth driving on the expressway.',
    now(), now()
);

-- 5b. Driver profile review aggregation
-- Serviced by index: reviews_driver_idx ON reviews (driver_id, created_at DESC)
SELECT count(*) AS total_reviews,
       round(avg(rating)::numeric, 2) AS average_rating
FROM reviews
WHERE driver_id = '44444444-4444-4444-8444-444444444444'
  AND deleted_at IS NULL;
