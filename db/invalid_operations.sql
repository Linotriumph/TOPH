-- ============================================================================
-- TOPH ride-hailing MVP — Invalid Operations and Negative Security Tests
-- Proves that the database constraints, partial unique indexes, and triggers
-- strictly reject illegal business states, paired with positive controls.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- TEST 1: Second Active Trip for the Same Rider
-- ----------------------------------------------------------------------------
-- POSITIVE CONTROL: Rider '11111111-1111-4111-8111-111111111111' creates a valid active trip.
-- (Currently has completed trips only, so 0 active trips).
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

-- NEGATIVE TEST: Attempt to insert a SECOND active trip for Rider '11111111-1111-4111-8111-111111111111'.
-- Expected Error: duplicate key value violates unique constraint "trips_one_active_per_rider" (SQLSTATE 23505)
\echo '>>> EXECUTING TEST 1: Attempting second active trip for rider...'
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


-- ----------------------------------------------------------------------------
-- TEST 2: Review for an Incomplete Trip
-- ----------------------------------------------------------------------------
-- NEGATIVE TEST: Attempt to insert a review for trip '10101010-1010-4010-8010-101010101010'
-- which is currently in 'requested' status (incomplete).
-- Expected Error: trigger fn_reviews_guard raises exception 'review: trip ... is requested - a review requires a completed trip' (SQLSTATE 23514)
\echo '>>> EXECUTING TEST 2: Attempting review on requested (incomplete) trip...'
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


-- ----------------------------------------------------------------------------
-- TEST 3: Forbidden State Transition (completed -> in_progress)
-- ----------------------------------------------------------------------------
-- NEGATIVE TEST: Attempt to update trip '77777777-7777-4777-8777-777777777777' (which is 'completed')
-- back to 'in_progress'.
-- Expected Error: trigger fn_trips_transition_guard raises exception 'trip ...: invalid trip status transition from completed to in_progress' (SQLSTATE 23514)
\echo '>>> EXECUTING TEST 3: Attempting illegal transition completed -> in_progress...'
UPDATE trips
SET status = 'in_progress',
    updated_at = now()
WHERE id = '77777777-7777-4777-8777-777777777777';
