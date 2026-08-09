using CSV: CSV
using DataFrames: DataFrame, nrow, sort!
using EzXML: EzXML, nodecontent, readxml, root
using JSON3: JSON3
using Printf: @sprintf
using Proj: Proj
using SHA: sha256

include(joinpath(@__DIR__, "..", "common.jl"))
using .ExtractionCommon

const SOURCE_FILE = "UtilityandGovernmentalServices.gml"
const SOURCE_URL = "https://service.pdok.nl/hwh/waterschappen-nutsdiensten-en-overheidsdiensten/atom/downloads/UtilityandGovernmentalServices.gml"
const SOURCE_SHA256 = "bf5b19ed41d4da9b8538574a26e5084e192767c5cb9beaf53f41cb783f58577d"
const SOURCE_BYTES = 97_014_053
const SOURCE_DATE = "2026-08-06"
const SOURCE_CRS = "urn:ogc:def:crs:EPSG::4258"
const GML_NAMESPACE = "http://www.opengis.net/gml/3.2"
const TELECOM_NAMESPACE = "http://inspire.ec.europa.eu/schemas/us-net-tc/4.0"
const COMMON_NAMESPACE = "http://inspire.ec.europa.eu/schemas/us-net-common/4.0"
const NO_NAMESPACES = Pair{String,String}[]
const ATTACHMENT_TOLERANCE_M = 1.0e-6
const LICENSE = "NOASSERTION"
const CITATION = "Het Waterschapshuis, Waterschappen Nuts-Overheidsdiensten (INSPIRE geharmoniseerd), PDOK snapshot 2026-08-06."

const EXPECTED_FEATURE_COUNTS = Dict(
    "EnvironmentalManagementFacility" => 318,
    "Duct" => 3_660,
    "Manhole" => 7_535,
    "ElectricityCable" => 2_038,
    "SewerPipe" => 27_364,
    "TelecommunicationsCable" => 2_079,
)

const CONFIGURATIONS = [
    (;
        feature_type="TelecommunicationsCable",
        namespace=TELECOM_NAMESPACE,
        network_id="telecommunications_cables",
        name="Water-authority telecommunications cables",
        description="Telecommunications-cable geometries published by Dutch water authorities; cable material is unspecified and optical fibre is not implied.",
        part_count=2_161,
        multipart_count=34,
        attached_manhole_count=4,
        repaired_manhole_ids=Set{String}(),
        node_count=3_045,
        segment_count=2_430,
        edge_count=1_966,
        component_count=1_110,
        self_loops_removed=270,
        parallel_edges_combined=194,
    ),
    (;
        feature_type="Duct",
        namespace=COMMON_NAMESPACE,
        network_id="ducts",
        name="Water-authority utility ducts",
        description="Utility-duct geometries published by Dutch water authorities; their telecommunications use and optical-fibre contents are not confirmed.",
        part_count=3_734,
        multipart_count=63,
        attached_manhole_count=35,
        repaired_manhole_ids=Set([
            "NL.WBHCODE.25.Put.200514",
            "NL.WBHCODE.25.Put.200251",
            "NL.WBHCODE.15.Put.201081",
        ]),
        node_count=7_378,
        segment_count=3_771,
        edge_count=3_753,
        component_count=3_626,
        self_loops_removed=6,
        parallel_edges_combined=12,
    ),
]

Proj.enable_network!(false)
const TO_RD = Proj.Transformation("EPSG:4258", "EPSG:28992"; always_xy=true)
const TO_WGS84 = Proj.Transformation("EPSG:4258", "EPSG:4326"; always_xy=true)

function only_node(element, xpath, context)
    nodes = findall(xpath, element, NO_NAMESPACES)
    length(nodes) == 1 || error("$(context): expected one XML node for $(xpath), found $(length(nodes))")
    return only(nodes)
end

function required_text(element, xpath, context)
    value = strip(nodecontent(only_node(element, xpath, context)))
    isempty(value) && error("$(context): empty XML value for $(xpath)")
    return value
end

function optional_text(element, xpath)
    nodes = findall(xpath, element, NO_NAMESPACES)
    isempty(nodes) && return ""
    length(nodes) == 1 || error("expected at most one XML node for $(xpath), found $(length(nodes))")
    return strip(nodecontent(only(nodes)))
end

function feature_identity(feature, feature_type)
    context = "$(feature_type) feature"
    local_id = required_text(feature, ".//*[local-name()='inspireId']/*[local-name()='Identifier']/*[local-name()='localId']", context)
    source_namespace = required_text(feature, ".//*[local-name()='inspireId']/*[local-name()='Identifier']/*[local-name()='namespace']", context)
    feature_id = "$(source_namespace).$(local_id)"
    gml_id = required_text(feature, "./@*[local-name()='id' and namespace-uri()='$(GML_NAMESPACE)']", context)
    gml_id == feature_id || error("$(context): gml:id $(gml_id) does not match INSPIRE identifier $(feature_id)")
    return (; feature_id, local_id, source_namespace)
end

function current_status(feature)
    return optional_text(
        feature,
        ".//*[local-name()='currentStatus']/@*[local-name()='href']",
    )
end

function transform_coordinate(latitude, longitude, context)
    all(isfinite, (latitude, longitude)) || error("$(context): non-finite source coordinate")
    -90 <= latitude <= 90 || error("$(context): latitude $(latitude) is outside WGS84 bounds")
    -180 <= longitude <= 180 || error("$(context): longitude $(longitude) is outside WGS84 bounds")
    projected = Tuple(Float64.(TO_RD(longitude, latitude)))
    wgs84 = Tuple(Float64.(TO_WGS84(longitude, latitude)))
    all(isfinite, projected) || error("$(context): non-finite EPSG:28992 coordinate")
    all(isfinite, wgs84) || error("$(context): non-finite EPSG:4326 coordinate")
    -180 <= wgs84[1] <= 180 && -90 <= wgs84[2] <= 90 ||
        error("$(context): transformed WGS84 coordinate $(wgs84) is outside valid bounds")
    return (; projected, wgs84)
end

function parse_coordinate_values(element, context)
    dimension = parse(Int, required_text(element, "./@*[local-name()='srsDimension']", context))
    dimension == 3 || error("$(context): expected srsDimension=3, found $(dimension)")
    values = parse.(Float64, split(strip(nodecontent(element))))
    length(values) % dimension == 0 || error("$(context): coordinate count is not divisible by $(dimension)")
    return [begin
        latitude, longitude, height = values[index:(index + 2)]
        transformed = transform_coordinate(latitude, longitude, context)
        (; transformed..., height)
    end for index in 1:dimension:length(values)]
end

function geometry_crs(feature, geometry_name, context)
    geometry = only_node(feature, ".//*[local-name()='$(geometry_name)']", context)
    EzXML.namespace(geometry) == GML_NAMESPACE || error("$(context): unexpected $(geometry_name) namespace")
    crs = required_text(geometry, "./@*[local-name()='srsName']", context)
    crs == SOURCE_CRS || error("$(context): expected $(SOURCE_CRS), found $(crs)")
    return geometry
end

function register_projection!(projected_by_wgs84, coordinate, projected, context)
    if haskey(projected_by_wgs84, coordinate)
        previous = projected_by_wgs84[coordinate]
        hypot(previous[1] - projected[1], previous[2] - projected[2]) <= ATTACHMENT_TOLERANCE_M ||
            error("$(context): one WGS84 coordinate maps to inconsistent projected coordinates")
    else
        projected_by_wgs84[coordinate] = projected
    end
    return nothing
end

function parse_line_feature(feature, configuration, projected_by_wgs84)
    EzXML.namespace(feature) == configuration.namespace ||
        error("$(configuration.feature_type): unexpected feature namespace $(EzXML.namespace(feature))")
    identity = feature_identity(feature, configuration.feature_type)
    geometry = geometry_crs(feature, "MultiCurve", identity.feature_id)
    position_lists = findall(".//*[local-name()='posList']", geometry, NO_NAMESPACES)
    isempty(position_lists) && error("$(identity.feature_id): source feature has no line parts")
    status = current_status(feature)
    material = optional_text(feature, ".//*[local-name()='telecommunicationsCableMaterialType']")
    duct_width = optional_text(feature, ".//*[local-name()='ductWidth']")

    records = NamedTuple[]
    for (part_index, position_list) in enumerate(position_lists)
        EzXML.namespace(position_list) == GML_NAMESPACE ||
            error("$(identity.feature_id): unexpected posList namespace")
        parsed = parse_coordinate_values(position_list, "$(identity.feature_id) part $(part_index)")
        length(parsed) >= 2 || error("$(identity.feature_id) part $(part_index): fewer than two coordinates")
        coordinates = getproperty.(parsed, :wgs84)
        projected_coordinates = getproperty.(parsed, :projected)
        for (coordinate, projected) in zip(coordinates, projected_coordinates)
            register_projection!(projected_by_wgs84, coordinate, projected, identity.feature_id)
        end
        source_id = "$(identity.feature_id)#part_$(lpad(part_index, 4, '0'))"
        attributes = (;
            source_feature_id=identity.feature_id,
            source_namespace=identity.source_namespace,
            source_local_id=identity.local_id,
            source_feature_type=configuration.feature_type,
            source_part_index=part_index,
            source_crs=SOURCE_CRS,
            current_status=status,
            telecommunications_cable_material_type=material,
            duct_width=duct_width,
            source_height_min=minimum(getproperty.(parsed, :height)),
            source_height_max=maximum(getproperty.(parsed, :height)),
            source_geometry_epsg28992_wkt=linestring_wkt(projected_coordinates),
        )
        push!(records, (;
            source_id,
            feature_id=identity.feature_id,
            name="",
            coordinates,
            projected_coordinates,
            source_attributes_json=String(JSON3.write(attributes)),
        ))
    end
    return (; records, identity.feature_id)
end

function parse_manhole(feature)
    EzXML.namespace(feature) == COMMON_NAMESPACE ||
        error("Manhole: unexpected feature namespace $(EzXML.namespace(feature))")
    identity = feature_identity(feature, "Manhole")
    geometry = geometry_crs(feature, "Point", identity.feature_id)
    position = only_node(geometry, ".//*[local-name()='pos']", identity.feature_id)
    parsed = only(parse_coordinate_values(position, identity.feature_id))
    return (;
        identity...,
        name=optional_text(feature, ".//*[local-name()='name']"),
        current_status=current_status(feature),
        coordinate=parsed.wgs84,
        projected=parsed.projected,
        source_height=parsed.height,
    )
end

function parse_source(path)
    document = readxml(path)
    collection = root(document)
    EzXML.nodename(collection) == "FeatureCollection" || error("source root is not a FeatureCollection")
    features = findall("./*[local-name()='member']/*", collection, NO_NAMESPACES)
    counts = Dict{String,Int}()
    for feature in features
        feature_type = EzXML.nodename(feature)
        counts[feature_type] = get(counts, feature_type, 0) + 1
    end
    counts == EXPECTED_FEATURE_COUNTS || error("source feature counts changed: $(sort!(collect(counts)))")

    projected_by_wgs84 = Dict{Tuple{Float64,Float64},Tuple{Float64,Float64}}()
    records_by_type = Dict(configuration.feature_type => NamedTuple[] for configuration in CONFIGURATIONS)
    feature_ids_by_type = Dict(configuration.feature_type => String[] for configuration in CONFIGURATIONS)
    part_counts_by_feature = Dict(configuration.feature_type => Int[] for configuration in CONFIGURATIONS)
    manholes = NamedTuple[]

    for feature in features
        feature_type = EzXML.nodename(feature)
        configuration_index = findfirst(configuration -> configuration.feature_type == feature_type, CONFIGURATIONS)
        if !isnothing(configuration_index)
            configuration = CONFIGURATIONS[configuration_index]
            parsed = parse_line_feature(feature, configuration, projected_by_wgs84)
            append!(records_by_type[feature_type], parsed.records)
            push!(feature_ids_by_type[feature_type], parsed.feature_id)
            push!(part_counts_by_feature[feature_type], length(parsed.records))
        elseif feature_type == "Manhole"
            push!(manholes, parse_manhole(feature))
        end
    end

    for configuration in CONFIGURATIONS
        ids = feature_ids_by_type[configuration.feature_type]
        length(unique(ids)) == length(ids) || error("$(configuration.feature_type): duplicate source IDs")
        length(records_by_type[configuration.feature_type]) == configuration.part_count ||
            error("$(configuration.feature_type): geometry-part count changed")
        count(>(1), part_counts_by_feature[configuration.feature_type]) == configuration.multipart_count ||
            error("$(configuration.feature_type): multipart-feature count changed")
    end
    length(unique(getproperty.(manholes, :feature_id))) == length(manholes) || error("duplicate manhole IDs")
    length(manholes) - length(unique(getproperty.(manholes, :coordinate))) == 117 ||
        error("manhole duplicate-coordinate count changed")
    return (; records_by_type, manholes, projected_by_wgs84)
end

bucket_key(point) = (floor(Int, point[1] / ATTACHMENT_TOLERANCE_M), floor(Int, point[2] / ATTACHMENT_TOLERANCE_M))

function match_manholes(configuration, records, manholes)
    projected_by_coordinate = Dict{Tuple{Float64,Float64},Tuple{Float64,Float64}}()
    feature_ids_by_coordinate = Dict{Tuple{Float64,Float64},Set{String}}()
    for record in records
        for (coordinate, projected) in zip(record.coordinates, record.projected_coordinates)
            projected_by_coordinate[coordinate] = projected
            push!(get!(feature_ids_by_coordinate, coordinate, Set{String}()), record.feature_id)
        end
    end
    buckets = Dict{Tuple{Int,Int},Set{Tuple{Float64,Float64}}}()
    for (coordinate, projected) in projected_by_coordinate
        push!(get!(buckets, bucket_key(projected), Set{Tuple{Float64,Float64}}()), coordinate)
    end

    attached = Dict{Tuple{Float64,Float64},Vector{NamedTuple}}()
    report = NamedTuple[]
    repaired_ids = Set{String}()
    for manhole in sort!(copy(manholes); by=manhole -> manhole.feature_id)
        key = bucket_key(manhole.projected)
        candidates = Set{Tuple{Float64,Float64}}()
        for delta_x in -1:1, delta_y in -1:1
            union!(candidates, get(buckets, (key[1] + delta_x, key[2] + delta_y), Set{Tuple{Float64,Float64}}()))
        end
        matches = [begin
            projected = projected_by_coordinate[coordinate]
            distance_m = hypot(projected[1] - manhole.projected[1], projected[2] - manhole.projected[2])
            (; coordinate, distance_m)
        end for coordinate in candidates if begin
            projected = projected_by_coordinate[coordinate]
            hypot(projected[1] - manhole.projected[1], projected[2] - manhole.projected[2]) <= ATTACHMENT_TOLERANCE_M
        end]
        sort!(matches; by=match -> (match.distance_m, match.coordinate))

        if isempty(matches)
            push!(report, (;
                network_id=configuration.network_id,
                source_manhole_id=manhole.feature_id,
                status="excluded_unattached",
                match_distance_m=missing,
                matched_source_feature_ids=missing,
                detail="No relevant route vertex is equal within $(ATTACHMENT_TOLERANCE_M) metre.",
            ))
            continue
        end
        if length(matches) > 1 && isapprox(matches[1].distance_m, matches[2].distance_m; atol=eps(Float64), rtol=0)
            error("$(configuration.network_id): manhole $(manhole.feature_id) has multiple equally near route vertices")
        end
        match = first(matches)
        push!(get!(attached, match.coordinate, NamedTuple[]), manhole)
        repaired = match.distance_m > 0
        repaired && push!(repaired_ids, manhole.feature_id)
        push!(report, (;
            network_id=configuration.network_id,
            source_manhole_id=manhole.feature_id,
            status=repaired ? "included_numerical_repair" : "included",
            match_distance_m=match.distance_m,
            matched_source_feature_ids=join(sort!(collect(feature_ids_by_coordinate[match.coordinate])), ";"),
            detail=repaired ? "Matched to the numerically equal route vertex; no physical snapping." : "Exact route-vertex coordinate match.",
        ))
    end

    sum(length, values(attached)) == configuration.attached_manhole_count ||
        error("$(configuration.network_id): attached-manhole count changed")
    repaired_ids == configuration.repaired_manhole_ids ||
        error("$(configuration.network_id): numerical manhole repairs changed: $(sort!(collect(repaired_ids)))")
    return (; attached, report)
end

function projected_length(projected_by_wgs84, segment)
    return sum(begin
        projected_a = projected_by_wgs84[point_a]
        projected_b = projected_by_wgs84[point_b]
        hypot(projected_b[1] - projected_a[1], projected_b[2] - projected_a[2])
    end for (point_a, point_b) in zip(segment, @view(segment[2:end])))
end

function projected_by_wkt_point(projected_by_wgs84)
    result = Dict{String,Tuple{Float64,Float64}}()
    for (coordinate, projected) in projected_by_wgs84
        key = "$(@sprintf("%.12g", coordinate[1])) $(@sprintf("%.12g", coordinate[2]))"
        if haskey(result, key)
            previous = result[key]
            hypot(previous[1] - projected[1], previous[2] - projected[2]) <= ATTACHMENT_TOLERANCE_M ||
                error("generated WKT rounds distinct projected vertices to $(key)")
        else
            result[key] = projected
        end
    end
    return result
end

function project_wkt(wkt, projected_by_point)
    startswith(wkt, "LINESTRING (") && endswith(wkt, ")") || error("unexpected generated WKT: $(wkt)")
    body = wkt[(length("LINESTRING (") + 1):(end - 1)]
    coordinates = [get(projected_by_point, strip(point)) do
        error("generated WKT point has no source projection: $(point)")
    end for point in split(body, ',')]
    return linestring_wkt(coordinates)
end

function build_network(configuration, records, manholes, projected_by_wgs84, output)
    matching = match_manholes(configuration, records, manholes)
    result = normalize_line_records(
        records;
        coordinate_method="source_epsg4258_transformed_or_geometry_derived",
        node_note="Node transformed from an attached source manhole or derived from a source geometry endpoint/shared vertex.",
        distance_method="projected_geometry",
        distance_note="Calculated along the source route after projection from EPSG:4258 to EPSG:28992; metres.",
        forced_node_coordinates=Set(keys(matching.attached)),
        distance=(_, segment) -> projected_length(projected_by_wgs84, segment),
    )

    nodes = result.nodes
    attached_by_row = [sort!(
        get(matching.attached, (row.longitude_deg, row.latitude_deg), NamedTuple[]);
        by=manhole -> manhole.feature_id,
    ) for row in eachrow(nodes)]
    nodes.name = [begin
        names = filter(!isempty, getproperty.(attached, :name))
        isempty(names) ? "" : first(names)
    end for attached in attached_by_row]
    nodes.coordinate_method = [isempty(attached) ?
        "geometry_vertex_transformed" : "source_manhole_matched_to_geometry_vertex_transformed"
        for attached in attached_by_row]
    nodes.note = [isempty(attached) ?
        "Node derived from a source geometry endpoint or shared vertex and transformed to WGS84." :
        "Attached source manhole matched to a route vertex within 1e-6 metre in EPSG:28992; the route vertex supplies the published coordinate."
        for attached in attached_by_row]
    nodes.source_manhole_ids = [join(getproperty.(attached, :feature_id), ";") for attached in attached_by_row]
    nodes.source_manhole_names = [join(sort!(unique(filter(!isempty, getproperty.(attached, :name)))), ";")
        for attached in attached_by_row]
    nodes.source_crs = fill(SOURCE_CRS, nrow(nodes))

    edges = result.edges
    projection_lookup = projected_by_wkt_point(projected_by_wgs84)
    edges.geometry_epsg28992_wkt = [project_wkt(wkt, projection_lookup) for wkt in edges.geometry_wkt]
    edges.source_crs = fill(SOURCE_CRS, nrow(edges))
    edges.distance_crs = fill("EPSG:28992", nrow(edges))

    nrow(nodes) == configuration.node_count || error("$(configuration.network_id): node count changed")
    result.segment_count == configuration.segment_count || error("$(configuration.network_id): segment count changed")
    nrow(edges) == configuration.edge_count || error("$(configuration.network_id): edge count changed")
    component_count(nrow(nodes), edges) == configuration.component_count || error("$(configuration.network_id): component count changed")
    result.self_loops_removed == configuration.self_loops_removed || error("$(configuration.network_id): self-loop count changed")
    result.parallel_edges_combined == configuration.parallel_edges_combined || error("$(configuration.network_id): parallel-edge count changed")

    write_network(output, configuration.network_id, nodes, edges)
    summary = (;
        schema_version=1,
        network_id=configuration.network_id,
        name=configuration.name,
        description=configuration.description,
        source_reference="$(SOURCE_FILE)#$(configuration.feature_type)",
        node_count=nrow(nodes),
        edge_count=nrow(edges),
        component_count=configuration.component_count,
        original_directed=false,
        coordinate_method="source_epsg4258_transformed_or_geometry_derived",
        distance_method="projected_geometry",
        license_identifier=LICENSE,
        license_url="",
        citation=CITATION,
        attribution="Het Waterschapshuis and the contributing Dutch water authorities; delivered through PDOK.",
        redistribution_notes="Deferred. No artifact is distributed because the declared and underlying rights are inconsistent and include no-derivatives restrictions.",
        source_node_count=configuration.attached_manhole_count,
        source_edge_count=EXPECTED_FEATURE_COUNTS[configuration.feature_type],
        self_loops_removed=result.self_loops_removed,
        parallel_edges_combined=result.parallel_edges_combined,
        source_manhole_count=length(manholes),
        attached_manhole_count=configuration.attached_manhole_count,
        source_geometry_part_count=configuration.part_count,
        numerical_attachment_repairs=length(configuration.repaired_manhole_ids),
        source_crs=SOURCE_CRS,
        distance_crs="EPSG:28992",
        source_sha256=SOURCE_SHA256,
    )
    return (; summary, report=matching.report)
end

options = parse_cli(ARGS; required=["gml", "output"])
gml = abspath(options["gml"])
output = abspath(options["output"])
isfile(gml) || error("source GML does not exist: $(gml)")
filesize(gml) == SOURCE_BYTES || error("source GML size does not match the pinned snapshot")
bytes2hex(open(sha256, gml)) == SOURCE_SHA256 || error("source GML checksum does not match the pinned snapshot")
ispath(output) && error("output already exists: $(output)")
mkpath(output)

source = parse_source(gml)
summaries = NamedTuple[]
report = NamedTuple[]
for configuration in CONFIGURATIONS
    built = build_network(
        configuration,
        source.records_by_type[configuration.feature_type],
        source.manholes,
        source.projected_by_wgs84,
        output,
    )
    push!(summaries, built.summary)
    append!(report, built.report)
end
write_artifact_metadata(output, @__DIR__, DataFrame(summaries))
sort!(report; by=row -> (row.network_id, row.source_manhole_id))
CSV.write(joinpath(output, "extraction_report.csv"), DataFrame(report); missingstring="")
println("Wrote two local audit networks and $(length(report)) manhole decisions to $(output). No artifact may be published.")
