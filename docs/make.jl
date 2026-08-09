using CommunicationNetworkDatasets
using Documenter

include("generate.jl")

generation = GenerateDocumentation.generate()
dataset_pages = [
    String(row.name) => joinpath("generated", String(row.dataset_id) * ".md")
    for row in generation.catalog_rows
]
generated_paths = [joinpath(@__DIR__, "src", path.second) for path in dataset_pages]
largest_generated_page = maximum(filesize, generated_paths)
total_generated_size = sum(filesize, generated_paths)
size_threshold = max(200 * 2^10, 8 * largest_generated_page)
size_threshold_warn = max(100 * 2^10, size_threshold ÷ 2)
search_size_threshold_warn = max(500 * 2^10, 2 * total_generated_size)

makedocs(
    modules=[CommunicationNetworkDatasets],
    sitename="CommunicationNetworkDatasets.jl",
    authors="Quantum Savory contributors",
    checkdocs=:exports,
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        inventory_version=string(pkgversion(CommunicationNetworkDatasets)),
        size_threshold,
        size_threshold_warn,
        search_size_threshold_warn,
    ),
    pages=[
        "Home" => "index.md",
        "Datasets" => dataset_pages,
        "Artifact schema" => "schema.md",
        "Public API" => "api.md",
    ],
)

deploydocs(;
    repo="github.com/QuantumSavory/CommunicationNetworkDatasets.jl.git",
    devbranch="main",
    push_preview=true,
    deploy_config=Documenter.Buildkite(),
)
