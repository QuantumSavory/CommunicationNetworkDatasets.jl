using CSV: CSV
using CodecZlib: GzipDecompressorStream
using DataFrames: DataFrame, nrow
using EzXML: EzXML, nodecontent, readxml, root
using JSON3: JSON3
using SHA: sha256
using Tar: Tar

include(joinpath(@__DIR__, "..", "common.jl"))
using .ExtractionCommon

const ARCHIVE_SHA256 = "7fba0617df71911a30df116478d1fc75758963c7b2569dd81818f47cf5b814c1"
const SOURCE_URL = "https://ndownloader.figshare.com/files/58057750"
const LICENSE = "CC-BY-4.0"
const LICENSE_URL = "https://creativecommons.org/licenses/by/4.0/"
const CITATION = "Knight et al., The Internet Topology Zoo, IEEE Journal on Selected Areas in Communications 29(9), 2011; licensed Figshare deposit 30153949.v1."
const NO_NAMESPACES = Pair{String,String}[]

function element_attributes(element, key_names)
    attributes = Dict{String,String}()
    for data in findall("./*[local-name()='data']", element, NO_NAMESPACES)
        key = get(key_names, data["key"], data["key"])
        attributes[key] = strip(nodecontent(data))
    end
    return attributes
end

function attributes_json(attributes)
    pairs = sort!(collect(attributes); by=first)
    ordered = (; (Symbol(key) => value for (key, value) in pairs)...)
    return String(JSON3.write(ordered))
end

function parse_coordinate(attributes, key)
    haskey(attributes, key) || return nothing
    value = tryparse(Float64, attributes[key])
    return isnothing(value) || !isfinite(value) ? nothing : value
end

function extract_graphml(path, output, network_id)
    document = readxml(path)
    graphml = root(document)
    key_names = Dict(
        key["id"] => (haskey(key, "attr.name") ? key["attr.name"] : key["id"])
        for key in findall("./*[local-name()='key']", graphml, NO_NAMESPACES)
    )
    graph = only(findall("./*[local-name()='graph']", graphml, NO_NAMESPACES))
    graph_attributes = element_attributes(graph, key_names)
    node_elements = findall("./*[local-name()='node']", graph, NO_NAMESPACES)
    edge_elements = findall("./*[local-name()='edge']", graph, NO_NAMESPACES)

    parsed_nodes = [begin
        attributes = element_attributes(node, key_names)
        (;
            source_id=node["id"],
            attributes,
            longitude=parse_coordinate(attributes, "Longitude"),
            latitude=parse_coordinate(attributes, "Latitude"),
        )
    end for node in node_elements]
    invalid_nodes = [node.source_id for node in parsed_nodes if
        isnothing(node.longitude) || isnothing(node.latitude) ||
        !(-180 <= node.longitude <= 180) || !(-90 <= node.latitude <= 90)]
    isempty(invalid_nodes) || return (;
        status="excluded",
        detail="$(length(invalid_nodes)) of $(length(parsed_nodes)) nodes lack valid WGS84 coordinates",
        summary=nothing,
    )

    sort!(parsed_nodes; by=node -> stable_source_id(node.source_id))
    vertex_by_source_id = Dict(node.source_id => index for (index, node) in enumerate(parsed_nodes))
    nodes = DataFrame(
        vertex=collect(eachindex(parsed_nodes)),
        node_id=["node_$(slug(node.source_id))" for node in parsed_nodes],
        name=[get(node.attributes, "label", node.source_id) for node in parsed_nodes],
        longitude_deg=[node.longitude for node in parsed_nodes],
        latitude_deg=[node.latitude for node in parsed_nodes],
        coordinate_method=fill("upstream_geocoded_or_published", length(parsed_nodes)),
        note=fill("Topology Zoo coordinates often identify geocoded places and are not verified equipment sites.", length(parsed_nodes)),
        source_node_id=[node.source_id for node in parsed_nodes],
        source_attributes_json=[attributes_json(node.attributes) for node in parsed_nodes],
    )

    candidates = NamedTuple[]
    self_loops = 0
    for (index, edge) in enumerate(edge_elements)
        source = edge["source"]
        destination = edge["target"]
        src = vertex_by_source_id[source]
        dst = vertex_by_source_id[destination]
        if src == dst
            self_loops += 1
            continue
        end
        attributes = element_attributes(edge, key_names)
        source_edge_id = haskey(edge, "id") ? edge["id"] : "edge_$(lpad(index, 6, '0'))"
        pair = minmax(src, dst)
        source_node = parsed_nodes[src]
        destination_node = parsed_nodes[dst]
        distance_m = haversine_m(
            source_node.longitude,
            source_node.latitude,
            destination_node.longitude,
            destination_node.latitude,
        )
        push!(candidates, (;
            pair,
            source_edge_id,
            distance_m,
            name=get(attributes, "LinkLabel", ""),
            attributes_json=attributes_json(attributes),
        ))
    end

    grouped = Dict{Tuple{Int,Int},Vector{NamedTuple}}()
    for candidate in candidates
        push!(get!(grouped, candidate.pair, NamedTuple[]), candidate)
    end
    edge_rows = NamedTuple[]
    for (pair, alternatives) in sort!(collect(grouped); by=first)
        sort!(alternatives; by=candidate -> (candidate.distance_m, candidate.source_edge_id))
        chosen = first(alternatives)
        push!(edge_rows, (;
            edge_id="edge_$(pair[1])_$(pair[2])",
            src_vertex=pair[1],
            dst_vertex=pair[2],
            name=chosen.name,
            distance_m=chosen.distance_m,
            distance_method="geodesic_endpoints",
            distance_note="Calculated as WGS84 great-circle endpoint distance; this is a lower bound, not source route length.",
            contributing_source_edge_count=length(alternatives),
            geometry_wkt=missing,
            source_edge_ids=join(sort!(getproperty.(alternatives, :source_edge_id)), ";"),
            source_attributes_json="[" * join(sort!(getproperty.(alternatives, :attributes_json)), ",") * "]",
        ))
    end
    edges = DataFrame(edge_rows)
    write_network(output, network_id, nodes, edges)

    source_name = get(graph_attributes, "Network", get(graph_attributes, "label", splitext(basename(path))[1]))
    original_directed = lowercase(graph["edgedefault"]) == "directed"
    summary = (;
        schema_version=1,
        network_id,
        name=source_name,
        description="Coordinate-complete network from the licensed Internet Topology Zoo deposit.",
        source_reference=basename(path),
        node_count=nrow(nodes),
        edge_count=nrow(edges),
        component_count=component_count(nrow(nodes), edges),
        original_directed,
        coordinate_method="upstream_geocoded_or_published",
        distance_method="geodesic_endpoints",
        license_identifier=LICENSE,
        license_url=LICENSE_URL,
        citation=CITATION,
        attribution="Internet Topology Zoo authors and the original map sources recorded in source_attributes_json.",
        redistribution_notes="CC BY 4.0; coordinates may be geocoded place locations.",
        source_node_count=length(node_elements),
        source_edge_count=length(edge_elements),
        self_loops_removed=self_loops,
        parallel_edges_combined=length(candidates) - nrow(edges),
        source_attributes_json=attributes_json(graph_attributes),
    )
    return (; status="published", detail="", summary)
end

options = parse_cli(ARGS; required=["archive", "output"])
archive = abspath(options["archive"])
output = abspath(options["output"])
bytes2hex(open(sha256, archive)) == ARCHIVE_SHA256 || error(
    "Internet Topology Zoo archive checksum does not match the pinned Figshare snapshot",
)
ispath(output) && error("output already exists: $(output)")
mkpath(output)

summary_rows = NamedTuple[]
report_rows = NamedTuple[]
mktempdir() do directory
    open(archive) do compressed
        stream = GzipDecompressorStream(compressed)
        try
            Tar.extract(stream, directory)
        finally
            close(stream)
        end
    end
    files = sort(filter(path -> endswith(path, ".graphml"), readdir(joinpath(directory, "graphml"); join=true)))
    ids = unique_slugs([first(splitext(basename(path))) for path in files])
    for (path, network_id) in zip(files, ids)
        result = extract_graphml(path, output, network_id)
        push!(report_rows, (;
            source_reference=basename(path),
            network_id=result.status == "published" ? network_id : missing,
            status=result.status,
            detail=result.detail,
        ))
        result.status == "published" && push!(summary_rows, result.summary)
    end
end

length(summary_rows) == 85 || error("expected 85 coordinate-complete networks; found $(length(summary_rows))")
write_artifact_metadata(output, @__DIR__, DataFrame(summary_rows))
CSV.write(joinpath(output, "extraction_report.csv"), DataFrame(report_rows); missingstring="")
println("Wrote $(length(summary_rows)) networks and $(count(row -> row.status == "excluded", report_rows)) exclusions to $(output)")
