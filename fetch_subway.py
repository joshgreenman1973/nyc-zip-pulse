#!/usr/bin/env python3
"""Build subway-ridership snapshots, aggregated to NYC ZCTAs.

The MTA Subway Hourly Ridership feed is station-keyed with lat/lng. To
present it on the ZIP-pulse map we:

  1. Fetch the set of station complexes appearing in a recent window
     (gives us the lat/lng of every active station complex).
  2. Point-in-polygon each station against the NYC ZCTA file so each
     station gets assigned to a ZIP.
  3. Query total ridership per station for each window (7/30/90 days)
     and the matching prior window, then sum to ZIP.

Writes:
  data/subway-{N}-counts.json
  data/subway-{N}-prior-counts.json
"""

from __future__ import annotations

import datetime
import json
import os
import sys
import time
import urllib.parse
import urllib.request

from shapely.geometry import shape, Point

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
os.makedirs(DATA, exist_ok=True)

MTA = "https://data.ny.gov/resource/5wq4-mkjj.json"
ZCTA = "https://data.cityofnewyork.us/resource/35j5-n34v.geojson?$limit=500"


def iso_days_ago(days: int) -> str:
    return (datetime.datetime.utcnow() - datetime.timedelta(days=days)).strftime(
        "%Y-%m-%dT00:00:00"
    )


def fetch_json(url: str, attempts: int = 4):
    """Socrata read timeouts are common on the big MTA table; retry with
    backoff so one slow response doesn't abort the whole nightly run."""
    last = None
    for i in range(attempts):
        try:
            with urllib.request.urlopen(url, timeout=180) as r:
                return json.loads(r.read())
        except Exception as e:                      # noqa: BLE001 - retry anything
            last = e
            wait = 5 * (i + 1)
            print(f"  retry {i + 1}/{attempts - 1} in {wait}s ({e})")
            time.sleep(wait)
    raise RuntimeError(f"giving up after {attempts} attempts: {last}")


def load_zctas():
    """Return list of (zip5, polygon) restricted to NYC ZIP ranges."""
    print("Loading ZCTAs...")
    fc = fetch_json(ZCTA)
    out = []
    for feat in fc["features"]:
        z = feat["properties"]["zcta5"]
        try:
            zn = int(z)
        except ValueError:
            continue
        if not ((10001 <= zn <= 10499) or (11001 <= zn <= 11697)):
            continue
        poly = shape(feat["geometry"])
        out.append((z, poly))
    print(f"  {len(out)} NYC ZCTAs")
    return out


def fetch_station_list(window_days: int = 30):
    """Distinct station complexes that show up in the recent window."""
    since = iso_days_ago(window_days)
    where = f"transit_timestamp > '{since}'"
    params = {
        "$select": "station_complex_id, station_complex, latitude, longitude",
        "$where": where,
        "$group": "station_complex_id, station_complex, latitude, longitude",
        "$limit": "1000",
    }
    url = MTA + "?" + urllib.parse.urlencode(params)
    print(f"Fetching station list (window={window_days}d)...")
    stations = fetch_json(url)
    print(f"  {len(stations)} stations")
    return stations


def assign_zips(stations, zctas):
    out = {}
    misses = 0
    for s in stations:
        try:
            lat = float(s["latitude"])
            lng = float(s["longitude"])
        except (KeyError, ValueError, TypeError):
            misses += 1
            continue
        p = Point(lng, lat)
        match = None
        for z, poly in zctas:
            if poly.contains(p):
                match = z
                break
        if match is None:
            misses += 1
            continue
        out[s["station_complex_id"]] = match
    print(f"  matched {len(out)} stations to ZIPs, {misses} unmatched")
    return out


def fetch_station_totals(start_iso: str, end_iso: str | None = None):
    """sum(ridership) grouped by station_complex_id within a date range."""
    parts = [f"transit_timestamp > '{start_iso}'"]
    if end_iso:
        parts.append(f"transit_timestamp <= '{end_iso}'")
    where = " AND ".join(parts)
    params = {
        "$select": "station_complex_id, sum(ridership) as n",
        "$where": where,
        "$group": "station_complex_id",
        "$limit": "2000",
    }
    url = MTA + "?" + urllib.parse.urlencode(params)
    return fetch_json(url)


def rollup_by_zip(rows, station_to_zip):
    z = {}
    for r in rows:
        sid = r.get("station_complex_id")
        zip5 = station_to_zip.get(sid)
        if not zip5:
            continue
        try:
            n = int(round(float(r.get("n", 0))))
        except ValueError:
            continue
        z[zip5] = z.get(zip5, 0) + n
    return z


def write_counts(path, mapping):
    rows = [{"zip": z, "n": str(n)} for z, n in mapping.items()]
    rows.sort(key=lambda r: -int(r["n"]))
    with open(path, "w") as f:
        json.dump(rows, f)
    print(f"  wrote {path} ({len(rows)} ZIPs, top={rows[0] if rows else None})")


def main():
    zctas = load_zctas()
    stations = fetch_station_list(window_days=30)
    station_to_zip = assign_zips(stations, zctas)

    for days in (7, 30, 90):
        # Current window
        start = iso_days_ago(days)
        print(f"\nCurrent window ({days}d) starting {start}...")
        cur_rows = fetch_station_totals(start)
        cur_zip = rollup_by_zip(cur_rows, station_to_zip)
        write_counts(os.path.join(DATA, f"subway-{days}-counts.json"), cur_zip)

        # Prior same-length window
        start_prior = iso_days_ago(days * 2)
        end_prior = iso_days_ago(days)
        print(f"Prior window ({days}d) {start_prior} -> {end_prior}...")
        prior_rows = fetch_station_totals(start_prior, end_prior)
        prior_zip = rollup_by_zip(prior_rows, station_to_zip)
        write_counts(
            os.path.join(DATA, f"subway-{days}-prior-counts.json"), prior_zip
        )


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print("FAILED:", e, file=sys.stderr)
        sys.exit(1)
