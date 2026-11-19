-- =====================================================================
-- Air quality database - schema (PostgreSQL 17)
-- Run this script inside the database "air_quality".
-- It is safe to re-run: it drops and recreates everything.
-- =====================================================================

DROP TABLE IF EXISTS exceedance    CASCADE;
DROP TABLE IF EXISTS measurement   CASCADE;
DROP TABLE IF EXISTS threshold     CASCADE;
DROP TABLE IF EXISTS sensor        CASCADE;
DROP TABLE IF EXISTS pollutant     CASCADE;
DROP TABLE IF EXISTS unit          CASCADE;
DROP TABLE IF EXISTS station       CASCADE;
DROP TABLE IF EXISTS station_type  CASCADE;
DROP TABLE IF EXISTS city          CASCADE;
DROP TABLE IF EXISTS country       CASCADE;
DROP TABLE IF EXISTS import_log    CASCADE;
DROP FUNCTION IF EXISTS fn_check_exceedance() CASCADE;

-- ---------------------------------------------------------------------
-- 1. country
-- ---------------------------------------------------------------------
CREATE TABLE country (
    country_id  SERIAL PRIMARY KEY,
    iso_code    CHAR(2)      NOT NULL UNIQUE,
    name        VARCHAR(100) NOT NULL
);

-- ---------------------------------------------------------------------
-- 2. city
-- ---------------------------------------------------------------------
CREATE TABLE city (
    city_id     SERIAL PRIMARY KEY,
    country_id  INT          NOT NULL REFERENCES country(country_id)
                             ON UPDATE CASCADE ON DELETE RESTRICT,
    name        VARCHAR(100) NOT NULL,
    UNIQUE (country_id, name)
);

-- ---------------------------------------------------------------------
-- 3. station_type
-- ---------------------------------------------------------------------
CREATE TABLE station_type (
    station_type_id SERIAL PRIMARY KEY,
    name            VARCHAR(50) NOT NULL UNIQUE,
    description     TEXT
);

-- ---------------------------------------------------------------------
-- 4. station
-- ---------------------------------------------------------------------
CREATE TABLE station (
    station_id      SERIAL PRIMARY KEY,
    external_id     VARCHAR(50)  NOT NULL UNIQUE,
    name            VARCHAR(150) NOT NULL,
    city_id         INT          NOT NULL REFERENCES city(city_id)
                                 ON UPDATE CASCADE ON DELETE RESTRICT,
    station_type_id INT          REFERENCES station_type(station_type_id)
                                 ON UPDATE CASCADE ON DELETE SET NULL,
    latitude        NUMERIC(9,6) CHECK (latitude  BETWEEN -90  AND 90),
    longitude       NUMERIC(9,6) CHECK (longitude BETWEEN -180 AND 180),
    elevation_m     NUMERIC(7,2)
);

-- ---------------------------------------------------------------------
-- 5. unit
-- ---------------------------------------------------------------------
CREATE TABLE unit (
    unit_id SERIAL PRIMARY KEY,
    symbol  VARCHAR(20) NOT NULL UNIQUE
);

-- ---------------------------------------------------------------------
-- 6. pollutant
-- ---------------------------------------------------------------------
CREATE TABLE pollutant (
    pollutant_id    SERIAL PRIMARY KEY,
    code            VARCHAR(20)  NOT NULL UNIQUE,
    name            VARCHAR(100) NOT NULL,
    default_unit_id INT          NOT NULL REFERENCES unit(unit_id)
                                 ON UPDATE CASCADE ON DELETE RESTRICT
);

-- ---------------------------------------------------------------------
-- 7. sensor  (resolves the N:M relationship station <-> pollutant)
-- ---------------------------------------------------------------------
CREATE TABLE sensor (
    sensor_id    SERIAL PRIMARY KEY,
    station_id   INT NOT NULL REFERENCES station(station_id)
                     ON UPDATE CASCADE ON DELETE CASCADE,
    pollutant_id INT NOT NULL REFERENCES pollutant(pollutant_id)
                     ON UPDATE CASCADE ON DELETE RESTRICT,
    installed_on DATE,
    UNIQUE (station_id, pollutant_id)
);

-- ---------------------------------------------------------------------
-- 11. import_log (created before measurement because it is referenced)
-- ---------------------------------------------------------------------
CREATE TABLE import_log (
    import_id     SERIAL PRIMARY KEY,
    source_name   VARCHAR(100) NOT NULL,
    source_url    TEXT         NOT NULL,
    retrieved_at  TIMESTAMP    NOT NULL,
    rows_read     INT          NOT NULL DEFAULT 0 CHECK (rows_read     >= 0),
    rows_loaded   INT          NOT NULL DEFAULT 0 CHECK (rows_loaded   >= 0),
    rows_rejected INT          NOT NULL DEFAULT 0 CHECK (rows_rejected >= 0),
    notes         TEXT
);

-- ---------------------------------------------------------------------
-- 8. measurement
-- ---------------------------------------------------------------------
CREATE TABLE measurement (
    measurement_id BIGSERIAL PRIMARY KEY,
    sensor_id      INT           NOT NULL REFERENCES sensor(sensor_id)
                                 ON UPDATE CASCADE ON DELETE CASCADE,
    measured_at    TIMESTAMP     NOT NULL,
    value          NUMERIC(10,3) NOT NULL CHECK (value >= 0),
    unit_id        INT           NOT NULL REFERENCES unit(unit_id)
                                 ON UPDATE CASCADE ON DELETE RESTRICT,
    quality_flag   VARCHAR(20)   NOT NULL DEFAULT 'valid'
                                 CHECK (quality_flag IN ('valid','suspect','invalid')),
    import_id      INT           REFERENCES import_log(import_id)
                                 ON UPDATE CASCADE ON DELETE SET NULL,
    UNIQUE (sensor_id, measured_at)
);

-- ---------------------------------------------------------------------
-- 9. threshold
-- ---------------------------------------------------------------------
CREATE TABLE threshold (
    threshold_id     SERIAL PRIMARY KEY,
    pollutant_id     INT           NOT NULL REFERENCES pollutant(pollutant_id)
                                   ON UPDATE CASCADE ON DELETE CASCADE,
    organization     VARCHAR(10)   NOT NULL CHECK (organization IN ('WHO','EU')),
    averaging_period VARCHAR(10)   NOT NULL CHECK (averaging_period IN ('1h','24h','year')),
    limit_value      NUMERIC(8,3)  NOT NULL CHECK (limit_value > 0),
    unit_id          INT           NOT NULL REFERENCES unit(unit_id)
                                   ON UPDATE CASCADE ON DELETE RESTRICT,
    valid_from       DATE          NOT NULL,
    UNIQUE (pollutant_id, organization, averaging_period, valid_from)
);

-- ---------------------------------------------------------------------
-- 10. exceedance (filled by a trigger)
-- ---------------------------------------------------------------------
CREATE TABLE exceedance (
    exceedance_id  BIGSERIAL PRIMARY KEY,
    measurement_id BIGINT       NOT NULL REFERENCES measurement(measurement_id)
                                ON UPDATE CASCADE ON DELETE CASCADE,
    threshold_id   INT          NOT NULL REFERENCES threshold(threshold_id)
                                ON UPDATE CASCADE ON DELETE CASCADE,
    detected_at    TIMESTAMP    NOT NULL DEFAULT now(),
    ratio          NUMERIC(8,2) NOT NULL CHECK (ratio > 1),
    UNIQUE (measurement_id, threshold_id)
);

-- ---------------------------------------------------------------------
-- Indexes (speed up the most common joins and time filters)
-- ---------------------------------------------------------------------
CREATE INDEX idx_station_city          ON station(city_id);
CREATE INDEX idx_sensor_pollutant      ON sensor(pollutant_id);
CREATE INDEX idx_measurement_time      ON measurement(measured_at);
CREATE INDEX idx_measurement_sensor_t  ON measurement(sensor_id, measured_at);
CREATE INDEX idx_exceedance_threshold  ON exceedance(threshold_id);

-- ---------------------------------------------------------------------
-- Trigger: record an exceedance when a new measurement is above a
-- 1-hour limit for the same pollutant and unit.
-- (24h and yearly limits need averaged values, so they are checked
--  later with SQL queries/views, not in this row-level trigger.)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_check_exceedance() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.quality_flag = 'valid' THEN
        INSERT INTO exceedance (measurement_id, threshold_id, ratio)
        SELECT NEW.measurement_id,
               t.threshold_id,
               ROUND(NEW.value / t.limit_value, 2)
        FROM sensor s
        JOIN threshold t ON t.pollutant_id = s.pollutant_id
        WHERE s.sensor_id = NEW.sensor_id
          AND t.averaging_period = '1h'
          AND t.unit_id = NEW.unit_id
          AND t.valid_from <= NEW.measured_at::date
          AND NEW.value > t.limit_value;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_measurement_exceedance
AFTER INSERT ON measurement
FOR EACH ROW EXECUTE FUNCTION fn_check_exceedance();

-- ---------------------------------------------------------------------
-- Reference data introduced by the team (NOT from the external dataset)
-- ---------------------------------------------------------------------
INSERT INTO unit (symbol) VALUES ('ug/m3'), ('ppm'), ('ppb');

INSERT INTO station_type (name, description) VALUES
 ('urban',       'Urban background'),
 ('suburban',    'Suburban background'),
 ('rural',       'Rural background'),
 ('industrial',  'Close to industrial sources'),
 ('traffic',     'Close to road traffic');

INSERT INTO pollutant (code, name, default_unit_id) VALUES
 ('pm25', 'Fine particulate matter (PM2.5)',   (SELECT unit_id FROM unit WHERE symbol='ug/m3')),
 ('pm10', 'Particulate matter (PM10)',         (SELECT unit_id FROM unit WHERE symbol='ug/m3')),
 ('no2',  'Nitrogen dioxide (NO2)',            (SELECT unit_id FROM unit WHERE symbol='ug/m3')),
 ('o3',   'Ozone (O3)',                        (SELECT unit_id FROM unit WHERE symbol='ug/m3')),
 ('so2',  'Sulphur dioxide (SO2)',             (SELECT unit_id FROM unit WHERE symbol='ug/m3')),
 ('co',   'Carbon monoxide (CO)',              (SELECT unit_id FROM unit WHERE symbol='ug/m3'));

-- Example limits. CHECK THESE VALUES against the official WHO / EU
-- documents before using them in the final report.
INSERT INTO threshold (pollutant_id, organization, averaging_period, limit_value, unit_id, valid_from)
SELECT p.pollutant_id, v.org, v.period, v.lim, u.unit_id, DATE '2021-09-22'
FROM (VALUES
  ('pm25','WHO','24h',   15),
  ('pm25','WHO','year',   5),
  ('pm10','WHO','24h',   45),
  ('pm10','WHO','year',  15),
  ('no2', 'WHO','24h',   25),
  ('no2', 'WHO','year',  10),
  ('pm10','EU', '24h',   50),
  ('pm10','EU', 'year',  40),
  ('pm25','EU', 'year',  25),
  ('no2', 'EU', '1h',   200),
  ('no2', 'EU', 'year',  40)
) AS v(code, org, period, lim)
JOIN pollutant p ON p.code = v.code
JOIN unit u      ON u.symbol = 'ug/m3';
