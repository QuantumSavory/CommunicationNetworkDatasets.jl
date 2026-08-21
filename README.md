# CommunicationNetworkDatasets.jl

`CommunicationNetworkDatasets.jl` supplies normalized, georeferenced communication-network data
for Julia simulations. The public graphs are simple and undirected, and every edge has a documented
distance in metres.

> [!IMPORTANT]
> The MIT license in this repository covers package code and extraction scripts only. Dataset
> artifacts retain their upstream licenses. Some artifacts require attribution, share-alike,
> noncommercial use, or other conditions. Inspect `datasets()` and each artifact's `README.md` and
> `LICENSE.md` before use or redistribution.

The package requires Julia 1.12 or later within Julia 1.x.

```julia
using CommunicationNetworkDatasets

datasets()                         # local catalog; downloads nothing
networks("topology_bench")         # installs that lazy artifact when first used
network = load_network("topology_bench", "abilene")
network.graph
network.distances                  # Dict{Edge{Int},Float64}, in metres
```

Plotting is an extension:

```julia
using CairoMakie, Tyler
view = plot_network("topology_bench", "abilene")
save("abilene.png", view.figure)
close(view.map) # the caller owns the Tyler map
```

## Data contract

The tracked [`data/datasets.csv`](data/datasets.csv) is the zero-download dataset catalog. Each
catalog row names a lazy artifact with this layout:

```text
networks.csv
README.md
LICENSE.md
extraction_report.csv        # optional audit and exclusion report
networks/<network_id>/
    nodes.csv
    edges.csv
```

Schema version 1 is documented in [`docs/src/schema.md`](docs/src/schema.md). Loaders validate
published data and never repair it. Unknown identifiers raise `ArgumentError` and point to the
applicable discovery function.

Source-specific extraction projects and their exact provenance are under [`data_sources`](data_sources).
They do not run in CI. The OpenStreetMap extractor is implemented but intentionally has no v1
artifact; [`data_sources/README.md`](data_sources/README.md) records the publication blocker and
excluded candidates.

## Development

Use Julia 1.12:

```sh
julia --project=. -e 'using Pkg; Pkg.test()'
julia --project=. -e 'using Pkg; Pkg.test(; test_args=["jet"])'
julia --project=. -e 'using Pkg; Pkg.test(; test_args=["tyler"])'
julia --project=docs docs/make.jl
```

The Tyler and documentation jobs use the QuantumSavory-hosted CI tile service. When
`TILE_CI_KEY` is present, the jobs authenticate with it; local runs without the key use the
rate-limited anonymous service.

See [`data_sources/README.md`](data_sources/README.md) for released, deferred, and excluded sources.
