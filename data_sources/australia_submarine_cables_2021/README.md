# Australia's Submarine Telecommunication Cable Locations 2021 extraction

This extractor publishes 16 independent networks, one per named cable feature. Each has the two
endpoints of its own published route. It does not merge nearby endpoints or infer landing stations.

- Source: ArcGIS item [`bc1e7fb37fca40faa5dafbc8a5a4dc3c`](https://www.arcgis.com/home/item.html?id=bc1e7fb37fca40faa5dafbc8a5a4dc3c)
- Source layer: FeatureServer layer 0, queried as WGS84 GeoJSON with all fields
- Retrieval date: 2026-08-08
- Source SHA-256: `3e668e85e2a6ea9bac963ca002b73c3b622de71e5973f862fda869527488f6ae`
- Source count: 16 features
- License: Creative Commons Attribution 4.0 International (`CC-BY-4.0`)
- Attribution: Australian Communications and Media Authority © Commonwealth of Australia

Run from this directory with Julia 1.12:

```sh
curl -L '<FeatureServer query URL recorded in extract.jl>' -o downloads/source.geojson
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. extract.jl --source downloads/source.geojson --output output/australia_submarine_cables_2021
julia --project=../.. ../../data_sources/validate.jl australia_submarine_cables_2021 output/australia_submarine_cables_2021
```

Locations and routes are approximate and cover cable-protection zones rather than complete surveyed
systems. The extractor ignores the source `Shape__Length`, which is an angular value in degrees. It
calculates metre distance along each WGS84 route and labels it `geodesic_polyline`. The Telstra
Endeavour geometry is multipart only because it is split at the antimeridian; its two parts remain
one route and one graph edge.
