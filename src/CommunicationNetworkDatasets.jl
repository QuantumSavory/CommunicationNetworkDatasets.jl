module CommunicationNetworkDatasets

using CSV: CSV
using DataFrames: DataFrame, nrow
import Graphs
using Graphs: Edge, SimpleGraph, add_edge!
using LazyArtifacts: LazyArtifacts, artifact_hash, artifact_path
using WeakDepHelpers: WeakDepCache, @declare_method_is_in_extension, register_weakdep_cache

export datasets, networks, load_network, plot_network

const SCHEMA_VERSION = 1
const PACKAGE_ROOT = normpath(joinpath(@__DIR__, ".."))
const DATASETS_PATH = joinpath(PACKAGE_ROOT, "data", "datasets.csv")
const ARTIFACTS_PATH = joinpath(PACKAGE_ROOT, "Artifacts.toml")
const WEAKDEP_CACHE = WeakDepCache()

include("validation.jl")

"""
    datasets() -> DataFrame

Return a fresh copy of the package-tracked dataset catalog. This call does not download artifacts.
"""
function datasets()
    table = _read_csv(DATASETS_PATH; dataset_id="catalog", network_id=nothing)
    _validate_datasets(table, DATASETS_PATH)
    return table
end

function _dataset_row(dataset_id::AbstractString)
    catalog = datasets()
    rows = findall(==(dataset_id), catalog.dataset_id)
    isempty(rows) && throw(ArgumentError(
        "Unknown dataset_id $(repr(dataset_id)). Call datasets() to list available datasets.",
    ))
    return catalog[only(rows), :]
end

function _artifact_root(dataset_id::AbstractString)
    row = _dataset_row(dataset_id)
    artifact_name = String(row.artifact_name)
    isfile(ARTIFACTS_PATH) || error(
        "Dataset $(repr(dataset_id)): missing artifact binding file $(ARTIFACTS_PATH)",
    )
    hash = artifact_hash(artifact_name, ARTIFACTS_PATH)
    isnothing(hash) && error(
        "Dataset $(repr(dataset_id)): artifact $(repr(artifact_name)) is not bound in $(ARTIFACTS_PATH)",
    )
    LazyArtifacts.ensure_artifact_installed(artifact_name, ARTIFACTS_PATH)
    return artifact_path(hash)
end

"""
    networks(dataset_id::AbstractString) -> DataFrame

Install the named lazy dataset artifact if needed, validate its index, and return a fresh network
catalog.
"""
function networks(dataset_id::AbstractString)
    root = _artifact_root(dataset_id)
    path = joinpath(root, "networks.csv")
    table = _read_csv(path; dataset_id, network_id=nothing)
    _validate_networks(table, path, dataset_id)

    expected = Int(_dataset_row(dataset_id).network_count)
    nrow(table) == expected || _invalid(
        dataset_id,
        nothing,
        path,
        "network_count is $(nrow(table)); datasets.csv declares $(expected)",
    )
    return table
end

"""
    load_network(dataset_id::AbstractString, network_id::AbstractString)

Load and validate one normalized network. The returned graph, distance dictionary, and tables are
new mutable objects on every call. Distances are in metres.
"""
function load_network(dataset_id::AbstractString, network_id::AbstractString)
    network_table = networks(dataset_id)
    rows = findall(==(network_id), network_table.network_id)
    isempty(rows) && throw(ArgumentError(
        "Unknown network_id $(repr(network_id)) for dataset $(repr(dataset_id)). " *
        "Call networks($(repr(dataset_id))) to list available networks.",
    ))
    summary = network_table[only(rows), :]
    root = _artifact_root(dataset_id)
    network_root = joinpath(root, "networks", network_id)
    nodes_path = joinpath(network_root, "nodes.csv")
    edges_path = joinpath(network_root, "edges.csv")
    nodes = _read_csv(nodes_path; dataset_id, network_id)
    edges = _read_csv(edges_path; dataset_id, network_id)
    _validate_nodes(nodes, nodes_path, dataset_id, network_id)
    _validate_edges(edges, edges_path, dataset_id, network_id, nrow(nodes))

    graph = SimpleGraph{Int}(nrow(nodes))
    distances = Dict{Edge{Int},Float64}()
    for edge_row in eachrow(edges)
        edge = Edge{Int}(Int(edge_row.src_vertex), Int(edge_row.dst_vertex))
        add_edge!(graph, edge) || _invalid(
            dataset_id,
            network_id,
            edges_path,
            "edge $(repr(edge_row.edge_id)) duplicates an existing undirected edge",
        )
        distances[edge] = Float64(edge_row.distance_m)
    end
    _validate_loaded(graph, distances, nodes, edges, summary, dataset_id, network_id, network_root)
    return (; graph, distances, nodes, edges)
end

@declare_method_is_in_extension WEAKDEP_CACHE plot_network (:Tyler, :CairoMakie) """
    plot_network(args...; kwargs...)

Plot a network in WGS84 coordinates. Accept either dataset and network identifiers or the named
tuple returned by [`load_network`](@ref). The Tyler extension is loaded after importing Tyler and a
Makie backend. It returns `(; figure, axis, map, node_plot, edge_plot, omitted_vertices,
omitted_edges)`. The caller owns the returned Tyler map and must wait for or close it when needed.
"""

function __init__()
    register_weakdep_cache(WEAKDEP_CACHE)
end

end
