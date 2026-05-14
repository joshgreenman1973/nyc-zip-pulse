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

fetch() {
  local key=$1 endpoint=$2 zipfield=$3 datefield=$4 extra=$5 days=$6
  local since
  since=$(iso_n_days_ago "$days")
  local where="${datefield} > '${since}' AND ${zipfield} IS NOT NULL"
  if [ -n "$extra" ]; then where="$where AND $extra"; fi
  local url="${endpoint}?\$select=${zipfield}%20as%20zip,count(*)%20as%20n&\$where=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$where")&\$group=${zipfield}&\$limit=2000"
  echo "  count: $key $days days"
  curl -sS "$url" > "data/${key}-${days}-counts.json"

  # Type breakdown only for 311
  if [ "$key" = "311" ]; then
    local urlb="${endpoint}?\$select=${zipfield}%20as%20zip,complaint_type%20as%20t,count(*)%20as%20n&\$where=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$where")&\$group=${zipfield},complaint_type&\$order=n%20desc&\$limit=20000"
    echo "  breakdown: $key $days days"
    curl -sS "$urlb" > "data/${key}-${days}-breakdown.json"
  fi
}

for d in 7 30 90; do
  fetch "311"        "https://data.cityofnewyork.us/resource/erm2-nwe9.json" incident_zip created_date "" "$d"
  fetch "evictions"  "https://data.cityofnewyork.us/resource/6z8x-wfk4.json" eviction_zip executed_date "" "$d"
  fetch "crashes"    "https://data.cityofnewyork.us/resource/h9gi-nx95.json" zip_code crash_date "" "$d"
  fetch "closures"   "https://data.cityofnewyork.us/resource/43nn-pn8j.json" zipcode inspection_date "action like 'Establishment Closed by DOHMH%'" "$d"
  fetch "construction" "https://data.cityofnewyork.us/resource/rbx6-tga4.json" zip_code issued_date "work_type in('Sidewalk Shed','Supported Scaffold','Suspended Scaffold')" "$d"
  fetch "hpd"        "https://data.cityofnewyork.us/resource/wvxf-dwi5.json" zip novissueddate "" "$d"
  fetch "oath"       "https://data.cityofnewyork.us/resource/6bgk-3dad.json" respondent_zip issue_date "" "$d"
  fetch "rats"       "https://data.cityofnewyork.us/resource/erm2-nwe9.json" incident_zip created_date "(complaint_type='Rodent' OR descriptor like '%Rat%')" "$d"
done

# Snapshot manifest
python3 -c "
import json, os, datetime
manifest = { 'generated_at': datetime.datetime.utcnow().isoformat() + 'Z' }
print(json.dumps(manifest))
" > data/manifest.json

echo "done."
