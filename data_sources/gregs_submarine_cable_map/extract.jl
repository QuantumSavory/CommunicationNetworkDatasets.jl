using CSV: CSV
using DataFrames: DataFrame, nrow
using JSON3: JSON3
using SHA: sha256

include(joinpath(@__DIR__, "..", "common.jl"))
using .ExtractionCommon

const CABLES_SHA256 = "a109fc04c233c3df5a7aadcd327bbc66f177c7ddf7c89f78604e8e3a92bc6cba"
const STATIONS_SHA256 = "8c041bac65faec836ae9f1f144a6ea09388ae346d9a8ab5692f5799097293bb8"
const MATCH_LIMIT_M = 25.0
const LICENSE = "GNU GPL, version unspecified"
const LICENSE_URL = "https://www.arcgis.com/home/item.html?id=00ae4550cd9b41dd93d33972bb8520bb"
const CITATION = "Greg Mahlknecht, Greg's Global Submarine Cable Map, ArcGIS item 00ae4550cd9b41dd93d33972bb8520bb."

function route_parts(feature)
    geometry = feature.geometry
    raw_parts = geometry.type == "LineString" ? [geometry.coordinates] :
        geometry.type == "MultiLineString" ? geometry.coordinates :
        error("FID $(feature.properties.FID): unsupported geometry $(geometry.type)")
    return [[(Float64(point[1]), Float64(point[2])) for point in part] for part in raw_parts]
end

function station_record(feature)
    feature.geometry.type == "Point" || error("station FID $(feature.properties.FID): expected Point")
    point = feature.geometry.coordinates
    return (;
        fid=Int(feature.properties.FID),
        name=String(feature.properties.Name),
        coordinate=(Float64(point[1]), Float64(point[2])),
        attributes_json=String(JSON3.write(feature.properties)),
    )
end

function analyze(feature, stations)
    parts = route_parts(feature)
    vertices = unique(vcat(parts...))
    matches = NamedTuple[]
    for station in stations
        distances = [haversine_m(station.coordinate[1], station.coordinate[2], point[1], point[2]) for point in vertices]
        distance_m, index = findmin(distances)
        distance_m <= MATCH_LIMIT_M && push!(matches, (;
            station,
            route_coordinate=vertices[index],
            distance_m,
        ))
    end
    sort!(matches; by=match -> match.station.fid)
    return (; feature, parts, matches)
end

options = parse_cli(ARGS; required=["cables", "stations", "output"])
cables_path = abspath(options["cables"])
stations_path = abspath(options["stations"])
output = abspath(options["output"])
bytes2hex(open(sha256, cables_path)) == CABLES_SHA256 || error("cable checksum does not match the pinned response")
bytes2hex(open(sha256, stations_path)) == STATIONS_SHA256 || error("station checksum does not match the pinned response")
ispath(output) && error("output already exists: $(output)")
mkpath(output)

cable_collection = JSON3.read(read(cables_path, String))
station_collection = JSON3.read(read(stations_path, String))
length(cable_collection.features) == 285 || error("expected 285 cable features")
length(station_collection.features) == 737 || error("expected 737 station features")
stations = sort(station_record.(collect(station_collection.features)); by=station -> station.fid)
analyses = [analyze(feature, stations) for feature in sort(collect(cable_collection.features);
    by=feature -> Int(feature.properties.FID))]
included = filter(result -> length(result.matches) >= 2, analyses)
length(included) == 279 || error("expected 279 cable features with at least two stations; found $(length(included))")
excluded_fids = sort!([Int(result.feature.properties.FID) for result in analyses if length(result.matches) < 2])
excluded_fids == [124, 230, 231, 258, 269, 277] ||
    error("unexpected excluded cable FIDs: $(join(excluded_fids, ", "))")
network_ids = unique_slugs([String(result.feature.properties.Name) for result in included])

summary_rows = NamedTuple[]
report_rows = NamedTuple[]
id_by_fid = Dict(Int(result.feature.properties.FID) => network_id for (result, network_id) in zip(included, network_ids))

for result in analyses
    feature = result.feature
    fid = Int(feature.properties.FID)
    name = String(feature.properties.Name)
    if length(result.matches) < 2
        push!(report_rows, (;
            source_reference="cable FID $(fid)",
            network_id=missing,
            status="excluded",
            detail="only $(length(result.matches)) station(s) matched a route vertex within $(MATCH_LIMIT_M) m",
        ))
        continue
    end
    network_id = id_by_fid[fid]
    matches_by_route = Dict{Tuple{Float64,Float64},Vector{NamedTuple}}()
    for match in result.matches
        push!(get!(matches_by_route, match.route_coordinate, NamedTuple[]), match)
    end
    primary_by_route = Dict(route_coordinate => first(sort(matches; by=match -> (match.distance_m, match.station.fid)))
        for (route_coordinate, matches) in matches_by_route)
    forced = Set(keys(primary_by_route))
    records = [(
        source_id="cable_$(fid)_part_$(part_index)",
        name,
        coordinates=part,
        source_attributes_json=String(JSON3.write(feature.properties)),
    ) for (part_index, part) in enumerate(result.parts)]
    normalized = normalize_line_records(
        records;
        coordinate_method="route_geometry_vertex",
        node_note="Derived from approximate cable route geometry.",
        distance_method="geodesic_polyline",
        distance_note="Calculated along the approximate published route; reported whole-system length is retained only as network metadata.",
        forced_node_coordinates=forced,
    )

    nodes = normalized.nodes
    nodes[!, :source_station_fid] = Union{Missing,Int}[missing for _ in 1:nrow(nodes)]
    nodes[!, :source_station_longitude_deg] = Union{Missing,Float64}[missing for _ in 1:nrow(nodes)]
    nodes[!, :source_station_latitude_deg] = Union{Missing,Float64}[missing for _ in 1:nrow(nodes)]
    nodes[!, :source_station_attributes_json] = Union{Missing,String}[missing for _ in 1:nrow(nodes)]
    nodes[!, :route_match_distance_m] = Union{Missing,Float64}[missing for _ in 1:nrow(nodes)]
    vertex_by_coordinate = Dict((Float64(row.longitude_deg), Float64(row.latitude_deg)) => Int(row.vertex) for row in eachrow(nodes))
    used_station_fids = Set{Int}()
    for (route_coordinate, primary) in primary_by_route
        vertex = vertex_by_coordinate[route_coordinate]
        nodes.node_id[vertex] = "station_$(primary.station.fid)"
        nodes.name[vertex] = primary.station.name
        nodes.coordinate_method[vertex] = "route_geometry_vertex_matched_to_station"
        nodes.note[vertex] = "Published route vertex retained; station $(primary.station.fid) is $(primary.distance_m) m away and its source coordinate is retained separately."
        nodes.source_station_fid[vertex] = primary.station.fid
        nodes.source_station_longitude_deg[vertex] = primary.station.coordinate[1]
        nodes.source_station_latitude_deg[vertex] = primary.station.coordinate[2]
        nodes.source_station_attributes_json[vertex] = primary.station.attributes_json
        nodes.route_match_distance_m[vertex] = primary.distance_m
        push!(used_station_fids, primary.station.fid)
    end
    for match in result.matches
        match.station.fid in used_station_fids && continue
        push!(nodes, (;
            vertex=nrow(nodes) + 1,
            node_id="station_$(match.station.fid)",
            name=match.station.name,
            longitude_deg=match.station.coordinate[1],
            latitude_deg=match.station.coordinate[2],
            coordinate_method="published_station_matched_to_route",
            note="Additional source station retained as a distinct isolate; its matched route vertex is already represented by another station.",
            source_feature_ids="cable_$(fid)",
            source_station_fid=match.station.fid,
            source_station_longitude_deg=match.station.coordinate[1],
            source_station_latitude_deg=match.station.coordinate[2],
            source_station_attributes_json=match.station.attributes_json,
            route_match_distance_m=match.distance_m,
        ))
    end
    write_network(output, network_id, nodes, normalized.edges)
    match_distances = getproperty.(result.matches, :distance_m)
    reported_length = feature.properties.Distance_K
    push!(summary_rows, (;
        schema_version=1,
        network_id,
        name,
        description="Historical approximate submarine-cable route and matched landing stations.",
        source_reference="cable FID $(fid)",
        node_count=nrow(nodes),
        edge_count=nrow(normalized.edges),
        component_count=component_count(nrow(nodes), normalized.edges),
        original_directed=false,
        coordinate_method="route_geometry_and_matched_stations",
        distance_method="geodesic_polyline",
        license_identifier=LICENSE,
        license_url=LICENSE_URL,
        citation=CITATION,
        attribution="Greg Mahlknecht / Greg's Global Submarine Cable Map.",
        redistribution_notes="Upstream notice says GNU GPL without a version; license scope and version are ambiguous.",
        source_node_count=length(result.matches),
        source_edge_count=1,
        self_loops_removed=normalized.self_loops_removed,
        parallel_edges_combined=normalized.parallel_edges_combined,
        source_geometry_part_count=length(result.parts),
        reported_system_length_km=isnothing(reported_length) ? missing : Float64(reported_length),
        station_match_max_m=maximum(match_distances),
        station_match_mean_m=sum(match_distances) / length(match_distances),
    ))
    push!(report_rows, (;
        source_reference="cable FID $(fid)",
        network_id,
        status="published",
        detail="$(length(result.matches)) stations matched; maximum vertex distance $(maximum(match_distances)) m",
    ))
end

write_artifact_metadata(output, @__DIR__, DataFrame(summary_rows))
CSV.write(joinpath(output, "extraction_report.csv"), DataFrame(report_rows); missingstring="")
println("Wrote 279 cable networks and 6 exclusions to $(output)")
