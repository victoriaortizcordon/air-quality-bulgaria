-- =====================================================================
-- Air quality database (Bulgaria, OpenAQ, 2025)
-- 03_views_and_queries.sql
--
-- Part A: views used by several queries
-- Part B: 15 analytical queries (question + SQL + space for result and
--         interpretation). Run each query on its own (select it and press
--         F5 in pgAdmin) and copy the result into the report.
-- =====================================================================

-- =====================================================================
-- PART A. VIEWS
-- =====================================================================

-- Daily mean per sensor. Only valid hourly values are used, and a day
-- counts only if it has at least 18 hourly values (75 % coverage, the
-- usual minimum for a representative daily mean).
CREATE OR REPLACE VIEW v_daily_avg AS
SELECT se.sensor_id,
       st.station_id,
       st.name                 AS station,
       c.name                  AS city,
       p.pollutant_id,
       p.code                  AS pollutant,
       m.unit_id,
       m.measured_at::date     AS day,
       AVG(m.value)            AS avg_value,
       COUNT(*)                AS hours_count
FROM measurement m
JOIN sensor    se ON se.sensor_id    = m.sensor_id
JOIN station   st ON st.station_id   = se.station_id
JOIN city      c  ON c.city_id       = st.city_id
JOIN pollutant p  ON p.pollutant_id  = se.pollutant_id
WHERE m.quality_flag = 'valid'
GROUP BY se.sensor_id, st.station_id, st.name, c.name,
         p.pollutant_id, p.code, m.unit_id, m.measured_at::date
HAVING COUNT(*) >= 18;

-- Days on which the daily mean was above a 24h limit (WHO or EU).
-- The unit of the measurement must match the unit of the limit.
CREATE OR REPLACE VIEW v_daily_exceedances AS
SELECT d.station_id,
       d.station,
       d.city,
       d.pollutant,
       d.day,
       d.avg_value,
       t.organization,
       t.limit_value,
       ROUND(d.avg_value / t.limit_value, 2) AS ratio
FROM v_daily_avg d
JOIN threshold t
  ON t.pollutant_id     = d.pollutant_id
 AND t.unit_id          = d.unit_id
 AND t.averaging_period = '24h'
 AND t.valid_from      <= d.day
WHERE d.avg_value > t.limit_value;


-- =====================================================================
-- PART B. QUERIES
-- =====================================================================

-- ---------------------------------------------------------------------
-- Q0 (check before the queries): which units were imported?
-- If PM10, PM2.5 and NO2 are not in 'ug/m3', the limit comparisons
-- (queries 3, 4, 5, 12, 15) will return no rows.
-- ---------------------------------------------------------------------
SELECT p.code AS pollutant, u.symbol AS unit, COUNT(*) AS measurements
FROM measurement m
JOIN sensor    se ON se.sensor_id   = m.sensor_id
JOIN pollutant p  ON p.pollutant_id = se.pollutant_id
JOIN unit      u  ON u.unit_id      = m.unit_id
GROUP BY p.code, u.symbol
ORDER BY p.code, u.symbol;


-- ---------------------------------------------------------------------
-- Q1. Filtering and sorting
-- Question: Which were the 10 highest hourly PM10 concentrations
-- recorded in 2025, and where and when did they happen?
-- ---------------------------------------------------------------------
SELECT st.name AS station,
       c.name  AS city,
       m.measured_at,
       m.value AS pm10_ug_m3
FROM measurement m
JOIN sensor    se ON se.sensor_id   = m.sensor_id
JOIN station   st ON st.station_id  = se.station_id
JOIN city      c  ON c.city_id      = st.city_id
JOIN pollutant p  ON p.pollutant_id = se.pollutant_id
WHERE p.code = 'pm10'
  AND m.quality_flag = 'valid'
  AND m.measured_at >= '2025-01-01' AND m.measured_at < '2026-01-01'
ORDER BY m.value DESC
LIMIT 10;
-- Result: (paste here)
-- Interpretation: (write after running)


-- ---------------------------------------------------------------------
-- Q2. Multi-table JOIN
-- Question: How many sensors does each station have and which
-- pollutants does it measure?
-- ---------------------------------------------------------------------
SELECT c.name AS city,
       st.name AS station,
       COUNT(se.sensor_id) AS sensors,
       STRING_AGG(p.code, ', ' ORDER BY p.code) AS pollutants
FROM station st
JOIN city c            ON c.city_id      = st.city_id
LEFT JOIN sensor se    ON se.station_id  = st.station_id
LEFT JOIN pollutant p  ON p.pollutant_id = se.pollutant_id
GROUP BY c.name, st.name
ORDER BY sensors DESC, city, station;
-- Result: (paste here)
-- Interpretation: (write after running)


-- ---------------------------------------------------------------------
-- Q3. Aggregates, calculation and HAVING
-- Question: Which stations had an annual mean (2025) above the annual
-- limit of the WHO or the EU for PM10, PM2.5 or NO2, and by how much?
-- Only sensors with at least 4000 valid hours are considered, so the
-- mean is not based on a few days.
-- ---------------------------------------------------------------------
SELECT st.name AS station,
       p.code  AS pollutant,
       ROUND(AVG(m.value), 1) AS annual_mean,
       t.organization,
       t.limit_value,
       ROUND(AVG(m.value) / t.limit_value, 2) AS ratio_to_limit
FROM measurement m
JOIN sensor    se ON se.sensor_id   = m.sensor_id
JOIN station   st ON st.station_id  = se.station_id
JOIN pollutant p  ON p.pollutant_id = se.pollutant_id
JOIN threshold t  ON t.pollutant_id     = p.pollutant_id
                 AND t.unit_id          = m.unit_id
                 AND t.averaging_period = 'year'
WHERE p.code IN ('pm10', 'pm25', 'no2')
  AND m.quality_flag = 'valid'
  AND m.measured_at >= '2025-01-01' AND m.measured_at < '2026-01-01'
GROUP BY st.name, p.code, t.organization, t.limit_value
HAVING COUNT(*) >= 4000 AND AVG(m.value) > t.limit_value
ORDER BY ratio_to_limit DESC;
-- Result: (paste here)
-- Interpretation: (write after running)


-- ---------------------------------------------------------------------
-- Q4. GROUP BY on a view
-- Question: How many days did each station exceed the EU daily PM10
-- limit (50 ug/m3)?
-- ---------------------------------------------------------------------
SELECT station, city, COUNT(*) AS days_over_limit
FROM v_daily_exceedances
WHERE pollutant = 'pm10' AND organization = 'EU'
GROUP BY station, city
ORDER BY days_over_limit DESC;
-- Result: (paste here)
-- Interpretation: (write after running)


-- ---------------------------------------------------------------------
-- Q5. HAVING
-- Question: Which stations exceeded the EU daily PM10 limit on more
-- than 35 days? (The EU directive allows at most 35 days per year.)
-- ---------------------------------------------------------------------
SELECT station, city, COUNT(*) AS days_over_limit
FROM v_daily_exceedances
WHERE pollutant = 'pm10' AND organization = 'EU'
GROUP BY station, city
HAVING COUNT(*) > 35
ORDER BY days_over_limit DESC;
-- Result: (paste here)
-- Interpretation: (write after running)


-- ---------------------------------------------------------------------
-- Q6. Date/time operations
-- Question: How does the mean PM10 change month by month across all
-- stations?
-- ---------------------------------------------------------------------
SELECT DATE_TRUNC('month', day)::date AS month,
       ROUND(AVG(avg_value), 1)       AS mean_pm10,
       COUNT(DISTINCT station_id)     AS stations_reporting
FROM v_daily_avg
WHERE pollutant = 'pm10'
GROUP BY DATE_TRUNC('month', day)
ORDER BY month;
-- Result: (paste here)
-- Interpretation: (write after running)


-- ---------------------------------------------------------------------
-- Q7. CASE and seasonal comparison
-- Question: Are particulate levels higher during the heating season
-- (October-March) than in the rest of the year?
-- ---------------------------------------------------------------------
SELECT pollutant,
       CASE WHEN EXTRACT(MONTH FROM day) IN (10, 11, 12, 1, 2, 3)
            THEN 'heating season (Oct-Mar)'
            ELSE 'rest of year (Apr-Sep)' END AS season,
       ROUND(AVG(avg_value), 1) AS mean_ug_m3,
       COUNT(*)                 AS station_days
FROM v_daily_avg
WHERE pollutant IN ('pm10', 'pm25')
GROUP BY pollutant, season
ORDER BY pollutant, season;
-- Result: (paste here)
-- Interpretation: (write after running)


-- ---------------------------------------------------------------------
-- Q8. Time zones and hour of day
-- Question: At what local hour is NO2 highest on average (traffic
-- pattern)? Timestamps are stored in UTC, so they are converted to
-- Bulgarian local time.
-- ---------------------------------------------------------------------
SELECT EXTRACT(HOUR FROM (m.measured_at AT TIME ZONE 'UTC')
                          AT TIME ZONE 'Europe/Sofia')::int AS local_hour,
       ROUND(AVG(m.value), 1) AS mean_no2
FROM measurement m
JOIN sensor    se ON se.sensor_id   = m.sensor_id
JOIN pollutant p  ON p.pollutant_id = se.pollutant_id
JOIN unit      u  ON u.unit_id      = m.unit_id
WHERE p.code = 'no2' AND m.quality_flag = 'valid'
  AND u.symbol = 'ug/m3'   -- a few rows come in ppb: do not mix units
GROUP BY local_hour
ORDER BY local_hour;
-- Result: (paste here)
-- Interpretation: (write after running)


-- ---------------------------------------------------------------------
-- Q9. CTE and data quality
-- Question: Which sensors have less than 70 % of the hours of 2025
-- (8760 h)? These series should be interpreted with care.
-- ---------------------------------------------------------------------
WITH coverage AS (
    SELECT st.name AS station, p.code AS pollutant, COUNT(*) AS hours
    FROM measurement m
    JOIN sensor    se ON se.sensor_id   = m.sensor_id
    JOIN station   st ON st.station_id  = se.station_id
    JOIN pollutant p  ON p.pollutant_id = se.pollutant_id
    WHERE m.measured_at >= '2025-01-01' AND m.measured_at < '2026-01-01'
    GROUP BY st.name, p.code
)
SELECT station, pollutant, hours,
       ROUND(100.0 * hours / 8760, 1) AS coverage_pct
FROM coverage
WHERE hours < 0.7 * 8760
ORDER BY coverage_pct;
-- Result: (paste here)
-- Interpretation: (write after running)


-- ---------------------------------------------------------------------
-- Q10. Import traceability
-- Question: How many rows did each import read, load and reject, and
-- what percentage was rejected during cleaning?
-- ---------------------------------------------------------------------
SELECT import_id,
       source_name,
       retrieved_at,
       rows_read,
       rows_loaded,
       rows_rejected,
       ROUND(100.0 * rows_rejected / NULLIF(rows_read, 0), 2) AS rejected_pct
FROM import_log
ORDER BY import_id;
-- Result: (paste here)
-- Interpretation: (write after running)


-- ---------------------------------------------------------------------
-- Q11. Subquery
-- Question: Which stations have a mean PM10 above the mean of all
-- stations combined?
-- ---------------------------------------------------------------------
SELECT s.station, ROUND(s.mean_pm10, 1) AS mean_pm10
FROM (
    SELECT st.name AS station, AVG(m.value) AS mean_pm10
    FROM measurement m
    JOIN sensor    se ON se.sensor_id   = m.sensor_id
    JOIN station   st ON st.station_id  = se.station_id
    JOIN pollutant p  ON p.pollutant_id = se.pollutant_id
    WHERE p.code = 'pm10' AND m.quality_flag = 'valid'
    GROUP BY st.name
) s
WHERE s.mean_pm10 > (
    SELECT AVG(m.value)
    FROM measurement m
    JOIN sensor    se ON se.sensor_id   = m.sensor_id
    JOIN pollutant p  ON p.pollutant_id = se.pollutant_id
    WHERE p.code = 'pm10' AND m.quality_flag = 'valid'
)
ORDER BY s.mean_pm10 DESC;
-- Result: (paste here)
-- Interpretation: (write after running)


-- ---------------------------------------------------------------------
-- Q12. CTE and window function (ranking)
-- Question: Which cities had the most days above the WHO daily PM2.5
-- guideline (15 ug/m3)? Ranked from worst to best.
-- (A day counts once per city, even if several stations exceeded it.)
-- ---------------------------------------------------------------------
WITH days_over AS (
    SELECT city, COUNT(DISTINCT day) AS days_over_who
    FROM v_daily_exceedances
    WHERE pollutant = 'pm25' AND organization = 'WHO'
    GROUP BY city
)
SELECT city,
       days_over_who,
       RANK() OVER (ORDER BY days_over_who DESC) AS position
FROM days_over
ORDER BY position, city;
-- Result: (paste here)
-- Interpretation: (write after running)


-- ---------------------------------------------------------------------
-- Q13. DISTINCT ON
-- Question: What was the most polluted day (highest daily mean PM10)
-- in each city, and at which station?
-- ---------------------------------------------------------------------
SELECT DISTINCT ON (city)
       city, station, day, ROUND(avg_value, 1) AS daily_mean_pm10
FROM v_daily_avg
WHERE pollutant = 'pm10'
ORDER BY city, avg_value DESC;
-- Result: (paste here)
-- Interpretation: (write after running)


-- ---------------------------------------------------------------------
-- Q14. Statistical calculation (correlation) with a self-join
-- Question: Do PM10 and NO2 move together? Correlation of the daily
-- means per station (only stations with at least 100 common days).
-- ---------------------------------------------------------------------
SELECT a.station,
       COUNT(*) AS common_days,
       ROUND(CORR(a.avg_value, b.avg_value)::numeric, 2) AS corr_pm10_no2
FROM v_daily_avg a
JOIN v_daily_avg b
  ON b.station_id = a.station_id AND b.day = a.day
WHERE a.pollutant = 'pm10' AND b.pollutant = 'no2'
GROUP BY a.station
HAVING COUNT(*) >= 100
ORDER BY corr_pm10_no2 DESC;
-- Result: (paste here)
-- Interpretation: (write after running)


-- ---------------------------------------------------------------------
-- Q15. Complex analytical query (several entities, CTEs and windows)
-- Question: For each city and month, what was the mean PM10, how many
-- days exceeded the EU daily limit, how far was the month from the
-- city's own average, and where does the month rank among the city's
-- months (1 = most polluted)?
-- ---------------------------------------------------------------------
WITH monthly AS (
    SELECT city,
           DATE_TRUNC('month', day)::date AS month,
           AVG(avg_value)                 AS mean_pm10,
           COUNT(*)                       AS station_days
    FROM v_daily_avg
    WHERE pollutant = 'pm10'
    GROUP BY city, DATE_TRUNC('month', day)
),
exc AS (
    SELECT city,
           DATE_TRUNC('month', day)::date AS month,
           COUNT(DISTINCT day)            AS days_over_eu
    FROM v_daily_exceedances
    WHERE pollutant = 'pm10' AND organization = 'EU'
    GROUP BY city, DATE_TRUNC('month', day)
)
SELECT m.city,
       m.month,
       ROUND(m.mean_pm10, 1)                         AS mean_pm10,
       COALESCE(e.days_over_eu, 0)                   AS days_over_eu,
       ROUND(m.mean_pm10 - AVG(m.mean_pm10) OVER (PARTITION BY m.city), 1)
                                                     AS diff_vs_city_mean,
       RANK() OVER (PARTITION BY m.city ORDER BY m.mean_pm10 DESC)
                                                     AS rank_in_city
FROM monthly m
LEFT JOIN exc e ON e.city = m.city AND e.month = m.month
ORDER BY m.city, m.month;
-- Result: (paste here)
-- Interpretation: (write after running)
