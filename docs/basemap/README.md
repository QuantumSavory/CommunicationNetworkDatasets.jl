# Natural Earth offline basemap

This docs-only artifact contains one low-zoom raster tile generated from Natural Earth 1:110m land
polygons. Tyler tests and documentation use it without contacting a public tile service.

- Source: `ne_110m_land.geojson` from Natural Earth Vector tag `v5.1.2`
- Source URL: <https://github.com/nvkelso/natural-earth-vector/blob/v5.1.2/geojson/ne_110m_land.geojson>
- SHA-256: `9e0729ee253ca7d7a5c4ae9395fb1902264c5377c52e224d13dd85010e2835d9`
- Retrieval date: 2026-08-08
- Source status: public domain

Run with Julia 1.12 from the repository root:

```sh
julia --project=docs docs/basemap/build.jl --source staging/source-inspection/natural_earth/ne_110m_land.geojson \
  --output staging/artifacts/natural_earth_basemap
```

The script renders only exterior land rings into a 256 × 256 WGS84 overview tile. Small holes and
inland water are intentionally omitted at this docs-only scale. The result is modified from Natural
Earth and is not suitable for navigation or analysis.
