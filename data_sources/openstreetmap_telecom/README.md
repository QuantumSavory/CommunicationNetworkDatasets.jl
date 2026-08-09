# OpenStreetMap telecommunications extraction

This independent extractor accepts an explicit OpenStreetMap PBF file. It is complete, but its
output is deferred from the version 1 catalog. A reproducible full-planet run is a later task.

- Source: [OpenStreetMap](https://www.openstreetmap.org/)
- Test snapshot: [BBBike Halifax extract](https://download.bbbike.org/osm/bbbike/Halifax/)
- Test retrieval date: 2026-08-08
- Test PBF SHA-256: `bff0260c7aa0950d79e90e80e6560c6e101c56042c9fed8c1e0b7a5d87cfce83`
- Test PBF MD5: `bd4540f827834ae6dc14474dc6b7a9f9`
- License: Open Data Commons Open Database License 1.0 (`ODbL-1.0`)
- Attribution: © OpenStreetMap contributors

Run from this directory with Julia 1.12:

```sh
curl -L https://download.bbbike.org/osm/bbbike/Halifax/Halifax.osm.pbf \
    -o downloads/Halifax.osm.pbf
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. extract.jl \
    --source downloads/Halifax.osm.pbf \
    --source-reference 'BBBike Halifax PBF retrieved 2026-08-08' \
    --output output/openstreetmap_telecom
julia --project=../.. ../../data_sources/validate.jl \
    openstreetmap_telecom output/openstreetmap_telecom
```

The extractor retains ways for which `telecom:medium=fibre` and either `communication=line` or
`telecom=cable`. It rejects `area=yes` and any feature with a `building` tag. It creates topology
nodes only at selected-way endpoints and at OSM node IDs shared by distinct selected ways. Equal
coordinates do not create a junction, and visual crossings remain disconnected unless they share
an OSM node. Intermediate way nodes remain in `geometry_wkt`.

Every selected way is split at topology nodes. The extractor removes self-loops, combines parallel
or reverse segments, retains the shortest geodesic polyline with deterministic source-ID
tie-breaking, and records all contributing way and segment IDs. Distances are calculated in metres
along the WGS84 source geometry.

The pinned Halifax check selects 2,577 ways and 27,187 referenced nodes. It publishes 4,744 graph
nodes, 4,695 graph edges, and 358 components after removing 4 self-loops and combining 38 parallel
segments. The PBF header is provenance only; the ODbL grant and attribution come from OpenStreetMap
and the extract provider documentation.
