# CommunicationNetworkDatasets.jl

CommunicationNetworkDatasets.jl provides normalized, coordinate-bearing communication-network
graphs. Dataset discovery does not download artifacts. A dataset artifact is downloaded only when
`networks` or `load_network` needs it.

All public graphs are fresh, simple, and undirected. Edge distances are finite, nonnegative values
in metres. The artifact schema documents the normalization contract and the generated dataset
pages report complete source and network metadata.

Package code and extraction scripts use the MIT License. Each dataset artifact retains its
upstream license. Review the license, attribution, modification, and redistribution statements on
the relevant dataset page before using or redistributing artifact data or generated plots.

## Basic use

```julia
using CommunicationNetworkDatasets

catalog = datasets()
network_catalog = networks(catalog.dataset_id[1])
network = load_network(catalog.dataset_id[1], network_catalog.network_id[1])
```

To plot a network, load Tyler and one Makie backend before calling `plot_network`. The returned map
belongs to the caller. Wait for it before saving and close it when it is no longer needed.

```julia
using CairoMakie, Tyler

result = plot_network(catalog.dataset_id[1], network_catalog.network_id[1])
try
    wait(result.map)
    save("network.png", result.figure)
finally
    close(result.map)
end
```
