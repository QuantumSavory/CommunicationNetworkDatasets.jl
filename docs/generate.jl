module GenerateDocumentation

using CairoMakie
using CommunicationNetworkDatasets
using Pkg.Artifacts: artifact_hash, artifact_path, ensure_artifact_installed
using PrettyTables: pretty_table
using Tyler

const PACKAGE_ROOT = normpath(joinpath(@__DIR__, ".."))
const ARTIFACTS_TOML = joinpath(PACKAGE_ROOT, "Artifacts.toml")
const GENERATED_ROOT = joinpath(@__DIR__, "src", "generated")
const IMAGE_ROOT = joinpath(GENERATED_ROOT, "images")
const BASEMAP_NAME = "natural_earth_basemap"
const FIGURE_SIZE = (960, 600)

function offline_provider()
    ensure_artifact_installed(BASEMAP_NAME, ARTIFACTS_TOML)
    hash = artifact_hash(BASEMAP_NAME, ARTIFACTS_TOML)
    isnothing(hash) && error("docs basemap artifact $(repr(BASEMAP_NAME)) is not bound")
    root = artifact_path(hash)
    return Tyler.TileProviders.Provider(
        "file://" * joinpath(root, "{z}", "{x}", "{y}.png"),
        Dict{Symbol,Any}(
            :min_zoom => 0,
            :max_zoom => 0,
            :attribution => "Made with Natural Earth; public domain",
        ),
    )
end

function markdown_table(table)
    output = IOBuffer()
    pretty_table(output, table; backend=:markdown, column_labels=names(table))
    return String(take!(output))
end

function metadata_table(row)
    fields = propertynames(row)
    contents = Matrix{String}(undef, length(fields), 2)
    for (index, field) in enumerate(fields)
        contents[index, 1] = String(field)
        contents[index, 2] = ismissing(row[field]) ? "" : string(row[field])
    end
    output = IOBuffer()
    pretty_table(output, contents; backend=:markdown, column_labels=["Field", "Value"])
    return String(take!(output))
end

function html_escape(value)
    escaped = replace(string(value), '&' => "&amp;")
    escaped = replace(escaped, '<' => "&lt;", '>' => "&gt;")
    return replace(escaped, '"' => "&quot;", '\'' => "&#39;")
end

function license_link(row)
    identifier = html_escape(row.license_identifier)
    url = html_escape(row.license_url)
    return isempty(url) ? identifier : "<a href=\"$(url)\">$(identifier)</a>"
end

function modification_notice()
    return "CommunicationNetworkDatasets.jl normalized the source records into a simple " *
        "undirected graph, normalized identifiers and units, and rendered this plot over a " *
        "modified Natural Earth public-domain basemap."
end

function plot_caption(row)
    name = html_escape(row.name)
    attribution = html_escape(row.attribution)
    restrictions = html_escape(row.redistribution_notes)
    modification = html_escape(modification_notice())
    return "<strong>$(name).</strong> <strong>License:</strong> $(license_link(row)) " *
        "<strong>Attribution:</strong> $(attribution) <strong>Modifications:</strong> " *
        "$(modification) <strong>Use and redistribution:</strong> $(restrictions)"
end

function render_plot(provider, dataset_id, network_row, image_path)
    network_id = String(network_row.network_id)
    result = nothing
    try
        result = CommunicationNetworkDatasets.plot_network(
            dataset_id,
            network_id;
            provider,
            figure=CairoMakie.Figure(; size=FIGURE_SIZE),
            map_kwargs=(; fetching_scheme=Tyler.SimpleTiling(), max_parallel_downloads=1),
        )
        isempty(result.omitted_vertices) || error(
            "$(dataset_id)/$(network_id): plot omitted vertices $(result.omitted_vertices)",
        )
        isempty(result.omitted_edges) || error(
            "$(dataset_id)/$(network_id): plot omitted edges $(result.omitted_edges)",
        )
        wait(result.map)
        CairoMakie.save(image_path, result.figure; px_per_unit=1)
        filesize(image_path) > 1_000 || error(
            "$(dataset_id)/$(network_id): generated plot is unexpectedly small",
        )
    finally
        isnothing(result) || close(result.map)
    end
    return nothing
end

function write_source_page(page_path, dataset_row, network_table, provider)
    dataset_id = String(dataset_row.dataset_id)
    image_directory = joinpath(IMAGE_ROOT, dataset_id)
    mkpath(image_directory)
    open(page_path, "w") do output
        println(output, "# ", dataset_row.name)
        println(output)
        println(output, dataset_row.description)
        println(output)
        println(output, "## License, attribution, and modifications")
        println(output)
        println(output, "- License: [", dataset_row.license_identifier, "](", dataset_row.license_url, ")")
        println(output, "- Attribution: ", dataset_row.attribution)
        println(output, "- Citation: ", dataset_row.citation)
        println(output, "- Modifications: ", modification_notice())
        println(output, "- Use and redistribution: ", dataset_row.redistribution_notes)
        println(output)
        println(output, "## Source metadata")
        println(output)
        println(output, metadata_table(dataset_row))
        println(output)
        println(output, "## Network metadata")
        println(output)
        println(output, "This table is the complete network catalog returned by `networks(\"", dataset_id, "\")`.")
        println(output)
        println(output, markdown_table(network_table))
        println(output)
        println(output, "## Network plots")

        for network_row in eachrow(network_table)
            network_id = String(network_row.network_id)
            image_path = joinpath(image_directory, network_id * ".png")
            render_plot(provider, dataset_id, network_row, image_path)
            relative_image = "../images/$(dataset_id)/$(network_id).png"
            println(output)
            println(output, "### ", network_row.name)
            println(output)
            println(output, "```@raw html")
            println(output, "<figure>")
            println(
                output,
                "  <img loading=\"lazy\" decoding=\"async\" src=\"",
                html_escape(relative_image),
                "\" alt=\"",
                html_escape("$(network_row.name) network plot"),
                "\" style=\"max-width: 100%; height: auto;\">",
            )
            println(output, "  <figcaption>", plot_caption(network_row), "</figcaption>")
            println(output, "</figure>")
            println(output, "```")
        end
    end
    return nothing
end

function selected_rows(catalog, dataset_ids)
    rows = collect(eachrow(catalog))
    isnothing(dataset_ids) && return rows
    requested = Set(String.(dataset_ids))
    available = Set(String(row.dataset_id) for row in rows)
    unknown = sort!(collect(setdiff(requested, available)))
    isempty(unknown) || error(
        "unknown documentation dataset IDs: $(join(unknown, ", ")); call datasets() for valid IDs",
    )
    return [row for row in rows if String(row.dataset_id) in requested]
end

function generated_image_count(root)
    isdir(root) || return 0
    return sum(
        count(filename -> endswith(filename, ".png"), filenames)
        for (_, _, filenames) in walkdir(root)
    )
end

function generate(; dataset_ids=nothing)
    catalog = CommunicationNetworkDatasets.datasets()
    rows = selected_rows(catalog, dataset_ids)
    isempty(rows) && error("documentation selection contains no datasets")

    isdir(GENERATED_ROOT) && rm(GENERATED_ROOT; recursive=true)
    mkpath(IMAGE_ROOT)
    provider = offline_provider()
    expected_images = 0
    for dataset_row in rows
        dataset_id = String(dataset_row.dataset_id)
        network_table = CommunicationNetworkDatasets.networks(dataset_id)
        expected_images += size(network_table, 1)
        write_source_page(
            joinpath(GENERATED_ROOT, dataset_id * ".md"),
            dataset_row,
            network_table,
            provider,
        )
    end

    generated_pages = filter(name -> endswith(name, ".md"), readdir(GENERATED_ROOT))
    length(generated_pages) == length(rows) || error(
        "generated $(length(generated_pages)) dataset pages; expected $(length(rows))",
    )
    image_count = generated_image_count(IMAGE_ROOT)
    image_count == expected_images || error(
        "generated $(image_count) network images; expected $(expected_images)",
    )
    return (; catalog_rows=rows, generated_pages, image_count)
end

function cli_dataset_ids(arguments)
    isempty(arguments) && return nothing
    length(arguments) == 2 && arguments[1] == "--dataset" || error(
        "usage: julia --project=docs docs/generate.jl [--dataset DATASET_ID]",
    )
    return [arguments[2]]
end

if abspath(PROGRAM_FILE) == @__FILE__
    generate(; dataset_ids=cli_dataset_ids(ARGS))
end

end
