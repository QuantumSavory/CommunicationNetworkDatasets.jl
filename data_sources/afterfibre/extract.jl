using CSV: CSV
using DataFrames: DataFrame, nrow
using JSON3: JSON3
using SHA: sha256

include(joinpath(@__DIR__, "..", "common.jl"))
using .ExtractionCommon
include(joinpath(@__DIR__, "mvt_decode.jl"))
using .MVTDecode

const TILEJSON_SHA256 = "a33196caad678c330ca73aed7fbff93e51eb49fbf921180e88829d87a8987e39"
const INVENTORY_SHA256 = "18c97ae3e00282c4f65893553901138177f2a9b08900f04c7f95374b80ca3c69"
const TILE_TEMPLATE = "https://d316kar6yg8hyq.cloudfront.net/africa-fiber/{z}/{x}/{y}.mvt"
const ZOOM = 8
const X_RANGE = 115:167
const Y_RANGE = 99:154
const EXTENT = 4_096
const WARNING = "Routes are manually traced and simplified at source zoom 8; coordinates and distances are approximate."
const Point = Tuple{Float64,Float64}
const Primitive = Tuple{Point,Point}

canonical_primitive(a::Point, b::Point) = a < b ? (a, b) : (b, a)

function clip_segment_to_core(a, b, tile_x, tile_y)
    x_min = Float64(tile_x * EXTENT)
    x_max = Float64((tile_x + 1) * EXTENT)
    y_min = Float64(tile_y * EXTENT)
    y_max = Float64((tile_y + 1) * EXTENT)
    a_x, a_y = Float64(a[1]), Float64(a[2])
    delta_x, delta_y = Float64(b[1] - a[1]), Float64(b[2] - a[2])
    first_parameter, last_parameter = 0.0, 1.0
    for (direction, offset) in (
        (-delta_x, a_x - x_min),
        (delta_x, x_max - a_x),
        (-delta_y, a_y - y_min),
        (delta_y, y_max - a_y),
    )
        if iszero(direction)
            offset < 0 && return nothing
            continue
        end
        parameter = offset / direction
        if direction < 0
            first_parameter = max(first_parameter, parameter)
        else
            last_parameter = min(last_parameter, parameter)
        end
        first_parameter <= last_parameter || return nothing
    end
    canonical_point(parameter) = (
        round(a_x + parameter * delta_x; digits=9),
        round(a_y + parameter * delta_y; digits=9),
    )
    first_point = canonical_point(first_parameter)
    last_point = canonical_point(last_parameter)
    return first_point == last_point ? nothing : canonical_primitive(first_point, last_point)
end

function canonical_json(properties)
    return "{" * join((
        String(JSON3.write(key)) * ":" * String(JSON3.write(properties[key]))
        for key in sort!(collect(keys(properties)))
    ), ",") * "}"
end

function verify_snapshot(source)
    tilejson_path = joinpath(source, "africa-fiber.json")
    inventory_path = joinpath(source, "tile_inventory.csv")
    isfile(tilejson_path) || error("snapshot has no africa-fiber.json")
    isfile(inventory_path) || error("snapshot has no tile_inventory.csv")
    bytes2hex(open(sha256, tilejson_path)) == TILEJSON_SHA256 ||
        error("snapshot TileJSON checksum does not match")
    bytes2hex(open(sha256, inventory_path)) == INVENTORY_SHA256 ||
        error("snapshot tile inventory checksum does not match")
    tilejson = JSON3.read(read(tilejson_path, String))
    String(only(tilejson.tiles)) == TILE_TEMPLATE || error("snapshot tile template changed")

    inventory = CSV.read(inventory_path, DataFrame)
    names(inventory) == ["z", "x", "y", "status", "byte_count", "sha256", "etag"] ||
        error("snapshot inventory schema is invalid")
    nrow(inventory) == 2_968 || error("snapshot inventory row count is invalid")
    expected = [(ZOOM, x, y) for x in X_RANGE for y in Y_RANGE]
    collect(zip(inventory.z, inventory.x, inventory.y)) == expected ||
        error("snapshot inventory order or coverage is invalid")
    count(==(200), inventory.status) == 937 || error("snapshot nonempty tile count changed")
    count(==(204), inventory.status) == 2_031 || error("snapshot empty tile count changed")

    for row in eachrow(inventory)
        tile_path = joinpath(source, "tiles", string(row.z), string(row.x), "$(row.y).mvt")
        if row.status == 200
            isfile(tile_path) || error("missing snapshot tile $(row.z)/$(row.x)/$(row.y)")
            filesize(tile_path) == row.byte_count || error("snapshot tile byte count changed: $(tile_path)")
            bytes2hex(open(sha256, tile_path)) == row.sha256 ||
                error("snapshot tile checksum changed: $(tile_path)")
        elseif row.status == 204
            row.byte_count == 0 || error("empty snapshot tile has a nonzero byte count")
            isfile(tile_path) && error("empty snapshot tile has a file: $(tile_path)")
        else
            error("unsupported snapshot HTTP status $(row.status)")
        end
    end
    return inventory
end

function collect_features(source, inventory)
    properties_by_id = Dict{String,Dict{String,Any}}()
    property_json_by_id = Dict{String,String}()
    primitives_by_id = Dict{String,Set{Primitive}}()

    for row in eachrow(inventory)
        row.status == 200 || continue
        tile_path = joinpath(source, "tiles", string(row.z), string(row.x), "$(row.y).mvt")
        tile = decode_tile(read(tile_path))
        layers = filter(layer -> layer.name == "fiber", tile.layers)
        length(layers) == 1 || error("$(tile_path): expected one fiber layer")
        layer = only(layers)
        layer.version == 2 || error("$(tile_path): expected MVT version 2")
        layer.extent == EXTENT || error("$(tile_path): expected extent $(EXTENT)")
        for feature in layer.features
            feature.id == 0 || error("$(tile_path): unexpected nonzero MVT feature ID")
            values = properties(feature, layer)
            haskey(values, "cartodb_id") || error("$(tile_path): feature has no cartodb_id")
            haskey(values, "live") || error("$(tile_path): feature has no live property")
            values["live"] isa Bool || error("$(tile_path): live property is not Boolean")
            source_id = stable_source_id(values["cartodb_id"])
            encoded = canonical_json(values)
            if haskey(property_json_by_id, source_id)
                property_json_by_id[source_id] == encoded ||
                    error("$(tile_path): properties disagree for cartodb_id $(source_id)")
            else
                properties_by_id[source_id] = values
                property_json_by_id[source_id] = encoded
            end
            primitives = get!(primitives_by_id, source_id, Set{Primitive}())
            for part in line_parts(feature, Int(row.x), Int(row.y), EXTENT)
                for (a, b) in zip(part, @view(part[2:end]))
                    primitive = clip_segment_to_core(a, b, Int(row.x), Int(row.y))
                    isnothing(primitive) || push!(primitives, primitive)
                end
            end
        end
    end
    isempty(primitives_by_id) && error("snapshot contains no AfTerFibre geometry")
    Set(keys(primitives_by_id)) == Set(keys(properties_by_id)) ||
        error("feature properties and geometry identifiers differ")
    return (; properties_by_id, property_json_by_id, primitives_by_id)
end

function maximal_paths(primitives::Set{Primitive})
    adjacency = Dict{Point,Set{Point}}()
    for (a, b) in primitives
        push!(get!(adjacency, a, Set{Point}()), b)
        push!(get!(adjacency, b, Set{Point}()), a)
    end
    unused = copy(primitives)
    paths = Vector{Vector{Point}}()

    function walk(start, next)
        path = Point[start]
        current, following = start, next
        while true
            edge = canonical_primitive(current, following)
            edge in unused || error("stitching attempted to reuse a primitive")
            delete!(unused, edge)
            push!(path, following)
            length(adjacency[following]) == 2 || break
            candidates = sort!([
                neighbor for neighbor in adjacency[following]
                if canonical_primitive(following, neighbor) in unused
            ])
            isempty(candidates) && break
            length(candidates) == 1 || error("ambiguous degree-two route traversal")
            current, following = following, only(candidates)
        end
        return path
    end

    for start in sort!([point for (point, neighbors) in adjacency if length(neighbors) != 2])
        for next in sort!(collect(adjacency[start]))
            canonical_primitive(start, next) in unused || continue
            push!(paths, walk(start, next))
        end
    end
    while !isempty(unused)
        first_edge = minimum(unused)
        cycle = walk(first_edge...)
        first(cycle) == last(cycle) || error("unresolved degree-two component is not a cycle")
        ring = cycle[1:(end - 1)]
        length(ring) >= 3 || error("degenerate primitive cycle")
        second_index = 1 + fld(length(ring), 3)
        third_index = 1 + fld(2 * length(ring), 3)
        push!(paths, ring[1:second_index])
        push!(paths, ring[second_index:third_index])
        push!(paths, [ring[third_index:end]; ring[1]])
    end
    sort!(paths; by=path -> join(("$(point[1]),$(point[2])" for point in path), ";"))
    return paths
end

function wgs84(point::Point)
    scale = Float64(EXTENT * 2^ZOOM)
    longitude = 360 * point[1] / scale - 180
    latitude = rad2deg(atan(sinh(pi * (1 - 2 * point[2] / scale))))
    return (longitude, latitude)
end

function build_records(features, live)
    records = NamedTuple[]
    feature_ids = sort!([
        source_id for (source_id, properties) in features.properties_by_id
        if properties["live"] === live
    ])
    for source_id in feature_ids
        properties = features.properties_by_id[source_id]
        paths = maximal_paths(features.primitives_by_id[source_id])
        isempty(paths) && error("cartodb_id $(source_id) has no usable route")
        name = string(get(properties, "name", get(properties, "operator", "")))
        for (path_index, path) in enumerate(paths)
            push!(records, (;
                source_id="cartodb_$(source_id)_route_$(lpad(path_index, 4, '0'))",
                name,
                coordinates=wgs84.(path),
                source_attributes_json=features.property_json_by_id[source_id],
            ))
        end
    end
    return (; records, feature_ids)
end

options = parse_cli(ARGS; required=["source", "output"])
source = abspath(options["source"])
output = abspath(options["output"])
isdir(source) || error("source is not a snapshot directory: $(source)")
ispath(output) && error("output already exists: $(output)")
mkpath(output)

inventory = verify_snapshot(source)
features = collect_features(source, inventory)
length(features.properties_by_id) == 144 || error(
    "expected 144 stable cartodb_id values; found $(length(features.properties_by_id))",
)
network_rows = NamedTuple[]
report_rows = NamedTuple[]
for (live, network_id, network_name) in (
    (true, "afterfibre_live", "AfTerFibre live routes"),
    (false, "afterfibre_not_live", "AfTerFibre not-live routes"),
)
    selected = build_records(features, live)
    normalized = normalize_line_records(
        selected.records;
        coordinate_method="zoom_8_tile_geometry_vertex",
        node_note="Node derived from an exact shared vertex or endpoint in stitched zoom-8 tile geometry. $(WARNING)",
        distance_method="geodesic_polyline",
        distance_note="Calculated along stitched WGS84 zoom-8 tile geometry. $(WARNING)",
    )
    write_network(output, network_id, normalized.nodes, normalized.edges)
    push!(network_rows, (;
        schema_version=1,
        network_id,
        name=network_name,
        description="AfTerFibre routes grouped by the source live=$(live) property.",
        source_reference="AfTerFibre TileJSON/MVT snapshot at zoom 8, retrieved 2026-08-08",
        node_count=nrow(normalized.nodes),
        edge_count=nrow(normalized.edges),
        component_count=component_count(nrow(normalized.nodes), normalized.edges),
        original_directed=false,
        coordinate_method="zoom_8_tile_geometry_vertex",
        distance_method="geodesic_polyline",
        license_identifier="NOASSERTION",
        license_url="",
        citation="AfTerFibre / Open Telecom Data.",
        attribution="AfTerFibre / Open Telecom Data; upstream trace sources require clarification.",
        redistribution_notes="Deferred from publication: dataset redistribution license is not established. $(WARNING)",
        source_node_count=0,
        source_edge_count=length(selected.feature_ids),
        self_loops_removed=normalized.self_loops_removed,
        parallel_edges_combined=normalized.parallel_edges_combined,
        normalized_segment_count=normalized.segment_count,
        snapshot_tile_count=nrow(inventory),
    ))
    append!(report_rows, [(
        source_reference="cartodb_id=$(source_id)",
        network_id,
        status="deferred",
        detail="Extracted locally; publication waits for written dataset license clarification. $(WARNING)",
    ) for source_id in selected.feature_ids])
end
write_artifact_metadata(output, @__DIR__, DataFrame(network_rows))
CSV.write(joinpath(output, "extraction_report.csv"), DataFrame(report_rows); missingstring="")
println("Wrote two deferred AfTerFibre networks from 144 source features to $(output)")
