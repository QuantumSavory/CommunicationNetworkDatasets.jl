# Greg's Global Submarine Cable Map extraction

This extractor publishes the 279 of 285 cable features that match at least two station records.

- Source: ArcGIS item [`00ae4550cd9b41dd93d33972bb8520bb`](https://www.arcgis.com/home/item.html?id=00ae4550cd9b41dd93d33972bb8520bb)
- Cable layer: 285 features; SHA-256 `a109fc04c233c3df5a7aadcd327bbc66f177c7ddf7c89f78604e8e3a92bc6cba`
- Station layer: 737 points; SHA-256 `8c041bac65faec836ae9f1f144a6ea09388ae346d9a8ab5692f5799097293bb8`
- Retrieval date: 2026-08-08; source data were last edited in 2018
- Source notice, literally: **“GNU GENERAL PUBLIC LICENSE”**
- Attribution: Greg Mahlknecht / Greg's Global Submarine Cable Map

> **License ambiguity:** The publisher names GNU GPL but gives no version and does not state clearly
> how the software-oriented terms apply to the data. This project records the license as the literal
> non-SPDX notice **“GNU GPL, version unspecified”**. Users must assess the ambiguity before use or
> redistribution.

Run from this directory with Julia 1.12:

```sh
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. extract.jl --cables downloads/cables.geojson \
  --stations downloads/stations.geojson --output output/gregs_submarine_cable_map
julia --project=../.. ../../data_sources/validate.jl gregs_submarine_cable_map output/gregs_submarine_cable_map
```

Stations match only to published route vertices within 25 m. The artifact records every matching
distance. Route endpoints and exact shared vertices supply other branch nodes; visual crossings are
not connected. Co-located source station records remain distinct nodes, including isolates when a
route vertex is already assigned to another record. Routes and station locations are approximate.
Per-edge distances are geodesic polyline calculations. `Distance_K` is a reported whole-system total
and remains network metadata only.

The six excluded cable FIDs are 124, 230, 231, 258, 269, and 277. Their nearest unmatched stations
are beyond 25 m or each feature has only one matched station. See `extraction_report.csv`.
