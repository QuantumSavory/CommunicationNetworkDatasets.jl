@testitem "all released artifacts satisfy the public contract" begin
    using CommunicationNetworkDatasets
    using DataFrames: nrow
    using Graphs: Edge, SimpleGraph, connected_components, edges, ne, nv

    const DATASET_COLUMNS = [
        "schema_version", "dataset_id", "artifact_name", "name", "description", "upstream_url",
        "upstream_version", "upstream_checksum", "retrieval_date", "extraction_script_commit",
        "license_identifier", "license_url", "citation", "attribution", "redistribution_notes",
        "network_count",
    ]
    const NETWORK_COLUMNS = [
        "schema_version", "network_id", "name", "description", "source_reference", "node_count",
        "edge_count", "component_count", "original_directed", "coordinate_method",
        "distance_method", "license_identifier", "license_url", "citation", "attribution",
        "redistribution_notes", "source_node_count", "source_edge_count", "self_loops_removed",
        "parallel_edges_combined",
    ]
    const NODE_COLUMNS = [
        "vertex", "node_id", "name", "longitude_deg", "latitude_deg", "coordinate_method", "note",
    ]
    const EDGE_COLUMNS = [
        "edge_id", "src_vertex", "dst_vertex", "name", "distance_m", "distance_method",
        "distance_note", "contributing_source_edge_count", "geometry_wkt",
    ]
    const DISTANCE_METHODS = Set([
        "measured", "reported", "source_calculated", "projected_geometry", "geodesic_polyline",
        "geodesic_endpoints", "scaled_geodesic_endpoints", "modeled",
    ])

    catalog = datasets()
    @test names(catalog) == DATASET_COLUMNS
    @test all(catalog.schema_version .== 1)
    @test all(id -> occursin(r"^[a-z][a-z0-9_]*$", id), catalog.dataset_id)
    @test allunique(catalog.dataset_id)
    @test allunique(catalog.artifact_name)
    @test all(count -> count > 0, catalog.network_count)

    total_networks = Ref(0)
    for dataset in eachrow(catalog)
        metadata = networks(dataset.dataset_id)
        @test names(metadata)[1:length(NETWORK_COLUMNS)] == NETWORK_COLUMNS
        @test nrow(metadata) == dataset.network_count
        @test all(metadata.schema_version .== 1)
        @test all(id -> occursin(r"^[a-z][a-z0-9_]*$", id), metadata.network_id)
        @test allunique(metadata.network_id)
        @test all(metadata.license_identifier .== dataset.license_identifier)

        artifact_root = CommunicationNetworkDatasets._artifact_root(dataset.dataset_id)
        @test filesize(joinpath(artifact_root, "README.md")) > 0
        @test filesize(joinpath(artifact_root, "LICENSE.md")) > 0

        for network in eachrow(metadata)
            loaded = load_network(dataset.dataset_id, network.network_id)
            total_networks[] += 1
            @test loaded.graph isa SimpleGraph{Int}
            @test names(loaded.nodes)[1:length(NODE_COLUMNS)] == NODE_COLUMNS
            @test names(loaded.edges)[1:length(EDGE_COLUMNS)] == EDGE_COLUMNS
            @test loaded.nodes.vertex == collect(1:nrow(loaded.nodes))
            @test allunique(loaded.nodes.node_id)
            @test all(id -> occursin(r"^[a-z][a-z0-9_]*$", id), loaded.nodes.node_id)
            @test all(isfinite, loaded.nodes.longitude_deg)
            @test all(isfinite, loaded.nodes.latitude_deg)
            @test all((-180 .<= loaded.nodes.longitude_deg) .& (loaded.nodes.longitude_deg .<= 180))
            @test all((-90 .<= loaded.nodes.latitude_deg) .& (loaded.nodes.latitude_deg .<= 90))

            @test allunique(loaded.edges.edge_id)
            @test all(id -> occursin(r"^[a-z][a-z0-9_]*$", id), loaded.edges.edge_id)
            @test all(loaded.edges.src_vertex .< loaded.edges.dst_vertex)
            @test all(isfinite, loaded.edges.distance_m)
            @test all(loaded.edges.distance_m .>= 0)
            @test all(method -> method in DISTANCE_METHODS, loaded.edges.distance_method)
            @test all(loaded.edges.contributing_source_edge_count .>= 1)

            expected_edges = Set(Edge{Int}(row.src_vertex, row.dst_vertex) for row in eachrow(loaded.edges))
            @test Set(edges(loaded.graph)) == expected_edges
            @test Set(keys(loaded.distances)) == expected_edges
            @test all(loaded.distances[Edge{Int}(row.src_vertex, row.dst_vertex)] == row.distance_m
                for row in eachrow(loaded.edges))
            @test nv(loaded.graph) == network.node_count == nrow(loaded.nodes)
            @test ne(loaded.graph) == network.edge_count == nrow(loaded.edges)
            @test length(connected_components(loaded.graph)) == network.component_count
            @test network.distance_method == "mixed" || network.distance_method in DISTANCE_METHODS
            @test network.self_loops_removed >= 0
            @test network.parallel_edges_combined >= 0
        end
    end
    @test total_networks[] == sum(catalog.network_count)
end

@testitem "discovery, fresh loads, and errors are useful" begin
    using CommunicationNetworkDatasets
    using Graphs: edges, ne, rem_edge!

    first_catalog = datasets()
    original_name = first_catalog.name[1]
    first_catalog.name[1] = "caller mutation"
    @test datasets().name[1] == original_name

    dataset_id = first(datasets().dataset_id)
    network_id = first(networks(dataset_id).network_id)
    first_load = load_network(dataset_id, network_id)
    original_node_name = first_load.nodes.name[1]
    first_load.nodes.name[1] = "caller mutation"
    empty!(first_load.distances)
    rem_edge!(first_load.graph, first(edges(first_load.graph)))
    second_load = load_network(dataset_id, network_id)
    @test second_load.nodes.name[1] == original_node_name
    @test !isempty(second_load.distances)
    @test ne(second_load.graph) > ne(first_load.graph)

    dataset_error = try
        networks("not_a_dataset")
        nothing
    catch error
        error
    end
    @test dataset_error isa ArgumentError
    @test occursin("datasets()", sprint(showerror, dataset_error))

    network_error = try
        load_network(dataset_id, "not_a_network")
        nothing
    catch error
        error
    end
    @test network_error isa ArgumentError
    @test occursin("networks", sprint(showerror, network_error))

    extension_error = try
        plot_network((;))
        nothing
    catch error
        error
    end
    @test extension_error isa MethodError
    hint = sprint(showerror, extension_error)
    @test occursin("Tyler", hint)
    @test occursin("CairoMakie", hint)
end

@testitem "Aqua package checks" begin
    using Aqua
    using CommunicationNetworkDatasets

    Aqua.test_all(CommunicationNetworkDatasets)
end
