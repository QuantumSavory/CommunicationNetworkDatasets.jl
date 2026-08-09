using CSV: CSV
using DataFrames: DataFrame, nrow
using JSON3: JSON3
using OpenStreetMapPBF: Node, Way, scan_nodes, scan_ways
using SHA: sha256

include(joinpath(@__DIR__, "..", "common.jl"))
using .ExtractionCommon

const LICENSE = "ODbL-1.0"
const LICENSE_URL = "https://opendatacommons.org/licenses/odbl/1-0/"
const CITATION = "OpenStreetMap contributors."

function canonical_tags_json(tags)
    entries = sort!(collect(tags); by=first)
    body = join((
        String(JSON3.write(key)) * ":" * String(JSON3.write(value))
        for (key, value) in entries
    ), ",")
    return "{" * body * "}"
end

function osm_id(kind, id::Int64)
    return id >= 0 ? "osm_$(kind)_$(id)" : "osm_$(kind)_negative_$(-id)"
end

function is_fibre_way(tags)
    return get(tags, "telecom:medium", "") == "fibre" &&
        (
            get(tags, "communication", "") == "line" ||
            get(tags, "telecom", "") == "cable"
        ) &&
        get(tags, "area", "") != "yes" &&
        !haskey(tags, "building")
end

function extract_pbf(source)
    ways = Way[]
    scan_ways(source) do way
        is_fibre_way(way.tags) && push!(ways, way)
    end
    sort!(ways; by=way -> way.id)
    isempty(ways) && error("no fibre ways matched the documented predicate")
    all(length(way.nodes) >= 2 for way in ways) ||
        error("a selected OSM way contains fewer than two node references")

    referenced_node_ids = Set{Int64}()
    endpoint_node_ids = Set{Int64}()
    way_ids_by_node = Dict{Int64,Set{Int64}}()
    for way in ways
        union!(referenced_node_ids, way.nodes)
        push!(endpoint_node_ids, first(way.nodes), last(way.nodes))
        for node_id in way.nodes
            push!(get!(way_ids_by_node, node_id, Set{Int64}()), way.id)
        end
    end
    shared_node_ids = Set(
        node_id for (node_id, owner_ids) in way_ids_by_node
        if length(owner_ids) > 1
    )
    topology_node_ids = union(endpoint_node_ids, shared_node_ids)

    source_nodes = Dict{Int64,Node}()
    scan_nodes(source) do node
        if node.id in referenced_node_ids
            haskey(source_nodes, node.id) && error("duplicate OSM node $(node.id)")
            source_nodes[node.id] = node
        end
    end
    missing_ids = sort!(collect(setdiff(referenced_node_ids, Set(keys(source_nodes)))))
    isempty(missing_ids) || error(
        "selected ways reference missing OSM nodes: " *
        join(first(missing_ids, min(10, length(missing_ids))), ", "),
    )
    for node_id in referenced_node_ids
        node = source_nodes[node_id]
        valid = isfinite(node.lon) && isfinite(node.lat) &&
            -180 <= node.lon <= 180 && -90 <= node.lat <= 90
        valid || error("OSM node $(node_id) has invalid WGS84 coordinates")
    end

    ordered_node_ids = sort!(collect(topology_node_ids))
    vertex_by_node_id = Dict(
        node_id => vertex for (vertex, node_id) in enumerate(ordered_node_ids)
    )
    nodes = DataFrame(
        vertex=collect(eachindex(ordered_node_ids)),
        node_id=[osm_id("node", node_id) for node_id in ordered_node_ids],
        name=[get(source_nodes[node_id].tags, "name", "") for node_id in ordered_node_ids],
        longitude_deg=[source_nodes[node_id].lon for node_id in ordered_node_ids],
        latitude_deg=[source_nodes[node_id].lat for node_id in ordered_node_ids],
        coordinate_method=fill("openstreetmap_node", length(ordered_node_ids)),
        note=fill(
            "Published OSM node that is a selected-way endpoint or is shared by distinct selected ways.",
            length(ordered_node_ids),
        ),
        source_osm_node_id=ordered_node_ids,
        source_tags_json=[
            canonical_tags_json(source_nodes[node_id].tags) for node_id in ordered_node_ids
        ],
    )

    raw_segments = NamedTuple[]
    for way in ways
        split_positions = findall(in(topology_node_ids), way.nodes)
        for (segment_index, (first_position, last_position)) in enumerate(
            zip(split_positions, @view(split_positions[2:end])),
        )
            node_refs = way.nodes[first_position:last_position]
            coordinates = [
                (source_nodes[node_id].lon, source_nodes[node_id].lat) for node_id in node_refs
            ]
            distance_m = polyline_length_m(coordinates)
            isfinite(distance_m) && distance_m >= 0 || error(
                "OSM way $(way.id), segment $(segment_index): invalid distance",
            )
            push!(raw_segments, (;
                source_segment_id="$(osm_id("way", way.id))_segment_$(lpad(segment_index, 4, '0'))",
                source_way_id=way.id,
                segment_index,
                src_vertex=vertex_by_node_id[first(node_refs)],
                dst_vertex=vertex_by_node_id[last(node_refs)],
                name=get(way.tags, "name", ""),
                distance_m,
                coordinates,
                source_attributes_json=canonical_tags_json(way.tags),
            ))
        end
    end

    self_loops_removed = 0
    grouped = Dict{Tuple{Int,Int},Vector{NamedTuple}}()
    for segment in raw_segments
        if segment.src_vertex == segment.dst_vertex
            self_loops_removed += 1
            continue
        end
        pair = minmax(segment.src_vertex, segment.dst_vertex)
        coordinates = segment.src_vertex == pair[1] ?
            segment.coordinates : reverse(segment.coordinates)
        push!(get!(grouped, pair, NamedTuple[]), merge(segment, (; coordinates)))
    end

    edge_rows = NamedTuple[]
    for (pair, alternatives) in sort!(collect(grouped); by=first)
        sort!(alternatives; by=candidate -> (
            candidate.distance_m,
            candidate.source_way_id,
            candidate.segment_index,
        ))
        chosen = first(alternatives)
        push!(edge_rows, (;
            edge_id="edge_$(pair[1])_$(pair[2])",
            src_vertex=pair[1],
            dst_vertex=pair[2],
            name=chosen.name,
            distance_m=chosen.distance_m,
            distance_method="geodesic_polyline",
            distance_note="Calculated along the selected OSM way geometry.",
            contributing_source_edge_count=length(alternatives),
            geometry_wkt=linestring_wkt(chosen.coordinates),
            source_way_ids=join(sort!(unique(getproperty.(alternatives, :source_way_id))), ";"),
            source_segment_ids=join(sort!(getproperty.(alternatives, :source_segment_id)), ";"),
            selected_source_segment_id=chosen.source_segment_id,
            source_attributes_json="[" * join(sort!(unique(getproperty.(
                alternatives,
                :source_attributes_json,
            ))), ",") * "]",
        ))
    end
    edges = DataFrame(edge_rows)
    parallel_edges_combined = length(raw_segments) - self_loops_removed - nrow(edges)
    return (;
        ways,
        referenced_node_ids,
        raw_segments,
        nodes,
        edges,
        self_loops_removed,
        parallel_edges_combined,
    )
end

options = parse_cli(ARGS; required=["source", "source-reference", "output"])
source = abspath(options["source"])
output = abspath(options["output"])
source_reference = options["source-reference"]
isfile(source) || error("source is not a file: $(source)")
ispath(output) && error("output already exists: $(output)")
mkpath(output)

result = extract_pbf(source)
network_id = "openstreetmap_telecom"
write_network(output, network_id, result.nodes, result.edges)
write_artifact_metadata(output, @__DIR__, DataFrame([(
    schema_version=1,
    network_id,
    name="OpenStreetMap telecommunications fibre",
    description="Fibre topology selected from an explicit OpenStreetMap PBF input.",
    source_reference,
    node_count=nrow(result.nodes),
    edge_count=nrow(result.edges),
    component_count=component_count(nrow(result.nodes), result.edges),
    original_directed=false,
    coordinate_method="openstreetmap_node",
    distance_method="geodesic_polyline",
    license_identifier=LICENSE,
    license_url=LICENSE_URL,
    citation=CITATION,
    attribution="© OpenStreetMap contributors.",
    redistribution_notes="Derived OpenStreetMap database subject to ODbL 1.0; no v1 artifact is published.",
    source_node_count=length(result.referenced_node_ids),
    source_edge_count=length(result.ways),
    self_loops_removed=result.self_loops_removed,
    parallel_edges_combined=result.parallel_edges_combined,
    normalized_segment_count=length(result.raw_segments),
    source_sha256=bytes2hex(open(sha256, source)),
)]))
CSV.write(
    joinpath(output, "extraction_report.csv"),
    DataFrame(
        source_reference=[source_reference],
        network_id=[network_id],
        status=["deferred"],
        detail=["Extractor output validated locally; no version 1 artifact or catalog row is published."],
    );
    missingstring="",
)
println("Wrote the deferred OpenStreetMap network to $(output)")
