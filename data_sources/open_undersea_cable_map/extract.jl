using CSV: CSV
using DataFrames: DataFrame, nrow
using JSON3: JSON3
using SHA: sha256

include(joinpath(@__DIR__, "..", "common.jl"))
using .ExtractionCommon

const SOURCE_COMMIT = "e7903491e73bcac0d0b013b945897d10928483c4"
const CABLE_GEO_SHA256 = "0cfca621aa2c4eb9e111d3ccb4f26f53462c87f8872df7ee639db3ceeaa000f9"
const LANDING_GEO_SHA256 = "c01d94947316b616f0bfaf6326f4bec424c9d7b5480eeb617a885f6bd4ec8aef"
const CABLE_METADATA_SHA256 = "1224999f6b73ee77ee267880a2d9132efb80f1c1efc591e2988698204daeaf99"
const LICENSE = "CC-BY-NC-SA-3.0"
const LICENSE_URL = "https://creativecommons.org/licenses/by-nc-sa/3.0/"
const CITATION = "TeleGeography submarine cable map data, republished by Steve Song in Open Undersea Cable Map commit $(SOURCE_COMMIT)."

coordinate(point) = (Float64(point[1]), Float64(point[2]))

function metadata_digest(paths)
    bytes = UInt8[]
    for path in paths
        append!(bytes, codeunits(basename(path)))
        push!(bytes, 0x00)
        append!(bytes, read(path))
        push!(bytes, 0x00)
    end
    return bytes2hex(sha256(bytes))
end

function reported_length_km(value)
    isnothing(value) && return missing
    matched = match(r"[0-9][0-9,]*(?:\.[0-9]+)?", String(value))
    isnothing(matched) && return missing
    return parse(Float64, replace(matched.match, "," => ""))
end

function missing_column(::Type{T}, count) where {T}
    return Union{Missing,T}[missing for _ in 1:count]
end

options = parse_cli(ARGS; required=["source", "output"])
source = abspath(options["source"])
output = abspath(options["output"])
isdir(source) || error("source is not a directory: $(source)")
ispath(output) && error("output already exists: $(output)")

cable_geo_path = joinpath(source, "cable", "cable-geo.json")
landing_geo_path = joinpath(source, "landing-point", "landing-point-geo.json")
bytes2hex(open(sha256, cable_geo_path)) == CABLE_GEO_SHA256 || error("cable geometry checksum does not match")
bytes2hex(open(sha256, landing_geo_path)) == LANDING_GEO_SHA256 || error("landing geometry checksum does not match")
metadata_paths = sort!(filter(path -> endswith(path, ".json") &&
    basename(path) ∉ ("all.json", "cable-geo.json"), readdir(joinpath(source, "cable"); join=true)))
length(metadata_paths) == 521 || error("expected 521 cable metadata files")
metadata_digest(metadata_paths) == CABLE_METADATA_SHA256 || error("cable metadata digest does not match")

cable_metadata = JSON3.read.(read.(metadata_paths, String))
cable_geometry = JSON3.read(read(cable_geo_path, String))
landing_geometry = JSON3.read(read(landing_geo_path, String))
length(cable_geometry.features) == 527 || error("expected 527 cable geometry features")
length(landing_geometry.features) == 1_414 || error("expected 1,414 landing geometries")

landing_coordinates = Dict{String,Tuple{Float64,Float64}}()
for feature in landing_geometry.features
    feature.geometry.type == "Point" || error("landing $(feature.properties.id) is not a Point")
    id = String(feature.properties.id)
    haskey(landing_coordinates, id) && error("duplicate landing geometry $(id)")
    landing_coordinates[id] = coordinate(feature.geometry.coordinates)
end

geometry_by_cable = Dict{String,Vector{Any}}()
for feature in cable_geometry.features
    feature.geometry.type == "MultiLineString" || error("cable $(feature.properties.id) is not a MultiLineString")
    push!(get!(geometry_by_cable, String(feature.properties.id), Any[]), feature)
end
Set(keys(geometry_by_cable)) == Set(String(metadata.id) for metadata in cable_metadata) ||
    error("cable metadata and geometry identifiers differ")

sort!(cable_metadata; by=metadata -> String(metadata.id))
included = filter(metadata -> length(metadata.landing_points) >= 2, cable_metadata)
excluded = filter(metadata -> length(metadata.landing_points) < 2, cable_metadata)
length(included) == 519 || error("expected 519 publishable systems; found $(length(included))")
sort!([String(metadata.id) for metadata in excluded]) ==
    ["darwin-jakarta-singapore-cable-djsc", "sednalink-fibre"] || error("unexpected exclusions")
network_ids = unique_slugs(String(metadata.id) for metadata in included)

mkpath(output)
summary_rows = NamedTuple[]
report_rows = NamedTuple[]

for (metadata, network_id) in zip(included, network_ids)
    cable_id = String(metadata.id)
    name = String(metadata.name)
    features = geometry_by_cable[cable_id]
    parts = [coordinate.(part) for feature in features for part in feature.geometry.coordinates]
    vertices = unique(vcat(parts...))
    matches = NamedTuple[]
    for landing in metadata.landing_points
        landing_id = String(landing.id)
        haskey(landing_coordinates, landing_id) || error("$(cable_id): missing landing geometry $(landing_id)")
        landing_coordinate = landing_coordinates[landing_id]
        distances = [haversine_m(landing_coordinate[1], landing_coordinate[2], vertex[1], vertex[2])
            for vertex in vertices]
        distance_m, index = findmin(distances)
        push!(matches, (; landing, coordinate=landing_coordinate,
            route_coordinate=vertices[index], distance_m))
    end
    sort!(matches; by=match -> String(match.landing.id))

    matches_by_route = Dict{Tuple{Float64,Float64},Vector{NamedTuple}}()
    for matched in matches
        push!(get!(matches_by_route, matched.route_coordinate, NamedTuple[]), matched)
    end
    primary_by_route = Dict(route_coordinate => first(sort!(candidates;
        by=matched -> (matched.distance_m, String(matched.landing.id))))
        for (route_coordinate, candidates) in matches_by_route)
    replacement = Dict(route_coordinate => matched.coordinate for (route_coordinate, matched) in primary_by_route)
    records = NamedTuple[]
    for (feature_index, feature) in enumerate(features), (part_index, part) in enumerate(feature.geometry.coordinates)
        source_id = String(feature.properties.feature_id)
        push!(records, (;
            source_id="$(source_id)_part_$(part_index)_feature_$(feature_index)",
            name,
            coordinates=[get(replacement, coordinate(point), coordinate(point)) for point in part],
            source_attributes_json=String(JSON3.write(feature.properties)),
        ))
    end
    normalized = normalize_line_records(
        records;
        coordinate_method="stylized_route_geometry_vertex",
        node_note="Derived from a stylized source route endpoint, junction, or explicit landing match.",
        distance_method="geodesic_polyline",
        distance_note="Calculated along the stylized WGS84 cable route; the reported system total is metadata only.",
        forced_node_coordinates=Set(values(replacement)),
    )

    nodes = normalized.nodes
    nodes[!, :landing_point_id] = missing_column(String, nrow(nodes))
    nodes[!, :country] = missing_column(String, nrow(nodes))
    nodes[!, :is_tbd] = missing_column(Bool, nrow(nodes))
    nodes[!, :route_match_distance_m] = missing_column(Float64, nrow(nodes))
    nodes[!, :source_landing_attributes_json] = missing_column(String, nrow(nodes))
    vertex_by_coordinate = Dict((Float64(row.longitude_deg), Float64(row.latitude_deg)) => Int(row.vertex)
        for row in eachrow(nodes))

    primary_by_coordinate = Dict{Tuple{Float64,Float64},Vector{NamedTuple}}()
    for matched in values(primary_by_route)
        push!(get!(primary_by_coordinate, matched.coordinate, NamedTuple[]), matched)
    end
    attached_landing_ids = Set{String}()
    for (landing_coordinate, candidates) in primary_by_coordinate
        matched = first(sort!(candidates; by=candidate -> (candidate.distance_m, String(candidate.landing.id))))
        vertex = vertex_by_coordinate[landing_coordinate]
        landing_id = String(matched.landing.id)
        nodes.node_id[vertex] = "landing_$(slug(landing_id))"
        nodes.name[vertex] = String(matched.landing.name)
        nodes.coordinate_method[vertex] = "published_landing_matched_to_route"
        nodes.note[vertex] = "Explicit cable landing matched to the nearest stylized route vertex at $(matched.distance_m) m."
        nodes.landing_point_id[vertex] = landing_id
        landing_country = get(matched.landing, :country, nothing)
        landing_is_tbd = get(matched.landing, :is_tbd, nothing)
        nodes.country[vertex] = isnothing(landing_country) ? missing : string(landing_country)
        nodes.is_tbd[vertex] = isnothing(landing_is_tbd) ? missing : Bool(landing_is_tbd)
        nodes.route_match_distance_m[vertex] = matched.distance_m
        nodes.source_landing_attributes_json[vertex] = String(JSON3.write(matched.landing))
        push!(attached_landing_ids, landing_id)
    end

    edges = normalized.edges
    for matched in matches
        landing_id = String(matched.landing.id)
        landing_id in attached_landing_ids && continue
        anchor_coordinate = replacement[matched.route_coordinate]
        src_vertex = vertex_by_coordinate[anchor_coordinate]
        dst_vertex = nrow(nodes) + 1
        landing_country = get(matched.landing, :country, nothing)
        landing_is_tbd = get(matched.landing, :is_tbd, nothing)
        push!(nodes, (;
            vertex=dst_vertex,
            node_id="landing_$(slug(landing_id))",
            name=String(matched.landing.name),
            longitude_deg=matched.coordinate[1],
            latitude_deg=matched.coordinate[2],
            coordinate_method="published_landing_matched_to_route",
            note="Explicit landing retained as a distinct node because another landing maps to the same stylized route vertex.",
            source_feature_ids="landing_$(landing_id)",
            landing_point_id=landing_id,
            country=isnothing(landing_country) ? missing : string(landing_country),
            is_tbd=isnothing(landing_is_tbd) ? missing : Bool(landing_is_tbd),
            route_match_distance_m=matched.distance_m,
            source_landing_attributes_json=String(JSON3.write(matched.landing)),
        ))
        route = [anchor_coordinate, matched.coordinate]
        push!(edges, (;
            edge_id="edge_$(src_vertex)_$(dst_vertex)",
            src_vertex,
            dst_vertex,
            name,
            distance_m=polyline_length_m(route),
            distance_method="geodesic_polyline",
            distance_note="Derived two-point branch retaining a distinct explicit landing that maps to an occupied stylized route vertex.",
            contributing_source_edge_count=1,
            geometry_wkt=linestring_wkt(route),
            source_edge_ids="landing_match_$(landing_id)",
            selected_source_edge_id="landing_match_$(landing_id)",
            source_attributes_json=String(JSON3.write(matched.landing)),
        ))
        push!(attached_landing_ids, landing_id)
    end
    length(attached_landing_ids) == length(matches) || error("$(cable_id): not all explicit landings were published")

    write_network(output, network_id, nodes, edges)
    match_distances = getproperty.(matches, :distance_m)
    raw_length = get(metadata, :length, nothing)
    push!(summary_rows, (;
        schema_version=1,
        network_id,
        name,
        description="Stylized submarine-cable route with explicit published landing membership.",
        source_reference="cable $(cable_id) at Open Undersea Cable Map commit $(SOURCE_COMMIT)",
        node_count=nrow(nodes),
        edge_count=nrow(edges),
        component_count=component_count(nrow(nodes), edges),
        original_directed=false,
        coordinate_method="published_landings_and_stylized_route_junctions",
        distance_method="geodesic_polyline",
        license_identifier=LICENSE,
        license_url=LICENSE_URL,
        citation=CITATION,
        attribution="TeleGeography and Steve Song.",
        redistribution_notes="CC BY-NC-SA 3.0; this artifact and derived documentation retain attribution, noncommercial, and share-alike terms.",
        source_node_count=length(matches),
        source_edge_count=length(records),
        self_loops_removed=normalized.self_loops_removed,
        parallel_edges_combined=normalized.parallel_edges_combined,
        source_geometry_feature_count=length(features),
        source_geometry_part_count=length(parts),
        reported_system_length=isnothing(raw_length) ? missing : string(raw_length),
        reported_system_length_km=reported_length_km(raw_length),
        owners=isnothing(get(metadata, :owners, nothing)) ? missing : string(metadata.owners),
        suppliers=isnothing(get(metadata, :suppliers, nothing)) ? missing : string(metadata.suppliers),
        ready_for_service=isnothing(get(metadata, :rfs, nothing)) ? missing : string(metadata.rfs),
        is_planned=isnothing(get(metadata, :is_planned, nothing)) ? missing : Bool(metadata.is_planned),
        landing_match_max_m=maximum(match_distances),
        landing_match_mean_m=sum(match_distances) / length(match_distances),
    ))
    push!(report_rows, (;
        source_reference="cable $(cable_id)",
        network_id,
        status="published",
        detail="$(length(matches)) explicit landings; maximum route-vertex match $(maximum(match_distances)) m; $(length(matches) - length(primary_by_route)) occupied-vertex landing(s)",
    ))
end

for metadata in excluded
    push!(report_rows, (;
        source_reference="cable $(metadata.id)",
        network_id=missing,
        status="excluded",
        detail="only $(length(metadata.landing_points)) explicit landing point",
    ))
end

write_artifact_metadata(output, @__DIR__, DataFrame(summary_rows))
CSV.write(joinpath(output, "extraction_report.csv"), DataFrame(report_rows); missingstring="")
println("Wrote 519 cable networks and 2 exclusions to $(output)")
