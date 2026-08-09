# La Fibre Grand Lyon extraction

This extractor publishes the metropolitan public-initiative fibre layer as one network.

- Source: Métropole de Lyon WFS layer `tel_telecom.fibre_rip_thd`
- Source request: [WFS 2.0 GeoJSON in EPSG:4326](https://data.grandlyon.com/geoserver/metropole-de-lyon/ows?SERVICE=WFS&VERSION=2.0.0&request=GetFeature&typename=metropole-de-lyon%3Atel_telecom.fibre_rip_thd&outputFormat=application%2Fjson&SRSNAME=EPSG%3A4326)
- Retrieval date: 2026-08-08
- Exact response SHA-256: `11fd3773ef36ed41c2075aa752b506b79d2704bebfc3f79863ac0afaa69ccfdd`
- Source count: 11,386 features
- License: French Open Licence 2.0 (`etalab-2.0`)
- Attribution: Métropole de Lyon

Run from this directory with Julia 1.12:

```sh
curl -fsSL 'https://data.grandlyon.com/geoserver/metropole-de-lyon/ows?SERVICE=WFS&VERSION=2.0.0&request=GetFeature&typename=metropole-de-lyon%3Atel_telecom.fibre_rip_thd&outputFormat=application%2Fjson&SRSNAME=EPSG%3A4326' \
  -o downloads/source.geojson
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. extract.jl --source downloads/source.geojson --output output/grand_lyon_fibre
julia --project=../.. ../../data_sources/validate.jl grand_lyon_fibre output/grand_lyon_fibre
```

The WFS service is mutable and can add response timestamps. The extractor therefore requires the
exact archived response checksum. It creates nodes at endpoints and exact shared source-geometry
vertices, keeps intermediate shape points in WKT, does not connect visual crossings, and applies no
coordinate snapping. Distances are WGS84 geodesic polyline calculations, not reported or measured
fibre lengths.
