# Vermont state-owned fibre extraction

This extractor publishes two semantic networks based on the source `BUILT` field. It retains all
302 `YES` routes in `built` and all 240 `NO` routes in `not_built_planned`.

- Source: Vermont VCGI `PSD State-Owned Fiber Routes`, MapServer layer 46
- Query: all fields and geometry, WGS84 GeoJSON
- Retrieval date: 2026-08-08
- Source SHA-256: `4d0d7f30e026301056827f2575da75983791fda712895f709c94e8d7ef254f26`
- License/use policy: Vermont Open Geodata Policy
- Restriction: direct, non-value-added reproduction with intent to sell is not permitted
- Citation: Vermont Center for Geographic Information, PSD State-Owned Fiber Routes

Run from this directory with Julia 1.12:

```sh
curl -L '<MapServer query URL recorded in the catalog>' -o downloads/source.geojson
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. extract.jl --source downloads/source.geojson --output output/vermont_state_fibre
julia --project=../.. ../../data_sources/validate.jl vermont_state_fibre output/vermont_state_fibre
```

Endpoints and exact shared geometry vertices form graph nodes. Visual crossings are not connected,
and the extractor does not snap nearby routes. It uses the source projected GIS length in metres.
If an exact shared interior vertex splits one source route, that length is apportioned by the WGS84
polyline share and the method remains `projected_geometry`. The source reports unknown accuracy and
precision and says the data are not suitable for detailed network design.
