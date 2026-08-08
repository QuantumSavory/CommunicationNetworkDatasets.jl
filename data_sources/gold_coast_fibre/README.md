# City of Gold Coast fibre extraction

This extractor publishes one approximate municipal network from all 128 source WFS features.

- Source: [City of Gold Coast Fibre Optic Cable](https://data.gov.au/data/dataset/fibre-optic-cable)
- Source request: data.gov.au WFS GeoJSON, EPSG:4326
- Retrieval date: 2026-08-08
- Exact response SHA-256: `4f979c39c6d467313cb0659e4a92294c5f8f53d4465a7713415e7dd525529721`
- License: Creative Commons Attribution 3.0 Australia (`CC-BY-3.0-AU`)
- Attribution: City of Gold Coast

Publisher warning: **“The information is provided to assist in field investigations. All locations,
dimensions and depths shown are to be confirmed on site.”**

Run from this directory with Julia 1.12:

```sh
curl -L '<WFS URL recorded in the package catalog>' -o downloads/source.geojson
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. extract.jl --source downloads/source.geojson --output output/gold_coast_fibre
julia --project=../.. ../../data_sources/validate.jl gold_coast_fibre output/gold_coast_fibre
```

The extractor creates nodes only at endpoints and exact shared source vertices. It does not snap
nearby geometry or connect visual crossings. It calculates WGS84 polyline distance in metres. The
result is approximate and is not suitable as a surveyed asset location.
