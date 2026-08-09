module CommunicationNetworkDatasetsTylerExt

import Makie
import Tyler
import CommunicationNetworkDatasets: load_network, plot_network

const DEFAULT_NODE_STYLE = (; color=:dodgerblue, markersize=9)
const DEFAULT_EDGE_STYLE = (; color=:navy, linewidth=1.5)

function _valid_coordinate(longitude, latitude)
    return !ismissing(longitude) && !ismissing(latitude) &&
        longitude isa Real && latitude isa Real &&
        isfinite(longitude) && isfinite(latitude) &&
        -180 <= longitude <= 180 && -90 <= latitude <= 90
end

function _parse_linestring(value, edge_id)
    ismissing(value) && return nothing
    text = strip(String(value))
    isempty(text) && return nothing
    matched = match(r"^LINESTRING\s*\((.*)\)$"i, text)
    isnothing(matched) && throw(ArgumentError(
        "edge $(repr(edge_id)) has unsupported geometry_wkt; expected generated LINESTRING data",
    ))
    points = Tuple{Float64,Float64}[]
    for encoded_point in split(only(matched.captures), ',')
        ordinates = split(strip(encoded_point))
        length(ordinates) == 2 || throw(ArgumentError(
            "edge $(repr(edge_id)) has malformed LINESTRING coordinate $(repr(encoded_point))",
        ))
        longitude = tryparse(Float64, ordinates[1])
        latitude = tryparse(Float64, ordinates[2])
        (isnothing(longitude) || isnothing(latitude)) && throw(ArgumentError(
            "edge $(repr(edge_id)) has a nonnumeric LINESTRING coordinate $(repr(encoded_point))",
        ))
        push!(points, (longitude, latitude))
    end
    length(points) >= 2 || throw(ArgumentError(
        "edge $(repr(edge_id)) has a LINESTRING with fewer than two coordinates",
    ))
    return points
end

function _split_antimeridian(route)
    segments = Vector{Vector{Tuple{Float64,Float64}}}()
    current = Tuple{Float64,Float64}[first(route)]
    crossed = false
    for point in @view(route[2:end])
        previous = last(current)
        delta = point[1] - previous[1]
        if abs(delta) <= 180
            push!(current, point)
            continue
        end
        crossed = true
        adjusted_longitude = delta > 180 ? point[1] - 360 : point[1] + 360
        boundary = delta > 180 ? -180.0 : 180.0
        opposite_boundary = -boundary
        fraction = (boundary - previous[1]) / (adjusted_longitude - previous[1])
        crossing_latitude = previous[2] + fraction * (point[2] - previous[2])
        push!(current, (boundary, crossing_latitude))
        push!(segments, current)
        current = Tuple{Float64,Float64}[(opposite_boundary, crossing_latitude), point]
    end
    push!(segments, current)
    return segments, crossed
end

function _extent(coordinates, crosses_antimeridian)
    isempty(coordinates) && return Makie.Rect2f(-180, -90, 360, 180)
    longitudes = first.(coordinates)
    latitudes = last.(coordinates)
    latitude_min, latitude_max = extrema(latitudes)
    latitude_span = latitude_max - latitude_min
    latitude_pad = latitude_span == 0 ? 0.25 : max(0.05, 0.05 * latitude_span)
    ymin = max(-90.0, latitude_min - latitude_pad)
    ymax = min(90.0, latitude_max + latitude_pad)
    ymin == ymax && ((ymin, ymax) = (max(-90.0, ymin - 0.25), min(90.0, ymax + 0.25)))

    if crosses_antimeridian
        return Makie.Rect2f(-180, ymin, 360, ymax - ymin)
    end
    longitude_min, longitude_max = extrema(longitudes)
    longitude_span = longitude_max - longitude_min
    longitude_pad = longitude_span == 0 ? 0.25 : max(0.05, 0.05 * longitude_span)
    xmin = max(-180.0, longitude_min - longitude_pad)
    xmax = min(180.0, longitude_max + longitude_pad)
    xmin == xmax && ((xmin, xmax) = (max(-180.0, xmin - 0.25), min(180.0, xmax + 0.25)))
    return Makie.Rect2f(xmin, ymin, xmax - xmin, ymax - ymin)
end

function _plot_data(network)
    hasproperty(network, :nodes) && hasproperty(network, :edges) || throw(ArgumentError(
        "plot_network expects the named tuple returned by load_network, including nodes and edges",
    ))
    coordinates_by_vertex = Dict{Int,Tuple{Float64,Float64}}()
    omitted_vertices = Int[]
    for row in eachrow(network.nodes)
        vertex = Int(row.vertex)
        if _valid_coordinate(row.longitude_deg, row.latitude_deg)
            coordinates_by_vertex[vertex] = (Float64(row.longitude_deg), Float64(row.latitude_deg))
        else
            push!(omitted_vertices, vertex)
        end
    end

    node_coordinates = [coordinates_by_vertex[vertex] for vertex in sort!(collect(keys(coordinates_by_vertex)))]
    line_segments = Vector{Vector{Tuple{Float64,Float64}}}()
    omitted_edges = String[]
    crosses_antimeridian = false
    extent_coordinates = copy(node_coordinates)
    for row in eachrow(network.edges)
        edge_id = String(row.edge_id)
        src_vertex, dst_vertex = Int(row.src_vertex), Int(row.dst_vertex)
        if !haskey(coordinates_by_vertex, src_vertex) || !haskey(coordinates_by_vertex, dst_vertex)
            push!(omitted_edges, edge_id)
            continue
        end
        route = hasproperty(row, :geometry_wkt) ? _parse_linestring(row.geometry_wkt, edge_id) : nothing
        isnothing(route) && (route = [coordinates_by_vertex[src_vertex], coordinates_by_vertex[dst_vertex]])
        if !all(point -> _valid_coordinate(point[1], point[2]), route)
            push!(omitted_edges, edge_id)
            continue
        end
        segments, crossed = _split_antimeridian(route)
        append!(line_segments, segments)
        append!(extent_coordinates, route)
        crosses_antimeridian |= crossed
    end
    return (; node_coordinates, line_segments, extent_coordinates, crosses_antimeridian,
        omitted_vertices=sort!(omitted_vertices), omitted_edges=sort!(omitted_edges))
end

function _line_coordinates(segments)
    longitudes = Float64[]
    latitudes = Float64[]
    for segment in segments
        append!(longitudes, first.(segment))
        append!(latitudes, last.(segment))
        push!(longitudes, NaN)
        push!(latitudes, NaN)
    end
    return longitudes, latitudes
end

function plot_network(dataset_id::AbstractString, network_id::AbstractString; kwargs...)
    return plot_network(load_network(dataset_id, network_id); kwargs...)
end

function plot_network(network::NamedTuple;
        provider=Tyler.TileProviders.OpenStreetMap(:Mapnik),
        figure=Makie.Figure(; size=(1000, 700)),
        map=nothing,
        map_kwargs=(;),
        node_style=DEFAULT_NODE_STYLE,
        edge_style=DEFAULT_EDGE_STYLE)
    data = _plot_data(network)
    extent = _extent(data.extent_coordinates, data.crosses_antimeridian)
    tyler_map = if isnothing(map)
        forbidden = intersect(keys(map_kwargs), (:provider, :figure, :crs))
        isempty(forbidden) || throw(ArgumentError(
            "map_kwargs cannot override provider, figure, or the required WGS84 CRS",
        ))
        Tyler.Map(extent, Tyler.wgs84; provider, figure, crs=Tyler.wgs84, map_kwargs...)
    else
        map.crs == Tyler.wgs84 || throw(ArgumentError("the supplied Tyler map must use the WGS84 CRS"))
        Makie.limits!(map.axis, (extent.origin[1], extent.origin[1] + extent.widths[1]),
            (extent.origin[2], extent.origin[2] + extent.widths[2]))
        map
    end
    axis = tyler_map.axis
    edge_longitudes, edge_latitudes = _line_coordinates(data.line_segments)
    edge_plot = Makie.lines!(axis, edge_longitudes, edge_latitudes; edge_style...)
    node_plot = Makie.scatter!(axis, first.(data.node_coordinates), last.(data.node_coordinates); node_style...)
    return (;
        figure=tyler_map.figure,
        axis,
        map=tyler_map,
        node_plot,
        edge_plot,
        omitted_vertices=data.omitted_vertices,
        omitted_edges=data.omitted_edges,
    )
end

end
