const DATASET_COLUMNS = [
    :schema_version,
    :dataset_id,
    :artifact_name,
    :name,
    :description,
    :upstream_url,
    :upstream_version,
    :upstream_checksum,
    :retrieval_date,
    :extraction_script_commit,
    :license_identifier,
    :license_url,
    :citation,
    :attribution,
    :redistribution_notes,
    :network_count,
]

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

const DISTANCE_METHODS = Set([
    "measured",
    "reported",
    "source_calculated",
    "projected_geometry",
    "geodesic_polyline",
    "geodesic_endpoints",
    "scaled_geodesic_endpoints",
    "modeled",
])
const NETWORK_DISTANCE_METHODS = union(DISTANCE_METHODS, Set(["mixed"]))
const ID_PATTERN = r"^[a-z][a-z0-9_]*$"

_is_integer(value) = !ismissing(value) && value isa Integer && !(value isa Bool)
_is_nonnegative_integer(value) = _is_integer(value) && value >= 0
_is_finite_real(value) =
    !ismissing(value) && value isa Real && !(value isa Bool) && isfinite(value)

function _invalid(dataset_id, network_id, path, invariant)
    network_context = isnothing(network_id) ? "" : ", network=$(repr(network_id))"
    throw(ArgumentError(
        "Invalid published data (dataset=$(repr(dataset_id))$(network_context), " *
        "file=$(repr(path))): $(invariant)",
    ))
end

function _read_csv(path; dataset_id, network_id)
    isfile(path) || _invalid(dataset_id, network_id, path, "required file is missing")
    try
        return CSV.read(path, DataFrame; missingstring="", normalizenames=false, strict=true)
    catch error
        _invalid(dataset_id, network_id, path, "CSV parse failed: $(sprint(showerror, error))")
    end
end

function _require_core_columns(table, required, path, dataset_id, network_id)
    actual = propertynames(table)
    length(actual) >= length(required) || _invalid(
        dataset_id,
        network_id,
        path,
        "expected at least $(length(required)) columns; found $(length(actual))",
    )
    actual[eachindex(required)] == required || _invalid(
        dataset_id,
        network_id,
        path,
        "core columns must be first and ordered as $(join(required, ", ")); found $(join(actual, ", "))",
    )
    for column in actual
        occursin(r"^[a-z][a-z0-9_]*$", String(column)) || _invalid(
            dataset_id,
            network_id,
            path,
            "column $(repr(column)) is not snake_case",
        )
    end
end

function _require_unique_ids(values, label, path, dataset_id, network_id)
    any(ismissing, values) && _invalid(dataset_id, network_id, path, "$(label) contains a missing value")
    string_values = String.(values)
    all(value -> occursin(ID_PATTERN, value), string_values) || _invalid(
        dataset_id,
        network_id,
        path,
        "$(label) values must match [a-z][a-z0-9_]*",
    )
    allunique(string_values) || _invalid(dataset_id, network_id, path, "$(label) values are not unique")
end

function _require_schema_version(table, path, dataset_id, network_id)
    all(value -> _is_integer(value) && value == SCHEMA_VERSION, table.schema_version) || _invalid(
        dataset_id,
        network_id,
        path,
        "schema_version must be $(SCHEMA_VERSION)",
    )
end

function _validate_datasets(table, path)
    _require_core_columns(table, DATASET_COLUMNS, path, "catalog", nothing)
    _require_schema_version(table, path, "catalog", nothing)
    _require_unique_ids(table.dataset_id, "dataset_id", path, "catalog", nothing)
    _require_unique_ids(table.artifact_name, "artifact_name", path, "catalog", nothing)
    issorted(table.dataset_id) || _invalid("catalog", nothing, path, "rows must be ordered by dataset_id")
    all(_is_nonnegative_integer, table.network_count) || _invalid(
        "catalog",
        nothing,
        path,
        "network_count must contain nonnegative integers",
    )
    return nothing
end

function _validate_networks(table, path, dataset_id)
    _require_core_columns(table, NETWORK_COLUMNS, path, dataset_id, nothing)
    _require_schema_version(table, path, dataset_id, nothing)
    _require_unique_ids(table.network_id, "network_id", path, dataset_id, nothing)
    issorted(table.network_id) || _invalid(dataset_id, nothing, path, "rows must be ordered by network_id")
    all(method -> !ismissing(method) && method in NETWORK_DISTANCE_METHODS, table.distance_method) ||
        _invalid(dataset_id, nothing, path, "distance_method contains an unsupported value")
    all(value -> value isa Bool, table.original_directed) || _invalid(
        dataset_id,
        nothing,
        path,
        "original_directed must contain Boolean values",
    )
    for column in (:node_count, :edge_count, :component_count, :source_node_count,
            :source_edge_count, :self_loops_removed, :parallel_edges_combined)
        all(_is_nonnegative_integer, table[!, column]) || _invalid(
            dataset_id,
            nothing,
            path,
            "$(column) must contain nonnegative integers",
        )
    end
    return nothing
end

function _validate_nodes(table, path, dataset_id, network_id)
    _require_core_columns(table, NODE_COLUMNS, path, dataset_id, network_id)
    (all(_is_integer, table.vertex) && table.vertex == collect(1:nrow(table))) || _invalid(
        dataset_id,
        network_id,
        path,
        "vertex must be contiguous and ordered from 1 through $(nrow(table))",
    )
    _require_unique_ids(table.node_id, "node_id", path, dataset_id, network_id)
    for (row, longitude, latitude) in zip(eachindex(table.vertex), table.longitude_deg, table.latitude_deg)
        (_is_finite_real(longitude) && -180 <= longitude <= 180) ||
            _invalid(dataset_id, network_id, path, "row $(row) has invalid longitude_deg")
        (_is_finite_real(latitude) && -90 <= latitude <= 90) ||
            _invalid(dataset_id, network_id, path, "row $(row) has invalid latitude_deg")
    end
    return nothing
end

function _validate_edges(table, path, dataset_id, network_id, node_count)
    _require_core_columns(table, EDGE_COLUMNS, path, dataset_id, network_id)
    _require_unique_ids(table.edge_id, "edge_id", path, dataset_id, network_id)
    edge_pairs = Tuple{Int,Int}[]
    for (row_index, row) in enumerate(eachrow(table))
        (_is_integer(row.src_vertex) && _is_integer(row.dst_vertex) &&
            1 <= row.src_vertex < row.dst_vertex <= node_count) || _invalid(
                dataset_id,
                network_id,
                path,
                "row $(row_index) must have 1 <= src_vertex < dst_vertex <= $(node_count)",
            )
        (_is_finite_real(row.distance_m) && row.distance_m >= 0) || _invalid(
                dataset_id,
                network_id,
                path,
                "row $(row_index) must have a finite nonnegative distance_m",
            )
        (!ismissing(row.distance_method) && row.distance_method in DISTANCE_METHODS) || _invalid(
            dataset_id,
            network_id,
            path,
            "row $(row_index) has unsupported distance_method $(repr(row.distance_method))",
        )
        (_is_integer(row.contributing_source_edge_count) &&
            row.contributing_source_edge_count >= 1) || _invalid(
                dataset_id,
                network_id,
                path,
                "row $(row_index) must have contributing_source_edge_count >= 1",
            )
        _validate_geometry_wkt(row.geometry_wkt, row_index, path, dataset_id, network_id)
        push!(edge_pairs, (Int(row.src_vertex), Int(row.dst_vertex)))
    end
    allunique(edge_pairs) || _invalid(
        dataset_id,
        network_id,
        path,
        "canonical undirected vertex pairs are not unique",
    )
    issorted(edge_pairs) || _invalid(
        dataset_id,
        network_id,
        path,
        "rows must be ordered by (src_vertex, dst_vertex)",
    )
    return nothing
end

function _validate_geometry_wkt(value, row_index, path, dataset_id, network_id)
    ismissing(value) && return nothing
    value isa AbstractString || _invalid(
        dataset_id,
        network_id,
        path,
        "row $(row_index) geometry_wkt must be empty or an EPSG:4326 LINESTRING",
    )
    matched = match(r"^LINESTRING \(([^()]*)\)$", value)
    isnothing(matched) && _invalid(
        dataset_id,
        network_id,
        path,
        "row $(row_index) geometry_wkt is not a canonical LINESTRING",
    )
    encoded_points = split(only(matched.captures), ", ")
    length(encoded_points) >= 2 || _invalid(
        dataset_id,
        network_id,
        path,
        "row $(row_index) geometry_wkt has fewer than two coordinates",
    )
    for encoded_point in encoded_points
        ordinates = split(encoded_point, ' ')
        length(ordinates) == 2 || _invalid(
            dataset_id,
            network_id,
            path,
            "row $(row_index) geometry_wkt has a malformed coordinate",
        )
        longitude = tryparse(Float64, ordinates[1])
        latitude = tryparse(Float64, ordinates[2])
        (!isnothing(longitude) && isfinite(longitude) && -180 <= longitude <= 180) || _invalid(
            dataset_id,
            network_id,
            path,
            "row $(row_index) geometry_wkt has an invalid longitude",
        )
        (!isnothing(latitude) && isfinite(latitude) && -90 <= latitude <= 90) || _invalid(
            dataset_id,
            network_id,
            path,
            "row $(row_index) geometry_wkt has an invalid latitude",
        )
    end
    return nothing
end

function _validate_loaded(graph, distances, nodes, edges, summary, dataset_id, network_id, path)
    Graphs.nv(graph) == nrow(nodes) == summary.node_count || _invalid(
        dataset_id,
        network_id,
        path,
        "node count disagrees with networks.csv",
    )
    Graphs.ne(graph) == nrow(edges) == summary.edge_count || _invalid(
        dataset_id,
        network_id,
        path,
        "edge count disagrees with networks.csv",
    )
    Set(keys(distances)) == Set(Graphs.edges(graph)) || _invalid(
        dataset_id,
        network_id,
        path,
        "distance keys do not equal graph edges",
    )
    length(Graphs.connected_components(graph)) == summary.component_count || _invalid(
        dataset_id,
        network_id,
        path,
        "component count disagrees with networks.csv",
    )
    return nothing
end
