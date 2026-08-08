# Topology Bench extraction

This extractor publishes the 105 real topologies in the pinned Topology Bench archive. It omits all
synthetic layouts.

- Source: Zenodo record [13921775](https://zenodo.org/records/13921775), file
  `real_topologies.zip`
- Retrieval date: 2026-08-08
- Source SHA-256: `f2ad31ecc53378dd8992beedfe93141454bc1915257bd78e4e0dca3484ed45c8`
- Source MD5 reported by Zenodo: `bcb92010a9116f575851781436528eb0`
- License: Creative Commons Attribution 4.0 International (`CC-BY-4.0`)
- Attribution: Topology Bench authors and the per-topology sources retained by that collection
- Citation: Virgillito et al., *Topology Bench: Systematic Graph Based Benchmarking for Optical
  Networks*, Zenodo record 13921775 (2024)

Run from this directory with Julia 1.12:

```sh
curl -L https://zenodo.org/api/records/13921775/files/real_topologies.zip/content \
  -o downloads/real_topologies.zip
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. extract.jl --archive downloads/real_topologies.zip --output output/topology_bench
julia --project=../.. ../../data_sources/validate.jl topology_bench output/topology_bench
```

The extractor keeps each workbook as one semantic network, preserves node place/country fields and
source identifiers, removes self-loops, and combines parallel or reverse source records. It retains
the smallest valid published distance with source-ID tie-breaking. `Computed Length (km)` is the
publisher's scaled-Haversine value: 1.5 times Haversine below 1,000 km, 1,500 km from 1,000 through
1,200 km, and 1.25 times Haversine above 1,200 km. The extractor converts it to metres and labels it
`scaled_geodesic_endpoints`; it does not present it as measured fibre length.

Coordinates can be published or geocoded place coordinates. They are not verified equipment sites.
The generated `extraction_report.csv` provides one audit row for every source workbook.
