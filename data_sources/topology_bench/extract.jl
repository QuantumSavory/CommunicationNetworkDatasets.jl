using CSV: CSV
using DataFrames: DataFrame, eachrow, nrow, rename!
using SHA: sha256
using XLSX: XLSX
using ZipFile: ZipFile

include(joinpath(@__DIR__, "..", "common.jl"))
using .ExtractionCommon

const ARCHIVE_SHA256 = "f2ad31ecc53378dd8992beedfe93141454bc1915257bd78e4e0dca3484ed45c8"
const SOURCE_URL = "https://zenodo.org/api/records/13921775/files/real_topologies.zip/content"
const LICENSE = "CC-BY-4.0"
const LICENSE_URL = "https://creativecommons.org/licenses/by/4.0/"
const CITATION = "Virgillito et al., Topology Bench: Systematic Graph Based Benchmarking for Optical Networks, Zenodo record 13921775 (2024)."

options = parse_cli(ARGS; required=["archive", "output"])
archive = abspath(options["archive"])
output = abspath(options["output"])
bytes2hex(open(sha256, archive)) == ARCHIVE_SHA256 || error(
    "Topology Bench archive checksum does not match the pinned snapshot",
)
ispath(output) && error("output already exists: $(output)")
mkpath(output)

function workbook_table(path, sheet_index)
    XLSX.openxlsx(path) do workbook
        sheets = XLSX.sheetnames(workbook)
        return DataFrame(XLSX.gettable(workbook[sheets[sheet_index]]))
    end
end

archive_reader = ZipFile.Reader(archive)
files = sort(filter(file -> occursin(r"^TOP_[0-9]+_.+\.xlsx$", file.name), archive_reader.files);
    by=file -> parse(Int, match(r"^TOP_([0-9]+)_", file.name).captures[1]))
length(files) == 105 || error("expected 105 real topology workbooks; found $(length(files))")

names = [replace(match(r"^TOP_[0-9]+_(.+)\.xlsx$", file.name).captures[1], '_' => ' ') for file in files]
network_ids = unique_slugs(names)
summary_rows = NamedTuple[]
report_rows = NamedTuple[]

try
    mktempdir() do directory
        for (file, network_id, network_name) in zip(files, network_ids, names)
            workbook_path = joinpath(directory, basename(file.name))
            open(workbook_path, "w") do io
                write(io, read(file))
            end
            source_nodes = workbook_table(workbook_path, 1)
            source_edges = workbook_table(workbook_path, 2)
            rename!(source_nodes, Symbol.(strip.(String.(propertynames(source_nodes)))))
            rename!(source_edges, Symbol.(strip.(String.(propertynames(source_edges)))))

            node_id_column = :Node_ID
            latitude_column = :Latitude
            longitude_column = :Longitude
            location_column = Symbol("Location Name")
            country_column = :Country
            required_node_columns = [node_id_column, latitude_column, longitude_column, location_column, country_column]
            all(column -> column in propertynames(source_nodes), required_node_columns) || error(
                "$(file.name): unexpected node columns $(propertynames(source_nodes))",
            )
            required_edge_columns = [:Edge_ID, :Source, :Destination, Symbol("Computed Length (km)")]
            all(column -> column in propertynames(source_edges), required_edge_columns) || error(
                "$(file.name): unexpected edge columns $(propertynames(source_edges))",
            )

            source_node_ids = stable_source_id.(source_nodes[!, node_id_column])
            length(unique(source_node_ids)) == length(source_node_ids) || error("$(file.name): duplicate Node_ID")
            permutation = sortperm(source_node_ids; by=id -> tryparse(Int, id) === nothing ? (1, id) : (0, lpad(id, 20, '0')))
            source_nodes = source_nodes[permutation, :]
            source_node_ids = source_node_ids[permutation]
            vertex_by_source_id = Dict(id => index for (index, id) in enumerate(source_node_ids))
            nodes = DataFrame(
                vertex=collect(eachindex(source_node_ids)),
                node_id=["node_$(slug(id))" for id in source_node_ids],
                name=string.(source_nodes[!, location_column]),
                longitude_deg=Float64.(source_nodes[!, longitude_column]),
                latitude_deg=Float64.(source_nodes[!, latitude_column]),
                coordinate_method=fill("published_place_coordinates", nrow(source_nodes)),
                note=fill("Topology Bench coordinates identify published or geocoded places, not verified equipment sites.", nrow(source_nodes)),
                source_node_id=source_node_ids,
                country=string.(source_nodes[!, country_column]),
            )

            edge_input = DataFrame(
                src=stable_source_id.(source_edges.Source),
                dst=stable_source_id.(source_edges.Destination),
                source_edge_id=stable_source_id.(source_edges.Edge_ID),
                computed_length_km=Float64.(source_edges[!, Symbol("Computed Length (km)")]),
            )
            normalized = canonicalize_explicit_edges(
                edge_input,
                vertex_by_source_id;
                distance=row -> row.computed_length_km * 1000,
                source_id=row -> row.source_edge_id,
                name=row -> "",
                distance_method=row -> "scaled_geodesic_endpoints",
                distance_note=row -> "Publisher-supplied scaled-Haversine distance, converted from kilometres to metres.",
                source_columns=[:computed_length_km],
            )
            edges = normalized.edges
            write_network(output, network_id, nodes, edges)
            push!(summary_rows, (;
                schema_version=1,
                network_id,
                name=network_name,
                description="Real optical-network topology normalized from Topology Bench.",
                source_reference=file.name,
                node_count=nrow(nodes),
                edge_count=nrow(edges),
                component_count=component_count(nrow(nodes), edges),
                original_directed=false,
                coordinate_method="published_place_coordinates",
                distance_method="scaled_geodesic_endpoints",
                license_identifier=LICENSE,
                license_url=LICENSE_URL,
                citation=CITATION,
                attribution="Topology Bench authors and the per-topology sources named by the upstream collection.",
                redistribution_notes="CC BY 4.0; retain per-topology source provenance.",
                source_node_count=nrow(source_nodes),
                source_edge_count=nrow(source_edges),
                self_loops_removed=normalized.removed_loops,
                parallel_edges_combined=normalized.combined_parallel,
            ))
            push!(report_rows, (;
                source_reference=file.name,
                network_id,
                status="published",
                detail="",
            ))
        end
    end
finally
    close(archive_reader)
end

write_artifact_metadata(output, @__DIR__, DataFrame(summary_rows))
CSV.write(joinpath(output, "extraction_report.csv"), DataFrame(report_rows); missingstring="")
println("Wrote $(length(summary_rows)) networks to $(output)")
