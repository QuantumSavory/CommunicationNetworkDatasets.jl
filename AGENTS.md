# CommunicationNetworkDatasets.jl development

This repository contains package code, independently runnable source extractors, and bindings
for separately licensed dataset artifacts.

- Use Julia 1.12 and the declared project for all package, test, documentation, and extraction
  work. Do not commit manifests.
- Never edit a released artifact. Change and commit the applicable extractor first, run it into
  ignored staging, validate the result, then publish a new immutable archive.
- Keep each `data_sources/<dataset_id>` project independent. It is intentionally outside the root
  workspace.
- Keep discovery in `data/datasets.csv`; `datasets()` must never cause an artifact download.
- Keep the public API limited to `datasets`, `networks`, `load_network`, and `plot_network`.
- Preserve upstream license, citation, attribution, and restriction text in artifacts and generated
  documentation. The repository MIT license applies only to package code and extraction scripts.
- Use integration tests over released artifacts. Do not mock source services or duplicate loader
  implementation in tests.
- Do not run extraction or source-refresh scripts in CI.
