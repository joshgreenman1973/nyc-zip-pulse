#!/usr/bin/env bash
# Precompute baseline snapshots for the four layers × three windows.
# Run from this directory. Output: data/{layer}-{days}.json
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p data

iso_n_days_ago() {
  if date -v -1d >/dev/null 2>&1; then
    date -u -v -"$1"d +"%Y-%m-%dT00:00:00"
  else
    date -u -d "$1 days ago" +"%Y-%m-%dT00:00:00"
  fi
}

# Every snapshot is written through this. A throttled, errored or empty
# response must abort the run -- a half-written data/ directory that still
# exits 0 is how a map goes stale while looking healthy.
FAILURES=0
EMPTY=""

get() {
  local url=$1 out=$2 label=$3
  local tmp="${out}.tmp"
  if ! curl -sS --fail-with-body --retry 3 --retry-delay 5 --max-time 120 "$url" -o "$tmp"; then
    echo "  FAIL  $label — HTTP error from Socrata" >&2
    rm -f "$tmp"
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  # Must be a JSON array. Socrata reports errors as a JSON *object*.
  local rows
  if ! rows=$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
if not isinstance(d, list):
    sys.stderr.write('not a JSON array: %s\n' % str(d)[:200])
    raise SystemExit(1)
print(len(d))
" "$tmp"); then
    echo "  FAIL  $label — response was not a row array" >&2
    rm -f "$tmp"
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  mv "$tmp" "$out"
  if [ "$rows" -eq 0 ]; then
    echo "  warn  $label — 0 rows"
    EMPTY="${EMPTY}${label}\n"
  else
    echo "  ok    $label — ${rows} rows"
  fi
}

urlencode() {
  python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$1"
}

fetch() {
  local key=$1 endpoint=$2 zipfield=$3 datefield=$4 extra=$5 days=$6
  local since
  since=$(iso_n_days_ago "$days")
  local where="${datefield} > '${since}' AND ${zipfield} IS NOT NULL"
  if [ -n "$extra" ]; then where="$where AND $extra"; fi
  local url="${endpoint}?\$select=${zipfield}%20as%20zip,count(*)%20as%20n&\$where=$(urlencode "$where")&\$group=${zipfield}&\$limit=2000"
  get "$url" "data/${key}-${days}-counts.json" "count $key ${days}d" || true

  # Type breakdown for 311 and noise (both expose complaint_type)
  if [ "$key" = "311" ] || [ "$key" = "noise" ]; then
    local urlb="${endpoint}?\$select=${zipfield}%20as%20zip,complaint_type%20as%20t,count(*)%20as%20n&\$where=$(urlencode "$where")&\$group=${zipfield},complaint_type&\$order=n%20desc&\$limit=20000"
    get "$urlb" "data/${key}-${days}-breakdown.json" "breakdown $key ${days}d" || true
  fi
}

for d in 7 30 90; do
  fetch "311"        "https://data.cityofnewyork.us/resource/erm2-nwe9.json" incident_zip created_date "" "$d"
  fetch "noise"      "https://data.cityofnewyork.us/resource/erm2-nwe9.json" incident_zip created_date "complaint_type like 'Noise%'" "$d"
  fetch "evictions"  "https://data.cityofnewyork.us/resource/6z8x-wfk4.json" eviction_zip executed_date "" "$d"
  fetch "crashes"    "https://data.cityofnewyork.us/resource/h9gi-nx95.json" zip_code crash_date "" "$d"
  fetch "closures"   "https://data.cityofnewyork.us/resource/43nn-pn8j.json" zipcode inspection_date "action like 'Establishment Closed by DOHMH%'" "$d"
  fetch "construction" "https://data.cityofnewyork.us/resource/rbx6-tga4.json" zip_code issued_date "work_type in('Sidewalk Shed','Supported Scaffold','Suspended Scaffold')" "$d"
  fetch "ratsConfirmed" "https://data.cityofnewyork.us/resource/p937-wjvj.json" zip_code inspection_date "(result='Rat Activity' OR result like 'Failed for Rat Activity%')" "$d"
  fetch "newBusinesses" "https://data.cityofnewyork.us/resource/ptev-4hud.json" zip submission_date "application_type='New'" "$d"
  fetch "sanitation" "https://data.cityofnewyork.us/resource/jz4z-kudi.json" violation_location_zip_code violation_date "issuing_agency in('SANITATION OTHERS','DOS - ENFORCEMENT AGENTS','SANITATION DEPT','SANITATION RECYCLING','SANITATION POLICE')" "$d"
  fetch "hpd"        "https://data.cityofnewyork.us/resource/wvxf-dwi5.json" zip novissueddate "" "$d"
  fetch "oath"       "https://data.cityofnewyork.us/resource/6bgk-3dad.json" respondent_zip issue_date "" "$d"
  fetch "rats"       "https://data.cityofnewyork.us/resource/erm2-nwe9.json" incident_zip created_date "(complaint_type='Rodent' OR descriptor like '%Rat%')" "$d"
  fetch "hpdComplaints" "https://data.cityofnewyork.us/resource/ygpa-z7cr.json" post_code received_date "" "$d"
  fetch "allInspections" "https://data.cityofnewyork.us/resource/43nn-pn8j.json" zipcode inspection_date "action IS NOT NULL" "$d"
  fetch "realEstate" "https://data.cityofnewyork.us/resource/usep-8jbt.json" zip_code sale_date "" "$d"
done

# Subway snapshots are built by a separate Python script (point-in-polygon join).
if [ -f fetch_subway.py ]; then
  echo "subway snapshots..."
  python3 fetch_subway.py
fi

# A run that failed any fetch must not stamp a fresh manifest -- the footer
# dates the numbers off this file, so stamping it after a partial run would
# relabel stale snapshots as current.
if [ "$FAILURES" -gt 0 ]; then
  echo "FAILED: ${FAILURES} fetch(es) errored — manifest not stamped, snapshots left as-is" >&2
  exit 1
fi

# The 311 30-day window is the flagship layer. Empty means the query shape or
# the dataset changed, not that New York stopped complaining.
if [ ! -s data/311-30-counts.json ] || \
   [ "$(python3 -c "import json;print(len(json.load(open('data/311-30-counts.json'))))")" -eq 0 ]; then
  echo "FAILED: 311 30-day snapshot is empty — refusing to publish" >&2
  exit 1
fi

if [ -n "$EMPTY" ]; then
  echo "note: some windows returned 0 rows:"
  printf "%b" "$EMPTY"
fi

# Snapshot manifest
python3 -c "
import json, datetime
manifest = { 'generated_at': datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00','Z') }
print(json.dumps(manifest))
" > data/manifest.json

echo "done."
