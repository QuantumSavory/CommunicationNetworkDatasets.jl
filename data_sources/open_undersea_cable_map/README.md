# Open Undersea Cable Map extraction

This extractor publishes one network for each cable system with at least two explicitly listed
landing points. The pinned snapshot contains 521 systems; 519 are published.

- Source: Steve Song's Open Undersea Cable Map fork at commit
  `e7903491e73bcac0d0b013b945897d10928483c4`
- Cable geometry SHA-256: `0cfca621aa2c4eb9e111d3ccb4f26f53462c87f8872df7ee639db3ceeaa000f9`
- Landing geometry SHA-256: `c01d94947316b616f0bfaf6326f4bec424c9d7b5480eeb617a885f6bd4ec8aef`
- Deterministic digest of the 521 individual cable metadata files:
  `1224999f6b73ee77ee267880a2d9132efb80f1c1efc591e2988698204daeaf99`
- Retrieval date: 2026-08-08
- License: CC BY-NC-SA 3.0 Unported
- Attribution: TeleGeography and Steve Song

Run from this directory with Julia 1.12:

```sh
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. extract.jl --source downloads/open_undersea_cable_map-e790349 \
  --output output/open_undersea_cable_map
julia --project=../.. ../../data_sources/validate.jl open_undersea_cable_map \
  output/open_undersea_cable_map
```

Landing membership comes only from each cable metadata file. Each landing is matched to the nearest
vertex of that cable's stylized route, and every match distance and published landing coordinate is
retained. The route vertex remains the public graph coordinate so route WKT is not altered. Exact
route endpoints, shared vertices, and explicit landing matches define topology; visual crossings
are not connected. The two `eac-c2c` landing records that map to one route vertex both remain
distinct, with the second retained as an audited isolate instead of inventing a source connection.
Multipart routes are split into graph edges, while their shape vertices remain in `geometry_wkt`.

Per-edge distances are geodesic calculations along the published or derived polyline. The reported
whole-system length is retained only as network metadata and is never assigned to an edge. Routes
are stylized, not surveyed alignments. The artifact and this derived documentation remain subject
to the upstream attribution, noncommercial, and share-alike terms.

The excluded systems are `darwin-jakarta-singapore-cable-djsc` and `sednalink-fibre`; each lists
only one landing point. See `extraction_report.csv`.
