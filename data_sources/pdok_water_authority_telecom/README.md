# PDOK water-authority telecommunications and duct data

This extractor publishes telecommunications-cable and duct networks from the harmonized
INSPIRE dataset. The source rights contain conflicting Creative Commons notices; see
[LICENSE.md](LICENSE.md) before use or redistribution.

## Source snapshot

Het Waterschapshuis publishes the harmonized INSPIRE dataset through PDOK. The pinned
snapshot is the ATOM file `UtilityandGovernmentalServices.gml`:

- download: <https://service.pdok.nl/hwh/waterschappen-nutsdiensten-en-overheidsdiensten/atom/downloads/UtilityandGovernmentalServices.gml>
- dataset feed: <https://service.pdok.nl/hwh/waterschappen-nutsdiensten-en-overheidsdiensten/atom/waterschappen_nutsoverheidsdiensten_inspire_geharmoniseerd.xml>
- feed update: `2026-08-20T00:00:00Z`
- HTTP Last-Modified: `2026-08-20T10:38:59Z`
- size: `92,448,221` bytes
- SHA-256: `b4c949906aa104639d6bd35a96ce148d691cea914c118bf534a48c4f99a20bd6`

The source contains 2,074 `TelecommunicationsCable` features, 3,509 `Duct` features,
and 7,484 `Manhole` features. It also contains electricity cables, sewer pipes, and
environmental-management facilities, which this extractor excludes.

The service provides WMS and ATOM, but no bulk WFS or OGC API Features endpoint. The
extractor therefore reads the pinned ATOM GML file directly.

## Run the extractor

Use Julia 1.12 and the independent source environment:

```sh
julia --project=data_sources/pdok_water_authority_telecom -e \
  'using Pkg; Pkg.instantiate()'

julia --project=data_sources/pdok_water_authority_telecom \
  data_sources/pdok_water_authority_telecom/extract.jl \
  --gml /absolute/path/to/UtilityandGovernmentalServices.gml \
  --output /absolute/path/to/output/pdok_water_authority_telecom

julia --project=. data_sources/validate.jl \
  pdok_water_authority_telecom /absolute/path/to/output/pdok_water_authority_telecom
```

Do not commit the source file or output directory. No manifest is committed for this
independent extraction environment.

## Transformations

The ATOM entry labels the download EPSG:28992, but every target geometry in the file
declares `urn:ogc:def:crs:EPSG::4258`. Its three-dimensional coordinate tuples use the
EPSG axis order `(latitude, longitude, z)`. The extractor validates that declaration,
swaps to `(longitude, latitude)`, and uses PROJ with network access disabled to:

1. transform EPSG:4258 coordinates to EPSG:28992 for topology matching and distances;
2. transform EPSG:4258 coordinates to EPSG:4326 for public node coordinates and route
   `geometry_wkt`;
3. ignore the third ordinate because the source supplies no usable vertical CRS.

Each multipart feature is split into deterministic source parts. Graph nodes are route
endpoints, shared source vertices, and attached manholes. Visual crossings are not
connected. Distances are the sums of two-dimensional segment lengths in EPSG:28992 and
use `projected_geometry`. The source-specific `geometry_epsg28992_wkt` column retains a
projected representation in addition to the required EPSG:4326 `geometry_wkt`.

The output has two simple undirected networks:

| Network ID | Nodes | Edges | Components |
|---|---:|---:|---:|
| `telecommunications_cables` | 3,034 | 1,958 | 1,107 |
| `ducts` | 7,076 | 3,602 | 3,475 |

Neither network is described as optical fibre. The source cable-material and duct-width
fields are empty in this snapshot.

## Manholes, repairs, and exclusions

The source `inNetwork` and `link` elements are empty. A manhole is retained only when its
EPSG:28992 position equals a vertex of the relevant line layer within `1e-6` metre. This
tolerance represents numerical equality, not physical snapping. Four manholes attach to
the telecommunications layer and 35 attach to the duct layer.

Three duct manholes require a sub-micrometre numerical-coordinate repair:

- `NL.WBHCODE.25.Put.200514`
- `NL.WBHCODE.25.Put.200251`
- `NL.WBHCODE.15.Put.201081`

The extractor asserts these identifiers and writes every inclusion, repair, and
exclusion decision to `extraction_report.csv`. Unattached manholes are not published as
isolated graph nodes. It also removes 270 telecommunications self-loops and six duct
self-loops, then combines 194 and 12 parallel edge records respectively.

## Rights and attribution

Attribution: Het Waterschapshuis and the contributing Dutch water authorities, delivered
through PDOK. The ATOM feed and service record state CC0, while the underlying dataset
metadata states CC BY-NC-ND 4.0 and includes navigation and legal-evidence limitations.
The artifact catalog conservatively records `CC-BY-NC-ND-4.0`. For licensing purposes,
CommunicationNetworkDatasets.jl presents the artifact as a non-derivative technical-format
representation and asserts no rights in the upstream data. See [LICENSE.md](LICENSE.md).
