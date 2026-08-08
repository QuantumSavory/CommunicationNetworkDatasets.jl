using CSV: CSV
using DataFrames: DataFrame, nrow
using JSON3: JSON3
using SHA: sha256

include(joinpath(@__DIR__, "..", "common.jl"))
using .ExtractionCommon

const SOURCE_SHA256 = "4f979c39c6d467313cb0659e4a92294c5f8f53d4465a7713415e7dd525529721"
const LICENSE = "CC-BY-3.0-AU"
const LICENSE_URL = "https://creativecommons.org/licenses/by/3.0/au/"
const CITATION = "City of Gold Coast, Fibre Optic Cable, data.gov.au dataset fa5452e4-7713-4c15-b647-ba0191a8c25c."
const WARNING = "The information is provided to assist in field investigations. All locations, dimensions and depths shown are to be confirmed on site."

options = parse_cli(ARGS; required=["source", "output"])
source = abspath(options["source"])
output = abspath(options["output"])
bytes2hex(open(sha256, source)) == SOURCE_SHA256 || error("source checksum does not match the pinned WFS response")
ispath(output) && error("output already exists: $(output)")
mkpath(output)

collection = JSON3.read(read(source, String))
length(collection.features) == 128 || error("expected 128 source features; found $(length(collection.features))")
features = sort(collect(collection.features); by=feature -> parse(Int, split(String(feature.id), '.')[end]))
records = NamedTuple[]
for feature in features
    feature.geometry.type == "MultiLineString" || error("$(feature.id): expected MultiLineString")
    for (part_index, part) in enumerate(feature.geometry.coordinates)
        push!(records, (;
            source_id="$(feature.id)_part_$(part_index)",
            name=isnothing(feature.properties.name) || ismissing(feature.properties.name) ? "" : String(feature.properties.name),
            coordinates=[(Float64(point[1]), Float64(point[2])) for point in part],
            source_attributes_json=String(JSON3.write(feature.properties)),
        ))
    end
end

normalized = normalize_line_records(
    records;
    coordinate_method="approximate_source_geometry_vertex",
    node_note="Node derived from approximate source geometry without snapping. $(WARNING)",
    distance_method="geodesic_polyline",
    distance_note="Calculated along approximate WGS84 geometry; $(WARNING)",
)
network_id = "gold_coast_municipal_fibre"
write_network(output, network_id, normalized.nodes, normalized.edges)
write_artifact_metadata(output, @__DIR__, DataFrame([(
    schema_version=1,
    network_id,
    name="City of Gold Coast municipal fibre",
    description="Approximate municipal fibre route topology for field investigation support.",
    source_reference="data.gov.au WFS ckan_fa5452e4_7713_4c15_b647_ba0191a8c25c",
    node_count=nrow(normalized.nodes),
    edge_count=nrow(normalized.edges),
    component_count=component_count(nrow(normalized.nodes), normalized.edges),
    original_directed=false,
    coordinate_method="approximate_source_geometry_vertex",
    distance_method="geodesic_polyline",
    license_identifier=LICENSE,
    license_url=LICENSE_URL,
    citation=CITATION,
    attribution="City of Gold Coast.",
    redistribution_notes="CC BY 3.0 Australia. $(WARNING)",
    source_node_count=0,
    source_edge_count=length(features),
    self_loops_removed=normalized.self_loops_removed,
    parallel_edges_combined=normalized.parallel_edges_combined,
    normalized_segment_count=normalized.segment_count,
)]))
CSV.write(
    joinpath(output, "extraction_report.csv"),
    DataFrame(source_reference=[String(feature.id) for feature in features], network_id=fill(network_id, length(features)),
        status=fill("published", length(features)), detail=fill(WARNING, length(features)));
    missingstring="",
)
println("Wrote the 128-feature Gold Coast network to $(output)")
