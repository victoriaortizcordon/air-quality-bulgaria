# Air Quality in Bulgaria (2025): relational database

Group project for the course **Databases** (Ruse University, Erasmus+), Prof. Tsvetelina Kaneva and Prof. Irena Valova.

A PostgreSQL 17 database of **hourly air-quality measurements in Bulgaria for 2025**, loaded from the open **OpenAQ API v3**. It contains 15 stations, 80 sensors and about 379,000 measurements of PM2.5, PM10, NO2, O3, SO2 and CO, plus WHO and EU limit values, a trigger, two views and 15 analytical queries.

## Data source

| Item | Description |
| --- | --- |
| Name | OpenAQ API v3 |
| Organization | OpenAQ (non-profit) |
| URL | https://api.openaq.org/v3 (docs: https://docs.openaq.org) |
| Format | JSON over REST, API key in the `X-API-Key` header |
| Period | 2025-01-01 to 2026-01-01, hourly values |
| Providers | Stations used here are reported by the EEA (European Environment Agency) and other providers |
| License | Set by each data provider; see https://docs.openaq.org/resources/licenses. Credit OpenAQ and the provider |
| Retrieved | 2026-11-17 |

The reference data in `01_schema.sql` (units, station types, pollutants and WHO/EU limit values) were entered by the team and do not come from OpenAQ. Limit values: WHO Global Air Quality Guidelines 2021 and EU Directive 2008/50/EC.

## Repository contents

| File | Purpose |
| --- | --- |
| `01_schema.sql` | Creates all 11 tables, indexes, the trigger and the reference data. **It drops existing tables: do not run it on a database you want to keep.** |
| `import_openaq.py` | Downloads and loads the data (repeatable) |
| `03_views_and_queries.sql` | Part A: two views. Part B: queries Q0 to Q15 |
| `04_integrity_tests.sql` | Eight statements that must fail, to show the constraints work |
| `requirements.txt` | Python packages |
| `.env.example` | Template for the settings file |
| `sample_data/` | Small sample of the downloaded measurements |
| `docs/` | Report (PDF) and ER diagram |

## Requirements

- PostgreSQL 17 and pgAdmin 4
- Python 3.10 or newer
- A free OpenAQ API key (https://explore.openaq.org, create an account and copy the key from the account page)

## How to run

1. Create an empty database called `air_quality` in pgAdmin.
2. Open a Query Tool on that database, load `01_schema.sql` and run it.
3. Copy `.env.example` to `.env` and fill in your values:
   ```
   OPENAQ_API_KEY=your_key_here
   PGHOST=localhost
   PGPORT=5432
   PGDATABASE=air_quality
   PGUSER=postgres
   PGPASSWORD=your_password
   ```
   Never commit `.env`: it is listed in `.gitignore`.
4. Install the packages and run the import:
   ```
   pip install -r requirements.txt
   python import_openaq.py --max-locations 15 --start 2025-01-01 --end 2026-01-01
   ```
   The API sometimes times out. If the script reports `failed_sensors`, run the same command again: existing rows are not duplicated (`UNIQUE (sensor_id, measured_at)` with `ON CONFLICT DO NOTHING`).
5. Run Part A of `03_views_and_queries.sql` to create the views, then the queries of Part B.
6. Optionally run `04_integrity_tests.sql` one statement at a time. Every statement must fail with an error.

## Import pipeline

Source (OpenAQ API, paginated, retries on 408/425/5xx) → validation (null and negative values rejected) → cleaning (duplicate timestamps removed, values above 1000 ug/m3 flagged `suspect`) → transformation (UTC timestamps, units mapped) → mapping (country, city, station, sensor) → load. Each run writes rows read, loaded and rejected to `import_log`.

## Data model (3NF, 11 tables)

`country` → `city` → `station` (+ `station_type`) → `sensor` (also linked to `pollutant`, which resolves the N:M relation station-pollutant) → `measurement` (+ `unit`, `import_log`). `threshold` stores WHO and EU limits and `exceedance` is filled by the trigger `trg_measurement_exceedance` when an hourly value is above a 1-hour limit. See `docs/` for the ER diagram.

## Results of the last import

- 394,165 rows read, 379,324 loaded, 14,841 rejected (3.77 %).
- 11 of 15 stations have data. Four stations (Kopitoto, ExEA/Pavlovo, Zelen klin, 4B Bulgaria Blvrd) have no measurements because the API timed out for all their sensors on every attempt.

## Authors

- Victoria Ortiz Cordón
- Carlos del Castillo Muñoz
- Juan Antonio Sánchez Vera
- Antonio Siles Reyes
