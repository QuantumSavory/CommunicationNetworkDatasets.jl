using Test

@testset "schema validators reject ambiguous primitive types" begin
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
