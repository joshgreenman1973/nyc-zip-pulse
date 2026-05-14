# NYC ZIP Pulse

A live map of New York City by ZIP code, normalized per square mile of land area so dense neighborhoods don't automatically dominate.

Seven data layers:
- 311 complaints
- Marshal evictions
- Traffic crashes
- Restaurant closures
- HPD housing violations
- OATH summonses (DOB/sanitation/health)
- Rat sightings

Time windows: 7, 30, 90 days. All data pulled live from NYC Open Data, with bundled snapshots for instant first paint.

See [methodology.md](methodology.md) for sources, counting rules, and limitations.

## Local development

```
python3 -m http.server 8830
```

To refresh the bundled snapshots:

```
./fetch_snapshots.sh
```
