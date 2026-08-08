# Côtes-d'Armor 2016 fibre extraction

This extractor joins the three publisher tables and creates separate artery and optical-cable
networks.

| Input | Rows | SHA-256 |
|---|---:|---|
| Nodes | 732 | `9f14059ff85ecbfb14d60f9a2bfe12cb3fcf41d741c5ac96b38f5344eff30bc0` |
| Arteries | 692 | `c25691c121ef85d9cb1c4ab475d39d2bd1c4bbd302781503e9b7cd3fc5e22c58` |
| Optical cables | 103 | `de8330b160860808a5d4d19957fce9d7d58cd5842cdb6ba60411bee65516c5f6` |

- Source: Département des Côtes-d'Armor Dat'Armor raw CSV endpoints
- Retrieval date: 2026-08-08
- License: French Open Licence 2.0 (`etalab-2.0`)
- Attribution: Département des Côtes-d'Armor / Dat'Armor

Run from this directory with Julia 1.12:

```sh
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. extract.jl --nodes downloads/nodes.csv --arteries downloads/arteries.csv \
  --cables downloads/cables.csv --output output/cotes_darmor_2016
julia --project=../.. ../../data_sources/validate.jl cotes_darmor_2016 output/cotes_darmor_2016
```

The raw files begin with two UTF-8 byte-order marks; the extractor removes only leading marks. It
checks all endpoint identifiers against point assets and deterministically repairs disagreements by
a nearest geometry match within 5 m. If no point is within that tolerance, it creates a
coordinate-bearing geometry endpoint. Every repair, including malformed or shifted publisher IDs,
is recorded in `extraction_report.csv`.

Arteries use publisher `AR_LONG` as `reported`. Optical cables prefer `CA_LG_MES` as `measured`,
then `CA_LG_CAL` as `source_calculated`, then geometry. The schemas do not declare a unit, but values
and geometry indicate metres; that assumption is retained in every distance note. The known reverse
parallel pair is collapsed under the same deterministic minimum-distance/source-ID rule as all other
parallel records.
