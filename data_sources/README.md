# Data-source status

Each subdirectory is an independent Julia 1.12 extraction project. It is outside the root package
workspace and has no committed manifest. The repository MIT license covers extractor code only;
source snapshots and produced datasets retain their upstream terms.

## Released in `data-v1`

| Dataset ID | Published networks | Upstream data terms |
|---|---:|---|
| `afterfibre` | 2 | GNU GPL 2.0 implied by the historical application repository; data scope is ambiguous |
| `australia_submarine_cables_2021` | 16 | CC BY 4.0 |
| `cotes_darmor_2016` | 2 | French Open Licence 2.0 |
| `gold_coast_fibre` | 1 | CC BY 3.0 Australia |
| `grand_lyon_fibre` | 1 | French Open Licence 2.0 |
| `gregs_submarine_cable_map` | 279 | Literal “GNU GPL, version unspecified”; ambiguous version and scope |
| `internet_topology_zoo` | 85 | CC BY 4.0 |
| `open_undersea_cable_map` | 519 | CC BY-NC-SA 3.0 |
| `pdok_water_authority_telecom` | 2 | CC BY-NC-ND 4.0 used conservatively; conflicting CC0 notices and a non-derivative assertion |
| `topology_bench` | 105 | CC BY 4.0 |
| `vermont_state_fibre` | 2 | Vermont custom terms, including a direct-resale restriction |

The release contains 1,014 semantic networks. `Artifacts.toml` binds immutable, content-hash-named
archives from the data-only `data-v1` GitHub release. Read each extractor README and artifact
license before using or redistributing data.

## Complete but deferred extractor

- `openstreetmap_telecom`: The explicit-PBF ODbL extractor is complete and checked on the real
  Halifax extract. A reproducible full-planet snapshot and publication run are later work.

The deferred source has no artifact binding, catalog row, generated dataset page, or CI extraction
job.

## Excluded candidates

| Candidate | Exclusion reason |
|---|---|
| SNDlib | The available terms do not provide sufficiently clear redistribution rights for a packaged derivative, and many instances lack usable coordinates. |
| TopoHub | It aggregates sources with mixed upstream rights and does not provide one redistribution grant for all included data. |
| REPETITA | The usable topology inputs do not provide complete coordinate-bearing nodes for this schema. |
| InterTubes | Redistribution rights for a packaged normalized copy are not established. |
| Rocketfuel | The available inputs do not provide a redistributable, coordinate-complete source suitable for this schema. |
| Croatia Plinacro | The candidate download is not available through a stable automated public source, and it is not a telecommunications dataset. |
| California MMBI | Access to the usable source records is gated and does not support a reproducible public extraction. |
| Kansas Freestate | A stable automated source with clear redistribution rights is unavailable. |
| EMODnet | Mixed upstream rights prevent one clear redistribution grant for the candidate records. |
| NOAA MarineCadastre | The relevant published areas are polygons and cannot define cable graph topology. |

An exclusion is a version 1 publication decision. It is not a claim that the source has no value or
can never be used after better coordinates, access, or licensing evidence becomes available.
