using CairoMakie
using CommunicationNetworkDatasets
using DataFrames: DataFrame
using Graphs: Edge, SimpleGraph, add_edge!
using Test
using Tyler

const PACKAGE_ROOT = normpath(joinpath(dirname(pathof(CommunicationNetworkDatasets)), ".."))
include(joinpath(PACKAGE_ROOT, "ci", "CITiles.jl"))
CairoMakie.activate!(; visible=false)

function explicit_network(nodes, edges)
    graph = SimpleGraph{Int}(size(nodes, 1))
    distances = Dict{Edge{Int},Float64}()
    for row in eachrow(edges)
        edge = Edge{Int}(row.src_vertex, row.dst_vertex)
        add_edge!(graph, edge)
        distances[edge] = 1.0
    end
    return (; graph, distances, nodes, edges)
end

function nodes_table(longitudes, latitudes)
    count = length(longitudes)
    return DataFrame(
        vertex=collect(1:count),
        node_id=["node_$(index)" for index in 1:count],
        name=fill("", count),
        longitude_deg=longitudes,
        latitude_deg=latitudes,
        coordinate_method=fill("explicit_test", count),
        note=fill("", count),
    )
end

function edges_table(rows=NamedTuple[])
    isempty(rows) && return DataFrame(
        edge_id=String[], src_vertex=Int[], dst_vertex=Int[], geometry_wkt=Union{Missing,String}[],
    )
    return DataFrame(rows)
end

@testset "Tyler extension with QuantumSavory CI tiles" begin
    withenv("TILE_CI_KEY" => nothing) do
        @test CITiles.tile_url() == CITiles.TILE_TEMPLATE
    end
    withenv("TILE_CI_KEY" => repeat("a", 64)) do
        @test CITiles.tile_url() == CITiles.TILE_TEMPLATE * "?ci_key=" * repeat("a", 64)
    end
    withenv("TILE_CI_KEY" => "invalid") do
        @test_throws ArgumentError CITiles.provider()
    end
    CITiles.preflight()
    provider = CITiles.provider()
    result = plot_network(
        "australia_submarine_cables_2021",
        first(networks("australia_submarine_cables_2021").network_id);
        provider,
        map_kwargs=(; fetching_scheme=Tyler.SimpleTiling(), max_parallel_downloads=1),
    )
    try
        @test keys(result) == (
            :figure, :axis, :map, :node_plot, :edge_plot, :omitted_vertices, :omitted_edges,
        )
        @test result.map.provider === provider
        @test isempty(result.omitted_vertices)
        @test isempty(result.omitted_edges)
        wait(result.map)
        image_path = joinpath(mktempdir(), "network.png")
        save(image_path, result.figure)
        @test filesize(image_path) > 1_000

        route = explicit_network(
            nodes_table([0.0, 2.0], [0.0, 0.0]),
            edges_table([(;
                edge_id="route_edge", src_vertex=1, dst_vertex=2,
                geometry_wkt="LINESTRING (0 0, 1 1, 2 0)",
            )]),
        )
        route_result = plot_network(route; map=result.map)
        @test isempty(route_result.omitted_edges)

        incomplete = explicit_network(
            nodes_table(Union{Missing,Float64}[0.0, missing], Union{Missing,Float64}[0.0, 1.0]),
            edges_table([(;
                edge_id="incomplete_edge", src_vertex=1, dst_vertex=2,
                geometry_wkt=missing,
            )]),
        )
        incomplete_result = plot_network(incomplete; map=result.map)
        @test incomplete_result.omitted_vertices == [2]
        @test incomplete_result.omitted_edges == ["incomplete_edge"]

        point = explicit_network(nodes_table([12.5], [41.9]), edges_table())
        point_result = plot_network(point; map=result.map)
        point_limits = point_result.axis.targetlimits[]
        @test point_limits.widths[1] > 0
        @test point_limits.widths[2] > 0

        antimeridian = explicit_network(
            nodes_table([179.0, -179.0], [10.0, 11.0]),
            edges_table([(;
                edge_id="dateline_edge", src_vertex=1, dst_vertex=2,
                geometry_wkt="LINESTRING (179 10, -179 11)",
            )]),
        )
        antimeridian_result = plot_network(antimeridian; map=result.map)
        dateline_limits = antimeridian_result.axis.targetlimits[]
        @test dateline_limits.origin[1] ≈ -180
        @test dateline_limits.widths[1] ≈ 360
    finally
        close(result.map)
    end
end
