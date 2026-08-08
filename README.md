# CommunicationNetworkDatasets.jl

`CommunicationNetworkDatasets.jl` supplies normalized, georeferenced communication-network data
for Julia simulations. The public graphs are simple and undirected, and every edge has a documented
distance in metres.

> [!IMPORTANT]
> The MIT license in this repository covers package code and extraction scripts only. Dataset
> artifacts retain their upstream licenses. Some artifacts require attribution, share-alike,
> noncommercial use, or other conditions. Inspect `datasets()` and each artifact's `README.md` and
> `LICENSE.md` before use or redistribution.

The package supports Julia 1.12 only. It is not registered in General and has no semantic package
release tag yet.

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
They do not run in CI. `openstreetmap_telecom` is implemented but intentionally has no v1 artifact.

## Development

Use Julia 1.12:

```sh
julia --project=test -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
julia --project=test/jet test/jet/runtests.jl
xvfb-run -a julia --project=test/tyler test/tyler/runtests.jl
xvfb-run -a julia --project=docs docs/make.jl
```

See [`data_sources/README.md`](data_sources/README.md) for released, deferred, and excluded sources.
