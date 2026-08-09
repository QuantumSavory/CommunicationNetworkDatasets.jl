using CSV: CSV
using DataFrames: DataFrame, nrow
using JSON3: JSON3
using SHA: sha256

include(joinpath(@__DIR__, "..", "common.jl"))
using .ExtractionCommon

const SOURCE_SHA256 = "3e668e85e2a6ea9bac963ca002b73c3b622de71e5973f862fda869527488f6ae"
const SOURCE_URL = "https://services1.arcgis.com/wfNKYeHsOyaFyPw3/arcgis/rest/services/Australias_Submarine_Telecommunication_Cable_locations_2021/FeatureServer/0/query?where=1%3D1&outFields=*&returnGeometry=true&outSR=4326&f=geojson"
const LICENSE = "CC-BY-4.0"
const LICENSE_URL = "https://creativecommons.org/licenses/by/4.0/"
const CITATION = "Australian Communications and Media Authority, Australia's Submarine Telecommunication Cable Locations 2021."

function coordinates(feature)
    geometry = feature.geometry
    parts = geometry.type == "LineString" ? [geometry.coordinates] :
        geometry.type == "MultiLineString" ? geometry.coordinates :
        error("OBJECTID $(feature.properties.OBJECTID): unsupported geometry $(geometry.type)")
    route = Tuple{Float64,Float64}[]
    for part in parts
        points = [(Float64(point[1]), Float64(point[2])) for point in part]
        length(points) >= 2 || error("OBJECTID $(feature.properties.OBJECTID): route part has fewer than two points")
        append!(route, points)
    end
    return route
end

options = parse_cli(ARGS; required=["source", "output"])
source = abspath(options["source"])
output = abspath(options["output"])
bytes2hex(open(sha256, source)) == SOURCE_SHA256 || error("source checksum does not match the pinned GeoJSON")
ispath(output) && error("output already exists: $(output)")
mkpath(output)

collection = JSON3.read(read(source, String))
length(collection.features) == 16 || error("expected 16 source features; found $(length(collection.features))")
features = sort(collect(collection.features); by=feature -> Int(feature.properties.OBJECTID))
network_ids = unique_slugs([strip(String(feature.properties.CABLE)) for feature in features])
summary_rows = NamedTuple[]
report_rows = NamedTuple[]

for (feature, network_id) in zip(features, network_ids)
    route = coordinates(feature)
    name = strip(String(feature.properties.CABLE))
    source_id = stable_source_id(feature.properties.OBJECTID)
    nodes = DataFrame(
        vertex=[1, 2],
        node_id=["endpoint_a", "endpoint_b"],
        name=["$(name) endpoint A", "$(name) endpoint B"],
        longitude_deg=[route[1][1], route[end][1]],
        latitude_deg=[route[1][2], route[end][2]],
        coordinate_method=fill("geometry_endpoint", 2),
        note=fill("Endpoint derived from the published approximate route; it is not an inferred landing station.", 2),
        source_feature_id=fill(source_id, 2),
    )
    edges = DataFrame(
        edge_id=["edge_1_2"],
        src_vertex=[1],
        dst_vertex=[2],
        name=[name],
        distance_m=[polyline_length_m(route)],
        distance_method=["geodesic_polyline"],
        distance_note=["Calculated along the approximate WGS84 polyline; the source angular Shape__Length field is not used."],
        contributing_source_edge_count=[1],
        geometry_wkt=[linestring_wkt(route)],
        source_feature_id=[source_id],
        source_shape_length_deg=[Float64(feature.properties.Shape__Length)],
        source_attributes_json=[String(JSON3.write(feature.properties))],
    )
    write_network(output, network_id, nodes, edges)
    push!(summary_rows, (;
        schema_version=1,
        network_id,
        name,
        description="One approximate submarine-cable route in Australian cable-protection zones.",
        source_reference="ArcGIS OBJECTID $(source_id)",
        node_count=2,
        edge_count=1,
        component_count=1,
        original_directed=false,
        coordinate_method="geometry_endpoint",
        distance_method="geodesic_polyline",
        license_identifier=LICENSE,
        license_url=LICENSE_URL,
        citation=CITATION,
        attribution="Australian Communications and Media Authority © Commonwealth of Australia.",
        redistribution_notes="CC BY 4.0; route and endpoint locations are approximate and limited to protection zones.",
        source_node_count=2,
        source_edge_count=1,
        self_loops_removed=0,
        parallel_edges_combined=0,
        reported_shape_length_deg=Float64(feature.properties.Shape__Length),
    ))
    push!(report_rows, (source_reference="ArcGIS OBJECTID $(source_id)", network_id, status="published", detail=""))
end

write_artifact_metadata(output, @__DIR__, DataFrame(summary_rows))
CSV.write(joinpath(output, "extraction_report.csv"), DataFrame(report_rows); missingstring="")
println("Wrote 16 independent cable networks to $(output)")
