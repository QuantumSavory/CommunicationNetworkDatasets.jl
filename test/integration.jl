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
    const EXPECTED_DATASETS = Dict(
        "australia_submarine_cables_2021" => (network_count=16, license="CC-BY-4.0", notice="CC-BY-4.0"),
        "cotes_darmor_2016" => (network_count=2, license="etalab-2.0", notice="etalab-2.0"),
        "gold_coast_fibre" => (network_count=1, license="CC-BY-3.0-AU", notice="CC-BY-3.0-AU"),
        "grand_lyon_fibre" => (network_count=1, license="etalab-2.0", notice="etalab-2.0"),
        "gregs_submarine_cable_map" => (network_count=279, license="GNU GPL, version unspecified", notice="GNU GPL, version unspecified"),
        "internet_topology_zoo" => (network_count=85, license="CC-BY-4.0", notice="CC-BY-4.0"),
        "open_undersea_cable_map" => (network_count=519, license="CC-BY-NC-SA-3.0", notice="Attribution-NonCommercial-ShareAlike"),
        "topology_bench" => (network_count=105, license="CC-BY-4.0", notice="CC-BY-4.0"),
        "vermont_state_fibre" => (network_count=2, license="Vermont-Open-Geodata-Policy", notice="non-value-added"),
    )

    catalog = datasets()
    @test names(catalog) == DATASET_COLUMNS
    @test Set(String.(catalog.dataset_id)) == Set(keys(EXPECTED_DATASETS))
    @test sum(catalog.network_count) == 1_010
    @test all(catalog.schema_version .== 1)
    @test all(id -> occursin(r"^[a-z][a-z0-9_]*$", id), catalog.dataset_id)
    @test allunique(catalog.dataset_id)
    @test allunique(catalog.artifact_name)
    @test all(count -> count > 0, catalog.network_count)
    @test all(value -> occursin(r"^\d{4}-\d{2}-\d{2}$", string(value)), catalog.retrieval_date)
    @test all(value -> occursin(r"^[0-9a-f]{40}$", value), catalog.extraction_script_commit)
    @test all(value -> !isempty(value), catalog.upstream_checksum)

    total_networks = Ref(0)
    for dataset in eachrow(catalog)
        expected_dataset = EXPECTED_DATASETS[String(dataset.dataset_id)]
        @test dataset.network_count == expected_dataset.network_count
        @test dataset.license_identifier == expected_dataset.license
        metadata = networks(dataset.dataset_id)
        @test names(metadata)[1:length(NETWORK_COLUMNS)] == NETWORK_COLUMNS
        @test nrow(metadata) == dataset.network_count
        @test all(metadata.schema_version .== 1)
        @test all(id -> occursin(r"^[a-z][a-z0-9_]*$", id), metadata.network_id)
        @test allunique(metadata.network_id)
        @test all(metadata.license_identifier .== dataset.license_identifier)

        artifact_root = CommunicationNetworkDatasets._artifact_root(dataset.dataset_id)
        @test filesize(joinpath(artifact_root, "README.md")) > 0
        license_path = joinpath(artifact_root, "LICENSE.md")
        @test filesize(license_path) > 0
        @test occursin(expected_dataset.notice, read(license_path, String))

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
    first_network_catalog = networks(dataset_id)
    original_network_name = first_network_catalog.name[1]
    first_network_catalog.name[1] = "caller mutation"
    @test networks(dataset_id).name[1] == original_network_name

    network_id = first(first_network_catalog.network_id)
    first_load = load_network(dataset_id, network_id)
    original_node_name = first_load.nodes.name[1]
    original_edge_name = first_load.edges.name[1]
    first_load.nodes.name[1] = "caller mutation"
    first_load.edges.name[1] = "caller mutation"
    empty!(first_load.distances)
    rem_edge!(first_load.graph, first(edges(first_load.graph)))
    second_load = load_network(dataset_id, network_id)
    @test second_load.nodes.name[1] == original_node_name
    @test second_load.edges.name[1] == original_edge_name
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

@testitem "schema validators reject ambiguous primitive types" begin
    using CommunicationNetworkDatasets

    function test_invalid(f, expected_fragments)
        error = try
            f()
            nothing
        catch error
            error
        end
        @test error isa ArgumentError
        message = sprint(showerror, error)
        for fragment in expected_fragments
            @test occursin(fragment, message)
        end
        return nothing
    end

    catalog = datasets()
    catalog[!, :network_count] = Float64.(catalog.network_count)
    test_invalid(["network_count must contain nonnegative integers", "test-datasets.csv"]) do
        CommunicationNetworkDatasets._validate_datasets(catalog, "test-datasets.csv")
    end

    catalog = datasets()
    catalog[!, :schema_version] = Float64.(catalog.schema_version)
    test_invalid(["schema_version must be 1", "test-datasets.csv"]) do
        CommunicationNetworkDatasets._validate_datasets(catalog, "test-datasets.csv")
    end

    dataset_id = first(datasets().dataset_id)
    metadata = networks(dataset_id)
    metadata[!, :node_count] = Float64.(metadata.node_count)
    test_invalid(["node_count must contain nonnegative integers", dataset_id]) do
        CommunicationNetworkDatasets._validate_networks(metadata, "test-networks.csv", dataset_id)
    end

    metadata = networks(dataset_id)
    metadata[!, :original_directed] = Int.(metadata.original_directed)
    test_invalid(["original_directed must contain Boolean values", dataset_id]) do
        CommunicationNetworkDatasets._validate_networks(metadata, "test-networks.csv", dataset_id)
    end

    network_id = first(metadata.network_id)
    loaded = load_network(dataset_id, network_id)
    nodes = copy(loaded.nodes)
    nodes[!, :vertex] = Float64.(nodes.vertex)
    test_invalid(["vertex must be contiguous", network_id]) do
        CommunicationNetworkDatasets._validate_nodes(
            nodes,
            "test-nodes.csv",
            dataset_id,
            network_id,
        )
    end

    nodes = copy(loaded.nodes)
    nodes[!, :longitude_deg] = fill(true, size(nodes, 1))
    test_invalid(["invalid longitude_deg"]) do
        CommunicationNetworkDatasets._validate_nodes(
            nodes,
            "test-nodes.csv",
            dataset_id,
            network_id,
        )
    end

    edges = copy(loaded.edges)
    edges[!, :src_vertex] = fill(true, size(edges, 1))
    test_invalid(["src_vertex < dst_vertex"]) do
        CommunicationNetworkDatasets._validate_edges(
            edges,
            "test-edges.csv",
            dataset_id,
            network_id,
            size(nodes, 1),
        )
    end

    edges = copy(loaded.edges)
    edges[!, :distance_m] = fill(true, size(edges, 1))
    test_invalid(["finite nonnegative distance_m"]) do
        CommunicationNetworkDatasets._validate_edges(
            edges,
            "test-edges.csv",
            dataset_id,
            network_id,
            size(nodes, 1),
        )
    end

    edges = copy(loaded.edges)
    edges[!, :contributing_source_edge_count] = fill(true, size(edges, 1))
    test_invalid(["contributing_source_edge_count >= 1"]) do
        CommunicationNetworkDatasets._validate_edges(
            edges,
            "test-edges.csv",
            dataset_id,
            network_id,
            size(nodes, 1),
        )
    end
end

@testitem "Aqua package checks" begin
    using Aqua
    using CommunicationNetworkDatasets

    Aqua.test_all(CommunicationNetworkDatasets)
end
