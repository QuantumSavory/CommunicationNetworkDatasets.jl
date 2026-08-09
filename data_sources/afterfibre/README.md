# AfTerFibre extraction

This extractor reads a pinned local snapshot of the AfTerFibre TileJSON and Mapbox Vector Tile
service. It creates separate semantic networks for `live=true` and `live=false`. The extractor is
complete, but no artifact, catalog row, or generated documentation page is published because the
dataset redistribution license is not established.

- Source application: [AfTerFibre](https://afterfibre.opentelecomdata.org/)
- TileJSON: `https://d316kar6yg8hyq.cloudfront.net/africa-fiber.json`
- Snapshot zoom: 8
- Retrieval date: 2026-08-08
- TileJSON SHA-256: `a33196caad678c330ca73aed7fbff93e51eb49fbf921180e88829d87a8987e39`
- Tile inventory SHA-256: `18c97ae3e00282c4f65893553901138177f2a9b08900f04c7f95374b80ca3c69`
- Snapshot extent: 2,968 requests; 937 nonempty tiles and 2,031 empty responses
- Dataset license: `NOASSERTION`; written clarification is required before publication
- Requested attribution: AfTerFibre / Open Telecom Data

Run from this directory with Julia 1.12:

```sh
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. snapshot.jl --output downloads/afterfibre-z8
julia --project=. extract.jl \
    --source downloads/afterfibre-z8 \
    --output output/afterfibre
julia --project=../.. ../../data_sources/validate.jl afterfibre output/afterfibre
```

The snapshot command requests all zoom-8 tiles intersecting the declared TileJSON bounds with
compression disabled. It records the status, byte count, SHA-256, and ETag for every request. The
extractor verifies the complete inventory before decoding any tile.

Mapbox feature IDs are zero in this service, so fragments are grouped by the stable `cartodb_id`
property. Geometry remains in world-tile coordinates while each fragment is clipped to its tile's
non-buffered core, duplicate buffered fragments are removed, and maximal routes are stitched. Tile
boundaries do not become graph nodes. The two
`live` values are normalized independently. Exact shared geometry vertices create junctions;
visual crossings without a shared source vertex remain disconnected. Self-loops are removed and
parallel routes are combined with deterministic shortest-distance and source-ID selection.

Coordinates are WGS84 values derived from Web Mercator tile coordinates. Distances use
`geodesic_polyline` along the stitched zoom-8 geometry. The source routes are manually traced and
tile geometry is simplified, so neither coordinates nor distances are surveyed asset data.

The pinned check finds 121 `live=true` and 23 `live=false` source identifiers. It produces 7,798
nodes and 6,366 edges for the live network, and 266 nodes and 139 edges for the not-live network.
No source record is silently excluded. The extraction report marks every record as deferred because
publication rights remain unresolved.
