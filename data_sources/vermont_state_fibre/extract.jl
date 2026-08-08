using CSV: CSV
using DataFrames: DataFrame, nrow
using JSON3: JSON3
using SHA: sha256

include(joinpath(@__DIR__, "..", "common.jl"))
using .ExtractionCommon

const SOURCE_SHA256 = "4d0d7f30e026301056827f2575da75983791fda712895f709c94e8d7ef254f26"
const LICENSE = "Vermont-Open-Geodata-Policy"
const LICENSE_URL = "https://files.vcgi.vermont.gov/other/policies/vermont-open-geodata-policy.html"
const CITATION = "Vermont Center for Geographic Information, PSD State-Owned Fiber Routes, MapServer layer 46."

function route(feature)
    feature.geometry.type == "LineString" || error("OBJECTID $(feature.properties.OBJECTID): expected LineString")
    return [(Float64(point[1]), Float64(point[2])) for point in feature.geometry.coordinates]
end

function source_length_m(properties)
    value = properties["Shape.STLength()"]
    isfinite(value) && value >= 0 || error("OBJECTID $(properties.OBJECTID): invalid projected length")
    return Float64(value)
end

options = parse_cli(ARGS; required=["source", "output"])
source = abspath(options["source"])
output = abspath(options["output"])
bytes2hex(open(sha256, source)) == SOURCE_SHA256 || error("source checksum does not match the pinned GeoJSON")
ispath(output) && error("output already exists: $(output)")
mkpath(output)

collection = JSON3.read(read(source, String))
length(collection.features) == 542 || error("expected 542 source routes; found $(length(collection.features))")
summary_rows = NamedTuple[]
report_rows = NamedTuple[]

for (status, network_id, name) in [
        ("YES", "built", "Built state-owned fibre routes"),
        ("NO", "not_built_planned", "Not-built or planned state-owned fibre routes"),
    ]
    features = sort(
        [feature for feature in collection.features if String(feature.properties.BUILT) == status];
        by=feature -> Int(feature.properties.OBJECTID),
    )
    expected = status == "YES" ? 302 : 240
    length(features) == expected || error("expected $(expected) BUILT=$(status) routes; found $(length(features))")
    records = [begin
        coordinates = route(feature)
        (;
            source_id="route_$(stable_source_id(feature.properties.OBJECTID))",
            name="",
            coordinates,
            source_attributes_json=String(JSON3.write(feature.properties)),
            source_length_m=source_length_m(feature.properties),
            source_geodesic_m=polyline_length_m(coordinates),
        )
    end for feature in features]
    normalized = normalize_line_records(
        records;
        coordinate_method="source_geometry_vertex",
        node_note="Node derived from a source route endpoint or exact shared geometry vertex; no snapping was applied.",
        distance_method="projected_geometry",
        distance_note="Source GIS projected length in metres; apportioned by polyline share only when an interior shared vertex splits a source route.",
        distance=(record, segment) -> record.source_geodesic_m > 0 ?
            record.source_length_m * polyline_length_m(segment) / record.source_geodesic_m :
            record.source_length_m,
    )
    write_network(output, network_id, normalized.nodes, normalized.edges)
    push!(summary_rows, (;
        schema_version=1,
        network_id,
        name,
        description="Vermont state-owned fibre routes grouped by the publisher's BUILT status.",
        source_reference="MapServer layer 46; BUILT=$(status)",
        node_count=nrow(normalized.nodes),
        edge_count=nrow(normalized.edges),
        component_count=component_count(nrow(normalized.nodes), normalized.edges),
        original_directed=false,
        coordinate_method="source_geometry_vertex",
        distance_method="projected_geometry",
        license_identifier=LICENSE,
        license_url=LICENSE_URL,
        citation=CITATION,
        attribution="Vermont Center for Geographic Information and Vermont Department of Public Service.",
        redistribution_notes="Reuse is allowed, but direct non-value-added reproduction with intent to sell is restricted.",
        source_node_count=0,
        source_edge_count=length(features),
        self_loops_removed=normalized.self_loops_removed,
        parallel_edges_combined=normalized.parallel_edges_combined,
        normalized_segment_count=normalized.segment_count,
        built_status=status,
    ))
    for feature in features
        push!(report_rows, (;
            source_reference="OBJECTID $(feature.properties.OBJECTID)",
            network_id,
            status="published",
            detail="BUILT=$(status)",
        ))
    end
end

write_artifact_metadata(output, @__DIR__, DataFrame(summary_rows))
CSV.write(joinpath(output, "extraction_report.csv"), DataFrame(report_rows); missingstring="")
println("Wrote built and not-built/planned networks with all 542 source routes to $(output)")
