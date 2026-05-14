# Methodology — What's happening in my ZIP

## What this tool shows

For every New York City ZIP Code Tabulation Area (ZCTA), a count of selected events in a recent time window, plus a density figure (events per square mile of land area). Density normalization is the point: large neighborhoods generate more raw events simply because they are larger, and density lets small dense ZIPs and large outer-borough ZIPs be compared on the same footing.

## Geography

- **Boundaries.** New York City ZCTAs from NYC Open Data dataset [35j5-n34v](https://data.cityofnewyork.us/City-Government/ZIP-Code-Tabulation-Areas/35j5-n34v/about_data), last refreshed November 2024. The file ships with land area, water area, and a guaranteed-internal centroid.
- **Filter.** The dataset includes ZCTAs from the surrounding region (for example 07305 in Jersey City). The tool keeps only ZIPs in the ranges 10001–10499 and 11001–11697, which covers all five boroughs.
- **ZCTA vs USPS ZIP.** ZCTAs are the Census Bureau's approximation of USPS delivery ZIPs as polygons. Point-only ZIPs (PO boxes, single-building ZIPs like 10118 at the Empire State Building, unique-government ZIPs) do not appear as polygons here and are dropped from any event whose ZIP is not in the file.

## Land area

- `arealand` in the source file is in square meters. Converted to square miles by dividing by 2,589,988.11.
- Water area is ignored. Density is per square mile of land only.

## Time window

- The window selector (7, 30, 90 days) computes a UTC cutoff as "now minus N days" at request time, so values update on every page load and every selector change.
- The source date field differs per dataset (see below).

## Datasets

All datasets are queried live from the NYC Open Data SODA API, client-side, with a server-side `GROUP BY` on the ZIP field.

| Layer | Source | ID | Date field | ZIP field | Filter |
|---|---|---|---|---|---|
| 311 complaints | 311 Service Requests | [erm2-nwe9](https://data.cityofnewyork.us/Social-Services/311-Service-Requests-from-2010-to-Present/erm2-nwe9) | `created_date` | `incident_zip` | none |
| Marshal evictions | Evictions | [6z8x-wfk4](https://data.cityofnewyork.us/City-Government/Evictions/6z8x-wfk4) | `executed_date` | `eviction_zip` | none |
| Traffic crashes | Motor Vehicle Collisions — Crashes | [h9gi-nx95](https://data.cityofnewyork.us/Public-Safety/Motor-Vehicle-Collisions-Crashes/h9gi-nx95) | `crash_date` | `zip_code` | `zip_code IS NOT NULL` |
| DOHMH closures | DOHMH Restaurant Inspection Results | [43nn-pn8j](https://data.cityofnewyork.us/Health/DOHMH-New-York-City-Restaurant-Inspection-Results/43nn-pn8j) | `inspection_date` | `zipcode` | `action like 'Establishment Closed by DOHMH%'` — i.e. ordered-closure inspections only, not re-openings |
| Construction (sheds/scaffolds) | DOB NOW: Build — Approved Permits | [rbx6-tga4](https://data.cityofnewyork.us/Housing-Development/DOB-NOW-Build-Approved-Permits/rbx6-tga4) | `issued_date` | `zip_code` | `work_type in('Sidewalk Shed','Supported Scaffold','Suspended Scaffold')` |
| HPD housing violations | Housing Maintenance Code Violations | [wvxf-dwi5](https://data.cityofnewyork.us/Housing-Development/Housing-Maintenance-Code-Violations/wvxf-dwi5) | `novissueddate` | `zip` | none |
| OATH summonses | OATH Hearings Division Case Status | [6bgk-3dad](https://data.cityofnewyork.us/City-Government/OATH-Hearings-Division-Case-Status/6bgk-3dad) | `issue_date` | `respondent_zip` | none |
| Rat sightings | 311 Service Requests (subset) | [erm2-nwe9](https://data.cityofnewyork.us/Social-Services/311-Service-Requests-from-2010-to-Present/erm2-nwe9) | `created_date` | `incident_zip` | `complaint_type='Rodent' OR descriptor like '%Rat%'` |

### Counting rules

- Every row in the source dataset that matches the date window and filter is counted as one event. There is no deduplication.
- For 311, a complaint and its updates may both produce rows in the source file; behavior follows whatever the source publishes.
- For restaurant inspections, a single restaurant closed and re-inspected within the window will count once per closure-action inspection row.
- For crashes, a single crash is one row regardless of how many people or vehicles were involved.

### A note on cranes

A "cranes per ZIP" layer was investigated and dropped. The only crane-specific NYC Open Data file (Street Construction Permits — Cranes, `hcv3-zacv`) has not been updated since 2018 and exposes no ZIP, lat/lng, or address. The DOB Crane Information Repository, where current crane device permits actually live, is not published to Open Data. The Construction layer above (sidewalk sheds + scaffolds) is the closest available proxy for "where is heavy construction happening" — most cranes operate at sites that also have a shed or scaffold permit.

### Crime is intentionally excluded

NYPD complaint datasets do not carry a ZIP field. Mapping crime to ZCTAs requires a spatial join from lat/lng to polygon. That is out of scope for this client-side tool and slated for a follow-up.

## Color scale

- Five classes plus a zero class.
- Class breaks are quantiles of the non-zero density values for the currently selected layer and window. Quantile breaks rescale with each selection, so colors are comparable within a view but not across views.
- All hues for a given dataset are tints of a single base color, mixed with white at fixed steps (18, 36, 54, 72, 90 percent of base).

## Ranking

A ZIP's rank in the side panel is its position when all New York City ZIPs are sorted by density (events per square mile) for the current layer and window, descending. Ties take the earlier rank.

## Known limitations

- **Reporting bias.** Volumes reflect both what is happening and how often people report it. 311 in particular has well-documented reporting disparities by neighborhood.
- **Late-arriving data.** Open Data tables refresh on different cadences. Crashes and 311 typically lag a day or two; restaurant inspections can lag longer.
- **ZIP-only events get dropped.** Events whose ZIP is missing or not in the New York City ZCTA file are excluded.
- **No population denominator.** Density here is per square mile of land, not per resident. A per-capita variant is on the backlog.
- **No statistical inference.** The tool shows observed counts and rates, not significance tests, expected values, or anomaly detection.

## Updates and caching

The tool uses a two-tier strategy so the map never sits blank:

1. **Precomputed snapshots ship in the repo.** On first paint the page reads a static JSON file (for example, `data/311-30-counts.json`) and renders immediately. Snapshots are generated by `fetch_snapshots.sh`, which runs the same SODA queries described above and writes one file per layer-window combination, plus a complaint-type breakdown file for 311.
2. **Live refresh in the background.** After the snapshot paints, the page kicks off the same SODA query against NYC Open Data, waits for the response, and silently swaps in the live counts when they arrive. If the live query fails the snapshot stays on screen.

Switching layers or windows during a session uses an in-memory cache; toggling back to a previously-viewed combination is instant with no network call.

To refresh the bundled snapshots, run `./fetch_snapshots.sh` from the project directory. The shipped snapshots reflect the last manual regeneration; a "Last refresh" timestamp would be a useful next addition.

There is no server. The page is static; all queries are client-side.

## Source

Built for Vital City. Source code at the project repo. Open Data API documentation: <https://dev.socrata.com/>.
