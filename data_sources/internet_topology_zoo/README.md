# Internet Topology Zoo extraction

This extractor publishes only networks for which every source node has a finite, in-range latitude
and longitude. A named network with any incomplete coordinate is recorded in
`extraction_report.csv` and excluded as a whole.

- Source: licensed Figshare deposit [30153949.v1](https://doi.org/10.25909/30153949.v1), file
  `graphml.tar.gz` (file ID 58057750)
- Retrieval date: 2026-08-08
- Source SHA-256: `7fba0617df71911a30df116478d1fc75758963c7b2569dd81818f47cf5b814c1`
- Source MD5 reported by Figshare: `bad498ebc81cea1e6d61b6f5c4f247d8`
- License: Creative Commons Attribution 4.0 International (`CC-BY-4.0`)
- Citation: Knight et al., *The Internet Topology Zoo*, IEEE Journal on Selected Areas in
  Communications 29(9), 2011; licensed Figshare deposit 30153949.v1

Run from this directory with Julia 1.12:

```sh
curl -L https://ndownloader.figshare.com/files/58057750 -o downloads/graphml.tar.gz
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. extract.jl --archive downloads/graphml.tar.gz --output output/internet_topology_zoo
julia --project=../.. ../../data_sources/validate.jl internet_topology_zoo output/internet_topology_zoo
```

The extractor preserves graph, node, and edge attributes as deterministic JSON source columns. It
normalizes each graph to a simple undirected graph, counts and removes self-loops, and combines
parallel and reverse-direction records. Per-edge distances are calculated from WGS84 endpoints and
labelled `geodesic_endpoints`; they are lower bounds rather than route or fibre lengths. Published
coordinates frequently came from place-name geocoding and do not identify verified equipment sites.
