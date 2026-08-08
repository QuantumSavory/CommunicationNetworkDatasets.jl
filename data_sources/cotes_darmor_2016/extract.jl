using CSV: CSV
using DataFrames: DataFrame, nrow
using JSON3: JSON3
using SHA: sha256

include(joinpath(@__DIR__, "..", "common.jl"))
using .ExtractionCommon

const CHECKSUMS = Dict(
    "nodes" => "9f14059ff85ecbfb14d60f9a2bfe12cb3fcf41d741c5ac96b38f5344eff30bc0",
    "arteries" => "c25691c121ef85d9cb1c4ab475d39d2bd1c4bbd302781503e9b7cd3fc5e22c58",
    "cables" => "de8330b160860808a5d4d19957fce9d7d58cd5842cdb6ba60411bee65516c5f6",
)
const LICENSE = "etalab-2.0"
const LICENSE_URL = "https://www.etalab.gouv.fr/licence-ouverte-open-licence/"
const CITATION = "Département des Côtes-d'Armor, fibre optique de la montée en débit, 2016 node, artery, and optical-cable tables."
const MATCH_TOLERANCE_M = 5.0

function read_source_csv(path)
    bytes = read(path)
    bom = UInt8[0xef, 0xbb, 0xbf]
    while length(bytes) >= 3 && bytes[1:3] == bom
        bytes = bytes[4:end]
    end
    return CSV.read(IOBuffer(bytes), DataFrame; missingstring="", strict=true)
end

function coordinates(geometry)
    object = JSON3.read(String(geometry))
    object.type == "LineString" || error("expected LineString geometry")
    return [(Float64(point[1]), Float64(point[2])) for point in object.coordinates]
end

function point_coordinate(geometry)
    object = JSON3.read(String(geometry))
    object.type == "Point" || error("expected Point geometry")
    return (Float64(object.coordinates[1]), Float64(object.coordinates[2]))
end

function nonempty(value)
    return !ismissing(value) && !isempty(strip(string(value)))
end

function declared_endpoint_ids(value)
    text = strip(string(value))
    parts = split(text, '_')
    length(parts) == 2 && return String.(parts)
    parts = split(text, '-')
    length(parts) == 2 && return String.(parts)
    return String[]
end

options = parse_cli(ARGS; required=["nodes", "arteries", "cables", "output"])
for name in keys(CHECKSUMS)
    path = abspath(options[name])
    bytes2hex(open(sha256, path)) == CHECKSUMS[name] || error("$(name) checksum does not match the pinned response")
end
output = abspath(options["output"])
ispath(output) && error("output already exists: $(output)")
mkpath(output)

source_nodes = read_source_csv(options["nodes"])
source_arteries = read_source_csv(options["arteries"])
source_cables = read_source_csv(options["cables"])
nrow(source_nodes) == 732 || error("expected 732 node rows")
nrow(source_arteries) == 692 || error("expected 692 artery rows")
nrow(source_cables) == 103 || error("expected 103 cable rows")

published_nodes = [begin
    assets = sort!([string(row[column]) for column in (:ID_NOEUD, :ID_CHBRE, :ID_EP, :ID_LT) if nonempty(row[column])])
    (;
        key="published_$(index)",
        coordinate=point_coordinate(row.geometry),
        node_id="node_$(slug(row.ID_NOEUD))",
        name=string(row.ID_NOEUD),
        source_node_id=string(row.ID_NOEUD),
        source_asset_ids=assets,
        source_attributes_json=String(JSON3.write(NamedTuple(row))),
    )
end for (index, row) in enumerate(eachrow(source_nodes))]

asset_to_source_indices = Dict{String,Vector{Int}}()
for (source_index, node) in enumerate(published_nodes), asset_id in node.source_asset_ids
    push!(get!(asset_to_source_indices, asset_id, Int[]), source_index)
end

function resolve_endpoint(coordinate, source_id, endpoint_label, declared_ids, preferred_id,
        node_definitions, repair_notes)
    distances = [haversine_m(coordinate[1], coordinate[2], node.coordinate[1], node.coordinate[2])
        for node in published_nodes]
    source_index = 0
    if !isnothing(preferred_id) && haskey(asset_to_source_indices, preferred_id)
        candidates = asset_to_source_indices[preferred_id]
        local_index = argmin(distances[candidates])
        source_index = candidates[local_index]
        length(candidates) > 1 && push!(repair_notes,
            "endpoint $(endpoint_label): duplicate publisher asset $(preferred_id) resolved by geometry")
    else
        source_index = argmin(distances)
    end
    distance_m = distances[source_index]
    nearest = published_nodes[source_index]
    if distance_m <= MATCH_TOLERANCE_M ||
            (!isnothing(preferred_id) && haskey(asset_to_source_indices, preferred_id))
        declared_matches = any(id -> id in nearest.source_asset_ids, declared_ids)
        (!declared_matches || distance_m > MATCH_TOLERANCE_M) && push!(repair_notes,
            "endpoint $(endpoint_label): geometry matched $(nearest.source_node_id) at $(distance_m) m; declared IDs=$(join(declared_ids, '|'))")
        node_definitions[nearest.key] = (;
            key=nearest.key,
            node_id=nearest.node_id,
            name=nearest.name,
            coordinate=nearest.coordinate,
            coordinate_method="published_point_geometry_match",
            note="Publisher node joined to route geometry within $(MATCH_TOLERANCE_M) m.",
            source_node_id=nearest.source_node_id,
            source_asset_ids=join(nearest.source_asset_ids, ";"),
            source_attributes_json=nearest.source_attributes_json,
        )
        return nearest.key
    end

    key="derived_$(slug(source_id))_$(endpoint_label)"
    node_definitions[key] = (;
        key,
        node_id=key,
        name=isempty(declared_ids) ? "Derived endpoint $(endpoint_label)" : join(declared_ids, " or "),
        coordinate,
        coordinate_method="geometry_endpoint",
        note="No publisher node was within $(MATCH_TOLERANCE_M) m; nearest distance was $(distance_m) m.",
        source_node_id=missing,
        source_asset_ids=join(declared_ids, ";"),
        source_attributes_json=missing,
    )
    push!(repair_notes, "endpoint $(endpoint_label): created geometry endpoint; nearest published node was $(distance_m) m away")
    return key
end

function make_network(distance_policy, source_table, network_id, name, id_column, prefer_declared_ids)
    node_definitions = Dict{String,NamedTuple}()
    candidates = NamedTuple[]
    report_rows = NamedTuple[]
    for (ordinal, row) in enumerate(eachrow(source_table))
        published_id = string(row[id_column])
        source_id = "$(network_id)_$(lpad(ordinal, 4, '0'))"
        route = coordinates(row.geometry)
        length(route) >= 2 || error("$(source_id): geometry has fewer than two points")
        declared_ids = declared_endpoint_ids(published_id)
        repairs = String[]
        preferred_src = prefer_declared_ids && length(declared_ids) == 2 ? declared_ids[1] : nothing
        preferred_dst = prefer_declared_ids && length(declared_ids) == 2 ? declared_ids[2] : nothing
        src_key = resolve_endpoint(route[1], source_id, "a", declared_ids, preferred_src, node_definitions, repairs)
        dst_key = resolve_endpoint(route[end], source_id, "b", declared_ids, preferred_dst, node_definitions, repairs)
        distance_m, method, note = distance_policy(row, route)
        push!(candidates, (;
            src_key,
            dst_key,
            source_id,
            published_id,
            name=published_id,
            distance_m,
            distance_method=method,
            distance_note=note,
            coordinates=route,
            source_attributes_json=String(JSON3.write(NamedTuple(row))),
        ))
        push!(report_rows, (;
            source_reference=source_id,
            network_id,
            status="published",
            detail=isempty(repairs) ? "publisher IDs and geometry agree" : join(repairs, "; "),
        ))
    end

    ordered_nodes = sort!(collect(values(node_definitions)); by=node -> node.node_id)
    vertex_by_key = Dict(node.key => vertex for (vertex, node) in enumerate(ordered_nodes))
    nodes = DataFrame(
        vertex=collect(eachindex(ordered_nodes)),
        node_id=getproperty.(ordered_nodes, :node_id),
        name=getproperty.(ordered_nodes, :name),
        longitude_deg=[node.coordinate[1] for node in ordered_nodes],
        latitude_deg=[node.coordinate[2] for node in ordered_nodes],
        coordinate_method=getproperty.(ordered_nodes, :coordinate_method),
        note=getproperty.(ordered_nodes, :note),
        source_node_id=getproperty.(ordered_nodes, :source_node_id),
        source_asset_ids=getproperty.(ordered_nodes, :source_asset_ids),
        source_attributes_json=getproperty.(ordered_nodes, :source_attributes_json),
    )

    self_loops = 0
    grouped = Dict{Tuple{Int,Int},Vector{NamedTuple}}()
    for candidate in candidates
        src = vertex_by_key[candidate.src_key]
        dst = vertex_by_key[candidate.dst_key]
        if src == dst
            self_loops += 1
            continue
        end
        pair = minmax(src, dst)
        route = src == pair[1] ? candidate.coordinates : reverse(candidate.coordinates)
        push!(get!(grouped, pair, NamedTuple[]), merge(candidate, (; pair, coordinates=route)))
    end
    edge_rows = NamedTuple[]
    for (pair, alternatives) in sort!(collect(grouped); by=first)
        sort!(alternatives; by=edge -> (edge.distance_m, edge.source_id))
        chosen = first(alternatives)
        push!(edge_rows, (;
            edge_id="edge_$(pair[1])_$(pair[2])",
            src_vertex=pair[1],
            dst_vertex=pair[2],
            name=chosen.name,
            distance_m=chosen.distance_m,
            distance_method=chosen.distance_method,
            distance_note=chosen.distance_note,
            contributing_source_edge_count=length(alternatives),
            geometry_wkt=linestring_wkt(chosen.coordinates),
            source_edge_ids=join(sort!(getproperty.(alternatives, :source_id)), ";"),
            published_source_ids=join(sort!(getproperty.(alternatives, :published_id)), ";"),
            source_attributes_json="[" * join(sort!(getproperty.(alternatives, :source_attributes_json)), ",") * "]",
        ))
    end
    edges = DataFrame(edge_rows)
    write_network(output, network_id, nodes, edges)
    return (;
        nodes,
        edges,
        report_rows,
        self_loops_removed=self_loops,
        parallel_edges_combined=length(candidates) - self_loops - nrow(edges),
        distance_method=length(unique(edges.distance_method)) == 1 ? only(unique(edges.distance_method)) : "mixed",
        name,
    )
end

arteries = make_network(source_arteries, "arteries", "Departmental fibre arteries", :ID_ARTERE, false) do row, route
    value = Float64(row.AR_LONG)
    return (value, "reported", "Publisher-reported artery route length; source values and geometry indicate an assumed unit of metres.")
end
cables = make_network(source_cables, "optical_cables", "Departmental optical cables", :ID_CABLE, true) do row, route
    if !ismissing(row.CA_LG_MES) && isfinite(row.CA_LG_MES) && row.CA_LG_MES >= 0
        return (Float64(row.CA_LG_MES), "measured", "Publisher cable measured length; source values and geometry indicate an assumed unit of metres.")
    elseif !ismissing(row.CA_LG_CAL) && isfinite(row.CA_LG_CAL) && row.CA_LG_CAL >= 0
        return (Float64(row.CA_LG_CAL), "source_calculated", "Publisher cable calculated length; source values and geometry indicate an assumed unit of metres.")
    end
    return (polyline_length_m(route), "geodesic_polyline", "Fallback WGS84 polyline distance because no valid publisher length was available.")
end

summary_rows = [
    ("arteries", arteries, nrow(source_arteries)),
    ("optical_cables", cables, nrow(source_cables)),
]
networks = DataFrame([(
    schema_version=1,
    network_id,
    name=result.name,
    description="Côtes-d'Armor 2016 fibre infrastructure joined to publisher node records with audited geometry-based repairs.",
    source_reference=network_id == "arteries" ? "artery and node tables" : "cable and node tables",
    node_count=nrow(result.nodes),
    edge_count=nrow(result.edges),
    component_count=component_count(nrow(result.nodes), result.edges),
    original_directed=false,
    coordinate_method="published_points_and_geometry_endpoints",
    distance_method=result.distance_method,
    license_identifier=LICENSE,
    license_url=LICENSE_URL,
    citation=CITATION,
    attribution="Département des Côtes-d'Armor / Dat'Armor.",
    redistribution_notes="French Open Licence 2.0; source length unit is assumed to be metres and all identifier repairs are audited.",
    source_node_count=nrow(source_nodes),
    source_edge_count,
    self_loops_removed=result.self_loops_removed,
    parallel_edges_combined=result.parallel_edges_combined,
) for (network_id, result, source_edge_count) in summary_rows])
write_artifact_metadata(output, @__DIR__, networks)
CSV.write(joinpath(output, "extraction_report.csv"), DataFrame(vcat(arteries.report_rows, cables.report_rows)); missingstring="")
println("Wrote artery and optical-cable networks to $(output)")
