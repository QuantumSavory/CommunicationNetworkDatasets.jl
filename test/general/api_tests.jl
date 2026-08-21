using Test

@testset "discovery, fresh loads, and errors are useful" begin
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
    original_node_note = first_load.nodes.note[1]
    original_edge_note = first_load.edges.distance_note[1]
    first_load.nodes.note[1] = "caller mutation"
    first_load.edges.distance_note[1] = "caller mutation"
    empty!(first_load.distances)
    rem_edge!(first_load.graph, first(edges(first_load.graph)))
    second_load = load_network(dataset_id, network_id)
    @test second_load.nodes.note[1] == original_node_note
    @test second_load.edges.distance_note[1] == original_edge_note
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
