using CommunicationNetworkDatasets
using CSV: CSV
using DataFrames: DataFrame, nrow
using Graphs: Edge, SimpleGraph, add_edge!

length(ARGS) == 2 || error("usage: julia --project=. data_sources/validate.jl DATASET_ID ARTIFACT_ROOT")
dataset_id, artifact_root = ARGS
networks_path = joinpath(artifact_root, "networks.csv")
network_table = CommunicationNetworkDatasets._read_csv(
    networks_path; dataset_id, network_id=nothing,
)
CommunicationNetworkDatasets._validate_networks(network_table, networks_path, dataset_id)

for summary in eachrow(network_table)
    network_id = String(summary.network_id)
    root = joinpath(artifact_root, "networks", network_id)
    nodes_path = joinpath(root, "nodes.csv")
    edges_path = joinpath(root, "edges.csv")
    nodes = CommunicationNetworkDatasets._read_csv(nodes_path; dataset_id, network_id)
    edges = CommunicationNetworkDatasets._read_csv(edges_path; dataset_id, network_id)
    CommunicationNetworkDatasets._validate_nodes(nodes, nodes_path, dataset_id, network_id)
    CommunicationNetworkDatasets._validate_edges(edges, edges_path, dataset_id, network_id, nrow(nodes))
    graph = SimpleGraph{Int}(nrow(nodes))
    distances = Dict{Edge{Int},Float64}()
    for row in eachrow(edges)
        edge = Edge{Int}(Int(row.src_vertex), Int(row.dst_vertex))
        add_edge!(graph, edge)
        distances[edge] = Float64(row.distance_m)
    end
    CommunicationNetworkDatasets._validate_loaded(
        graph, distances, nodes, edges, summary, dataset_id, network_id, root,
    )
end

println("Validated $(nrow(network_table)) networks for $(dataset_id) at $(artifact_root)")
