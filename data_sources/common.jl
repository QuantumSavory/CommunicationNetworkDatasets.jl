module ExtractionCommon

using CSV: CSV
using DataFrames: DataFrame, Not, nrow, select!, sort!
using Graphs: SimpleGraph, add_edge!, connected_components
using Printf: @sprintf

const NETWORK_COLUMNS = [
    :schema_version,
    :network_id,
    :name,
    :description,
    :source_reference,
    :node_count,
    :edge_count,
    :component_count,
    :original_directed,
    :coordinate_method,
    :distance_method,
    :license_identifier,
    :license_url,
    :citation,
    :attribution,
    :redistribution_notes,
    :source_node_count,
    :source_edge_count,
    :self_loops_removed,
    :parallel_edges_combined,
]

const NODE_COLUMNS = [
    :vertex,
    :node_id,
    :name,
    :longitude_deg,
    :latitude_deg,
    :coordinate_method,
    :note,
]

const EDGE_COLUMNS = [
    :edge_id,
    :src_vertex,
    :dst_vertex,
    :name,
    :distance_m,
    :distance_method,
    :distance_note,
    :contributing_source_edge_count,
    :geometry_wkt,
]

function slug(value)
    result = replace(lowercase(strip(string(value))), r"[^a-z0-9]+" => "_")
    result = strip(result, '_')
    isempty(result) && (result = "unnamed")
    isletter(first(result)) || (result = "id_" * result)
    return result
end

function unique_slugs(values)
    counts = Dict{String,Int}()
    return [begin
        base = slug(value)
        count = get(counts, base, 0) + 1
        counts[base] = count
        count == 1 ? base : "$(base)_$(count)"
    end for value in values]
end

function stable_source_id(value)
    if value isa Integer
        return string(value)
    elseif value isa AbstractFloat && isinteger(value)
        return string(Int(value))
    end
    return strip(string(value))
end

function haversine_m(longitude_a, latitude_a, longitude_b, latitude_b)
    radius_m = 6_371_008.8
    phi_a, phi_b = deg2rad(latitude_a), deg2rad(latitude_b)
    delta_phi = phi_b - phi_a
    delta_lambda = deg2rad(longitude_b - longitude_a)
    a = sin(delta_phi / 2)^2 + cos(phi_a) * cos(phi_b) * sin(delta_lambda / 2)^2
    return 2 * radius_m * asin(min(1.0, sqrt(a)))
end

function polyline_length_m(coordinates)
    length(coordinates) < 2 && return 0.0
    return sum(haversine_m(a[1], a[2], b[1], b[2]) for (a, b) in zip(coordinates, @view(coordinates[2:end])))
end

function linestring_wkt(coordinates)
    length(coordinates) >= 2 || throw(ArgumentError("LINESTRING needs at least two points"))
    points = join(("$(_number(point[1])) $(_number(point[2]))" for point in coordinates), ", ")
    return "LINESTRING ($(points))"
end

_number(value) = @sprintf("%.12g", Float64(value))

function component_count(node_count, edges)
    graph = SimpleGraph{Int}(node_count)
    for row in eachrow(edges)
        add_edge!(graph, Int(row.src_vertex), Int(row.dst_vertex))
    end
    return length(connected_components(graph))
end

function canonicalize_explicit_edges(source_edges, vertex_by_source_id; distance, source_id, name,
        distance_method, distance_note, source_columns=Symbol[])
    removed_loops = 0
    groups = Dict{Tuple{Int,Int},Vector{NamedTuple}}()
    for row in eachrow(source_edges)
        src = vertex_by_source_id[string(row.src)]
        dst = vertex_by_source_id[string(row.dst)]
        if src == dst
            removed_loops += 1
            continue
        end
        pair = minmax(src, dst)
        candidate = (;
            source_id=string(source_id(row)),
            distance_m=Float64(distance(row)),
            name=string(name(row)),
            distance_method=string(distance_method(row)),
            distance_note=string(distance_note(row)),
            source_values=Dict(column => row[column] for column in source_columns),
        )
        push!(get!(groups, pair, NamedTuple[]), candidate)
    end

    edge_rows = NamedTuple[]
    for (pair, candidates) in sort!(collect(groups); by=first)
        sort!(candidates; by=candidate -> (candidate.distance_m, candidate.source_id))
        chosen = first(candidates)
        source_ids = join(sort!(getproperty.(candidates, :source_id)), ";")
        extra = (; (column => join(sort!(unique(string(candidate.source_values[column]) for candidate in candidates)), ";")
            for column in source_columns)...)
        push!(edge_rows, (;
            edge_id="edge_$(pair[1])_$(pair[2])",
            src_vertex=pair[1],
            dst_vertex=pair[2],
            name=chosen.name,
            distance_m=chosen.distance_m,
            distance_method=chosen.distance_method,
            distance_note=chosen.distance_note,
            contributing_source_edge_count=length(candidates),
            geometry_wkt=missing,
            source_edge_ids=source_ids,
            extra...,
        ))
    end
    edges = DataFrame(edge_rows)
    return (; edges, removed_loops, combined_parallel=nrow(source_edges) - removed_loops - nrow(edges))
end

function normalize_line_records(records;
        coordinate_method="geometry_vertex",
        node_note="Node derived from a source geometry endpoint or shared vertex.",
        distance_method="geodesic_polyline",
        distance_note="Calculated along the published WGS84 polyline.",
        distance=(record, segment) -> polyline_length_m(segment))
    cleaned = [merge(record, (; coordinates=_deduplicate_consecutive(record.coordinates))) for record in records]
    all(record -> length(record.coordinates) >= 2, cleaned) ||
        throw(ArgumentError("every line record needs at least two distinct consecutive coordinates"))

    occurrences = Dict{Tuple{Float64,Float64},Int}()
    sources_by_coordinate = Dict{Tuple{Float64,Float64},Set{String}}()
    for record in cleaned, coordinate in record.coordinates
        point = (Float64(coordinate[1]), Float64(coordinate[2]))
        (-180 <= point[1] <= 180 && -90 <= point[2] <= 90 && all(isfinite, point)) ||
            throw(ArgumentError("source $(record.source_id) has an invalid WGS84 coordinate $(point)"))
        occurrences[point] = get(occurrences, point, 0) + 1
        push!(get!(sources_by_coordinate, point, Set{String}()), string(record.source_id))
    end

    segments = NamedTuple[]
    for record in cleaned
        route = [(Float64(point[1]), Float64(point[2])) for point in record.coordinates]
        split_indices = unique(sort!([1;
            [index for index in 2:(length(route) - 1) if occurrences[route[index]] > 1];
            length(route)]))
        for (first_index, last_index) in zip(split_indices, @view(split_indices[2:end]))
            segment = route[first_index:last_index]
            value = Float64(distance(record, segment))
            isfinite(value) && value >= 0 || throw(ArgumentError(
                "source $(record.source_id) produced invalid distance $(value)",
            ))
            push!(segments, (;
                source_id=string(record.source_id),
                name=string(record.name),
                source_attributes_json=string(record.source_attributes_json),
                coordinates=segment,
                distance_m=value,
            ))
        end
    end

    node_coordinates = sort!(unique(vcat(
        [segment.coordinates[1] for segment in segments],
        [segment.coordinates[end] for segment in segments],
    )))
    vertex_by_coordinate = Dict(coordinate => vertex for (vertex, coordinate) in enumerate(node_coordinates))
    nodes = DataFrame(
        vertex=collect(eachindex(node_coordinates)),
        node_id=["node_$(lpad(vertex, 6, '0'))" for vertex in eachindex(node_coordinates)],
        name=fill("", length(node_coordinates)),
        longitude_deg=first.(node_coordinates),
        latitude_deg=last.(node_coordinates),
        coordinate_method=fill(coordinate_method, length(node_coordinates)),
        note=fill(node_note, length(node_coordinates)),
        source_feature_ids=[join(sort!(collect(get(sources_by_coordinate, coordinate, Set{String}()))), ";")
            for coordinate in node_coordinates],
    )

    self_loops = 0
    grouped = Dict{Tuple{Int,Int},Vector{NamedTuple}}()
    for segment in segments
        src = vertex_by_coordinate[segment.coordinates[1]]
        dst = vertex_by_coordinate[segment.coordinates[end]]
        if src == dst
            self_loops += 1
            continue
        end
        pair = minmax(src, dst)
        oriented_coordinates = src == pair[1] ? segment.coordinates : reverse(segment.coordinates)
        candidate = merge(segment, (; pair, coordinates=oriented_coordinates))
        push!(get!(grouped, pair, NamedTuple[]), candidate)
    end

    edge_rows = NamedTuple[]
    for (pair, alternatives) in sort!(collect(grouped); by=first)
        sort!(alternatives; by=candidate -> (candidate.distance_m, candidate.source_id))
        chosen = first(alternatives)
        push!(edge_rows, (;
            edge_id="edge_$(pair[1])_$(pair[2])",
            src_vertex=pair[1],
            dst_vertex=pair[2],
            name=chosen.name,
            distance_m=chosen.distance_m,
            distance_method,
            distance_note,
            contributing_source_edge_count=length(alternatives),
            geometry_wkt=linestring_wkt(chosen.coordinates),
            source_edge_ids=join(sort!(getproperty.(alternatives, :source_id)), ";"),
            selected_source_edge_id=chosen.source_id,
            source_attributes_json="[" * join(sort!(getproperty.(alternatives, :source_attributes_json)), ",") * "]",
        ))
    end
    edges = DataFrame(edge_rows)
    return (;
        nodes,
        edges,
        self_loops_removed=self_loops,
        parallel_edges_combined=length(segments) - self_loops - nrow(edges),
        segment_count=length(segments),
    )
end

function _deduplicate_consecutive(coordinates)
    result = Tuple{Float64,Float64}[]
    for coordinate in coordinates
        point = (Float64(coordinate[1]), Float64(coordinate[2]))
        isempty(result) || point != result[end] || continue
        push!(result, point)
    end
    return result
end

function write_network(output_root, network_id, nodes, edges)
    sort!(nodes, :vertex)
    sort!(edges, [:src_vertex, :dst_vertex])
    select!(nodes, NODE_COLUMNS..., Not(NODE_COLUMNS))
    select!(edges, EDGE_COLUMNS..., Not(EDGE_COLUMNS))
    network_root = joinpath(output_root, "networks", network_id)
    mkpath(network_root)
    CSV.write(joinpath(network_root, "nodes.csv"), nodes; missingstring="")
    CSV.write(joinpath(network_root, "edges.csv"), edges; missingstring="")
    return nothing
end

function write_artifact_metadata(output_root, source_root, networks)
    sort!(networks, :network_id)
    select!(networks, NETWORK_COLUMNS..., Not(NETWORK_COLUMNS))
    mkpath(output_root)
    CSV.write(joinpath(output_root, "networks.csv"), networks; missingstring="")
    cp(joinpath(source_root, "README.md"), joinpath(output_root, "README.md"); force=true)
    cp(joinpath(source_root, "LICENSE.md"), joinpath(output_root, "LICENSE.md"); force=true)
    return nothing
end

function parse_cli(arguments; required=String[])
    options = Dict{String,String}()
    index = 1
    while index <= length(arguments)
        startswith(arguments[index], "--") || throw(ArgumentError("expected --option, got $(arguments[index])"))
        index == length(arguments) && throw(ArgumentError("missing value after $(arguments[index])"))
        options[arguments[index][3:end]] = arguments[index + 1]
        index += 2
    end
    for name in required
        haskey(options, name) || throw(ArgumentError("missing required option --$(name)"))
    end
    return options
end

export NETWORK_COLUMNS,
    NODE_COLUMNS,
    EDGE_COLUMNS,
    slug,
    unique_slugs,
    stable_source_id,
    haversine_m,
    polyline_length_m,
    linestring_wkt,
    component_count,
    canonicalize_explicit_edges,
    normalize_line_records,
    write_network,
    write_artifact_metadata,
    parse_cli

end
