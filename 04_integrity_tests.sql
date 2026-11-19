-- =====================================================================
-- 04_integrity_tests.sql
-- Examples showing that the constraints prevent invalid data.
-- EVERY statement below is expected to FAIL with an error.
-- Run them ONE BY ONE (select the statement and press F5) and take a
-- screenshot of the error message for the report.
-- Nothing is changed in the database because all of them are rejected.
-- =====================================================================

-- T1. CHECK (value >= 0): a negative concentration is not allowed.
INSERT INTO measurement (sensor_id, measured_at, value, unit_id)
VALUES ((SELECT MIN(sensor_id) FROM sensor), '2030-01-01 00:00', -5,
        (SELECT MIN(unit_id) FROM unit));

-- T2. UNIQUE (sensor_id, measured_at): the same sensor cannot have two
--     values for the same hour (we try to insert an existing row again).
INSERT INTO measurement (sensor_id, measured_at, value, unit_id)
SELECT sensor_id, measured_at, value, unit_id
FROM measurement
LIMIT 1;

-- T3. FOREIGN KEY: a station must belong to an existing city.
INSERT INTO station (external_id, name, city_id)
VALUES ('TEST-1', 'Station without a valid city', 999999);

-- T4. CHECK on latitude (-90..90).
INSERT INTO station (external_id, name, city_id, latitude, longitude)
VALUES ('TEST-2', 'Impossible latitude',
        (SELECT MIN(city_id) FROM city), 123.0, 25.0);

-- T5. CHECK on quality_flag (valid / suspect / invalid only).
INSERT INTO measurement (sensor_id, measured_at, value, unit_id, quality_flag)
VALUES ((SELECT MIN(sensor_id) FROM sensor), '2030-01-02 00:00', 10,
        (SELECT MIN(unit_id) FROM unit), 'maybe');

-- T6. ON DELETE RESTRICT: a city that still has stations cannot be deleted.
DELETE FROM city
WHERE city_id = (SELECT MIN(city_id) FROM station);

-- T7. CHECK (limit_value > 0) and CHECK on organization.
INSERT INTO threshold (pollutant_id, organization, averaging_period,
                       limit_value, unit_id, valid_from)
VALUES ((SELECT MIN(pollutant_id) FROM pollutant), 'WHO', '24h', 0,
        (SELECT MIN(unit_id) FROM unit), '2025-01-01');

-- T8. NOT NULL: a country needs a name.
INSERT INTO country (iso_code, name) VALUES ('ZZ', NULL);
