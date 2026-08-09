# Artifact schema

Every published CSV uses UTF-8, a header row, deterministic row order, empty fields for missing
values, and ISO 8601 dates. Identifiers match `[a-z][a-z0-9_]*`. Core columns must occur first in
the order below. A source can append documented snake-case columns. SI-valued columns use suffixes
such as `_m`, `_s`, and `_bps`; WGS84 coordinates use decimal degrees.

## `data/datasets.csv`

`schema_version`, `dataset_id`, `artifact_name`, `name`, `description`, `upstream_url`,
`upstream_version`, `upstream_checksum`, `retrieval_date`, `extraction_script_commit`,
`license_identifier`, `license_url`, `citation`, `attribution`, `redistribution_notes`, and
`network_count`.

This file is package data and is the only discovery input used by `datasets()`. The call does not
resolve or download an artifact.

## `networks.csv`

`schema_version`, `network_id`, `name`, `description`, `source_reference`, `node_count`,
`edge_count`, `component_count`, `original_directed`, `coordinate_method`, `distance_method`,
`license_identifier`, `license_url`, `citation`, `attribution`, `redistribution_notes`,
`source_node_count`, `source_edge_count`, `self_loops_removed`, and `parallel_edges_combined`.

`distance_method` is one allowed edge method or `mixed`. A semantic network can contain multiple
connected components; the extractor must keep them and report `component_count`.

## `nodes.csv`

`vertex`, `node_id`, `name`, `longitude_deg`, `latitude_deg`, `coordinate_method`, and `note`.

`vertex` is contiguous from 1 through `n`. Every published node has a finite WGS84 coordinate in
range. Geometry-derived endpoints and source-geometry junctions are nodes. An extractor does not
connect two lines at a visual crossing unless the source has a shared geometry vertex or an
explicit asset there.

## `edges.csv`

`edge_id`, `src_vertex`, `dst_vertex`, `name`, `distance_m`, `distance_method`, `distance_note`,
`contributing_source_edge_count`, and `geometry_wkt`.

Each edge is canonical (`src_vertex < dst_vertex`) and unique. Self-loops are absent. Parallel and
reverse source records are grouped semantically; the retained record has the smallest valid
distance, with its stable source ID as a deterministic tie-breaker. Source-specific columns retain
all contributing IDs and attributes.

Every edge has one finite, nonnegative distance in metres. Allowed methods are `measured`,
`reported`, `source_calculated`, `projected_geometry`, `geodesic_polyline`,
`geodesic_endpoints`, `scaled_geodesic_endpoints`, and `modeled`. A reported whole-system submarine
cable length is network metadata and is never assigned to an individual edge.

When present, `geometry_wkt` is a canonical EPSG:4326 `LINESTRING`. Multipart routes are split into
graph edges. Intermediate shape vertices remain in WKT and are not simulator nodes.
