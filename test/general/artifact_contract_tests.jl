using Test

@testset "all released artifacts satisfy the public contract" begin
    using CommunicationNetworkDatasets
    using DataFrames: nrow
    using Graphs: Edge, SimpleGraph, connected_components, edges, ne, nv

    DATASET_COLUMNS = [
        "schema_version", "dataset_id", "artifact_name", "name", "description", "upstream_url",
        "upstream_version", "upstream_checksum", "retrieval_date", "extraction_script_commit",
        "license_identifier", "license_url", "citation", "attribution", "redistribution_notes",
        "network_count",
    ]
    NETWORK_COLUMNS = [
        "schema_version", "network_id", "name", "description", "source_reference", "node_count",
        "edge_count", "component_count", "original_directed", "coordinate_method",
        "distance_method", "license_identifier", "license_url", "citation", "attribution",
        "redistribution_notes", "source_node_count", "source_edge_count", "self_loops_removed",
        "parallel_edges_combined",
    ]
    NODE_COLUMNS = [
        "vertex", "node_id", "name", "longitude_deg", "latitude_deg", "coordinate_method", "note",
    ]
    EDGE_COLUMNS = [
        "edge_id", "src_vertex", "dst_vertex", "name", "distance_m", "distance_method",
        "distance_note", "contributing_source_edge_count", "geometry_wkt",
    ]
    DISTANCE_METHODS = Set([
        "measured", "reported", "source_calculated", "projected_geometry", "geodesic_polyline",
        "geodesic_endpoints", "scaled_geodesic_endpoints", "modeled",
    ])
    EXPECTED_DATASETS = Dict(
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
