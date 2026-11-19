#!/usr/bin/env python3
"""
Import air-quality data from OpenAQ (API v3) into the PostgreSQL database
"air_quality" created with 01_schema.sql.

Pipeline:
    source data (OpenAQ API) -> validation -> cleaning -> transformation
    -> relational mapping -> database

Usage (example):
    python import_openaq.py --country BG --start 2025-01-01 --end 2026-01-01 --max-locations 15

Quick test first (small and fast):
    python import_openaq.py --max-locations 2 --start 2025-01-01 --end 2025-01-08

Configuration is read from a file called ".env" (see .env.example) or from
environment variables. NEVER commit the real .env file to GitHub.

The script is repeatable: reference rows are upserted and measurements use
ON CONFLICT DO NOTHING, so running it twice does not create duplicates.
"""
import argparse
import os
import sys
import time

import pandas as pd
import psycopg
import requests

API = "https://api.openaq.org/v3"
RATE_DELAY = 1.1          # seconds between API calls (the API has rate limits)
PAGE_LIMIT = 1000

# Pollutants we keep (codes must exist in the "pollutant" table).
WANTED = {"pm25", "pm10", "no2", "o3", "so2", "co"}

# Standardise unit symbols coming from the source.
UNIT_MAP = {
    "\u00b5g/m\u00b3": "ug/m3",   # micro sign
    "\u03bcg/m\u00b3": "ug/m3",   # greek mu
    "ug/m3": "ug/m3",
    "ppm": "ppm",
    "ppb": "ppb",
}

SUSPECT_ABOVE_UG = 1000.0  # values above this (ug/m3) are flagged 'suspect'


# ----------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------
def load_env(path=".env"):
    if not os.path.exists(path):
        return
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


# ----------------------------------------------------------------------
# OpenAQ client
# ----------------------------------------------------------------------
class OpenAQ:
    def __init__(self, api_key):
        self.session = requests.Session()
        self.session.headers.update({"X-API-Key": api_key})
        self.last_call = 0.0

    def get(self, path, params=None):
        for attempt in range(6):
            wait = RATE_DELAY - (time.time() - self.last_call)
            if wait > 0:
                time.sleep(wait)
            self.last_call = time.time()
            try:
                r = self.session.get(API + path, params=params, timeout=60)
            except requests.RequestException as e:
                print(f"   network error ({e}); retrying...")
                time.sleep(5 * (attempt + 1))
                continue
            if r.status_code == 429:
                try:
                    delay = float(r.headers.get("Retry-After", 15))
                except ValueError:
                    delay = 15
                time.sleep(delay)
                continue
            if r.status_code in (408, 425) or r.status_code >= 500:
                time.sleep(5 * (attempt + 1))
                continue
            if r.status_code in (401, 403):
                sys.exit("API key rejected (401/403). Check OPENAQ_API_KEY in your .env file.")
            r.raise_for_status()
            return r.json()
        raise RuntimeError(f"Too many failed attempts for {path}")

    def pages(self, path, params):
        page = 1
        while True:
            data = self.get(path, dict(params, limit=PAGE_LIMIT, page=page))
            results = data.get("results", [])
            yield from results
            if len(results) < PAGE_LIMIT:
                break
            page += 1


# ----------------------------------------------------------------------
# Database helpers (upserts that always return the row id)
# ----------------------------------------------------------------------
def one(cur, sql, params):
    cur.execute(sql, params)
    return cur.fetchone()[0]


def upsert_country(cur, iso, name):
    return one(cur,
        "INSERT INTO country (iso_code, name) VALUES (%s, %s) "
        "ON CONFLICT (iso_code) DO UPDATE SET name = EXCLUDED.name RETURNING country_id",
        (iso, name))


def upsert_city(cur, country_id, name):
    return one(cur,
        "INSERT INTO city (country_id, name) VALUES (%s, %s) "
        "ON CONFLICT (country_id, name) DO UPDATE SET name = EXCLUDED.name RETURNING city_id",
        (country_id, name))


def upsert_station(cur, external_id, name, city_id, lat, lon):
    return one(cur,
        "INSERT INTO station (external_id, name, city_id, latitude, longitude) "
        "VALUES (%s, %s, %s, %s, %s) "
        "ON CONFLICT (external_id) DO UPDATE SET name = EXCLUDED.name, "
        "city_id = EXCLUDED.city_id, latitude = EXCLUDED.latitude, "
        "longitude = EXCLUDED.longitude RETURNING station_id",
        (external_id, name, city_id, lat, lon))


def upsert_unit(cur, symbol):
    return one(cur,
        "INSERT INTO unit (symbol) VALUES (%s) "
        "ON CONFLICT (symbol) DO UPDATE SET symbol = EXCLUDED.symbol RETURNING unit_id",
        (symbol,))


def upsert_sensor(cur, station_id, pollutant_id):
    return one(cur,
        "INSERT INTO sensor (station_id, pollutant_id) VALUES (%s, %s) "
        "ON CONFLICT (station_id, pollutant_id) DO UPDATE "
        "SET station_id = EXCLUDED.station_id RETURNING sensor_id",
        (station_id, pollutant_id))


# ----------------------------------------------------------------------
# Cleaning / transformation of one batch of measurements
# ----------------------------------------------------------------------
def clean_batch(raw_rows, is_ug):
    """Return (rows_to_load, n_rejected) from the raw API rows of one sensor."""
    records = []
    for r in raw_rows:
        period = r.get("period") or {}
        dt_from = period.get("datetimeFrom") or {}
        records.append({"value": r.get("value"), "ts": dt_from.get("utc")})
    if not records:
        return [], 0

    df = pd.DataFrame(records)
    total = len(df)
    df["value"] = pd.to_numeric(df["value"], errors="coerce")
    df["ts"] = pd.to_datetime(df["ts"], utc=True, errors="coerce")

    # validation: drop rows without value/time, and negative values
    # (the CHECK constraint value >= 0 would reject them anyway)
    df = df.dropna(subset=["value", "ts"])
    df = df[df["value"] >= 0]
    rejected = total - len(df)

    # cleaning: remove duplicated timestamps, store UTC as naive timestamp
    df = df.drop_duplicates(subset=["ts"])
    df["ts"] = df["ts"].dt.tz_convert(None)

    rows = []
    for ts, value in zip(df["ts"], df["value"]):
        value = round(float(value), 3)
        flag = "suspect" if (is_ug and value > SUSPECT_ABOVE_UG) else "valid"
        rows.append((ts.to_pydatetime(), value, flag))
    return rows, rejected


# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------
def main():
    load_env()
    ap = argparse.ArgumentParser(description="Import OpenAQ data into PostgreSQL")
    ap.add_argument("--country", default="BG", help="ISO country code (default BG)")
    ap.add_argument("--start", default="2025-01-01", help="start date YYYY-MM-DD")
    ap.add_argument("--end", default="2026-01-01", help="end date YYYY-MM-DD")
    ap.add_argument("--max-locations", type=int, default=15,
                    help="max number of stations to import (default 15)")
    args = ap.parse_args()

    api_key = os.environ.get("OPENAQ_API_KEY")
    if not api_key:
        sys.exit("Missing OPENAQ_API_KEY (put it in the .env file).")
    pg_password = os.environ.get("PGPASSWORD")
    if not pg_password:
        sys.exit("Missing PGPASSWORD (put it in the .env file).")

    api = OpenAQ(api_key)

    # 1) find the country id in OpenAQ
    country = None
    for c in api.pages("/countries", {}):
        if (c.get("code") or "").upper() == args.country.upper():
            country = c
            break
    if not country:
        sys.exit(f"Country {args.country} not found in OpenAQ.")
    print(f"Country: {country['name']} (OpenAQ id {country['id']})")

    # 2) list locations and keep the ones with the most wanted sensors
    locations = []
    for loc in api.pages("/locations", {"countries_id": country["id"]}):
        sensors = [s for s in (loc.get("sensors") or [])
                   if ((s.get("parameter") or {}).get("name") or "").lower() in WANTED]
        if sensors:
            locations.append((loc, sensors))
    locations.sort(key=lambda x: len(x[1]), reverse=True)
    locations = locations[:args.max_locations]
    print(f"Locations selected: {len(locations)}")

    with psycopg.connect(
        host=os.environ.get("PGHOST", "localhost"),
        port=os.environ.get("PGPORT", "5432"),
        dbname=os.environ.get("PGDATABASE", "air_quality"),
        user=os.environ.get("PGUSER", "postgres"),
        password=pg_password,
    ) as conn:
        cur = conn.cursor()

        import_id = one(cur,
            "INSERT INTO import_log (source_name, source_url, retrieved_at, notes) "
            "VALUES (%s, %s, now(), %s) RETURNING import_id",
            ("OpenAQ API v3", API + "/locations, /sensors/{id}/hours",
             f"country={args.country}; period={args.start}..{args.end}; "
             f"max_locations={args.max_locations}"))
        conn.commit()

        country_id = upsert_country(cur, country["code"].upper(), country["name"])

        rows_read = rows_loaded = rows_rejected = 0
        skipped_duplicate_sensors = 0
        failed_sensors = 0
        unit_cache = {}
        pollutant_cache = {}

        for loc, sensors in locations:
            coords = loc.get("coordinates") or {}
            lat, lon = coords.get("latitude"), coords.get("longitude")
            city_name = (loc.get("locality") or loc.get("name") or "Unknown").strip()
            city_id = upsert_city(cur, country_id, city_name)
            station_id = upsert_station(
                cur, str(loc["id"]), (loc.get("name") or f"Location {loc['id']}").strip(),
                city_id,
                round(lat, 6) if lat is not None else None,
                round(lon, 6) if lon is not None else None)
            conn.commit()
            print(f"\nStation {loc['id']}: {loc.get('name')} ({city_name})")

            used_pollutants = set()
            for s in sensors:
                param = s["parameter"]
                code = param["name"].lower()
                symbol = UNIT_MAP.get(param.get("units"), param.get("units") or "unknown")

                if code in used_pollutants:
                    skipped_duplicate_sensors += 1
                    continue
                used_pollutants.add(code)

                if code not in pollutant_cache:
                    cur.execute("SELECT pollutant_id FROM pollutant WHERE code = %s", (code,))
                    row = cur.fetchone()
                    pollutant_cache[code] = row[0] if row else None
                if pollutant_cache[code] is None:
                    continue
                if symbol not in unit_cache:
                    unit_cache[symbol] = upsert_unit(cur, symbol)

                sensor_id = upsert_sensor(cur, station_id, pollutant_cache[code])
                conn.commit()

                # 3) download hourly values for this sensor
                try:
                    raw = list(api.pages(f"/sensors/{s['id']}/hours", {
                        "datetime_from": args.start, "datetime_to": args.end}))
                except Exception as e:
                    print(f"   {code:5s} sensor {s['id']}: FAILED ({e}); "
                          f"skipped, run the script again later")
                    failed_sensors += 1
                    continue
                rows_read += len(raw)

                # 4) validate / clean / transform
                clean, rejected = clean_batch(raw, is_ug=(symbol == "ug/m3"))
                rows_rejected += rejected

                # 5) load
                if clean:
                    cur.executemany(
                        "INSERT INTO measurement "
                        "(sensor_id, measured_at, value, unit_id, quality_flag, import_id) "
                        "VALUES (%s, %s, %s, %s, %s, %s) "
                        "ON CONFLICT (sensor_id, measured_at) DO NOTHING",
                        [(sensor_id, ts, v, unit_cache[symbol], flag, import_id)
                         for ts, v, flag in clean])
                    rows_loaded += max(cur.rowcount, 0)
                conn.commit()
                print(f"   {code:5s} sensor {s['id']}: read {len(raw)}, "
                      f"valid {len(clean)}, rejected {rejected}")

        cur.execute(
            "UPDATE import_log SET rows_read=%s, rows_loaded=%s, rows_rejected=%s, "
            "notes = notes || %s WHERE import_id=%s",
            (rows_read, rows_loaded, rows_rejected,
             f"; duplicate sensors skipped={skipped_duplicate_sensors}"
             f"; failed sensors={failed_sensors}", import_id))
        conn.commit()

    print(f"\nDone. read={rows_read}, loaded={rows_loaded}, rejected={rows_rejected}, "
          f"failed_sensors={failed_sensors}")
    if failed_sensors:
        print("Some sensors failed. Run the same command again to fill the gaps "
              "(existing rows are not duplicated).")


if __name__ == "__main__":
    main()
