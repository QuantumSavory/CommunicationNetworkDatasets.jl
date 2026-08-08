using CSV: CSV
using DataFrames: DataFrame, nrow
using JSON3: JSON3
using SHA: sha256

include(joinpath(@__DIR__, "..", "common.jl"))
using .ExtractionCommon

const SOURCE_SHA256 = "11fd3773ef36ed41c2075aa752b506b79d2704bebfc3f79863ac0afaa69ccfdd"
const LICENSE = "etalab-2.0"
const LICENSE_URL = "https://www.etalab.gouv.fr/licence-ouverte-open-licence/"
const CITATION = "Métropole de Lyon, Réseau d'initiative publique – La Fibre Grand Lyon, WFS layer tel_telecom.fibre_rip_thd."

options = parse_cli(ARGS; required=["source", "output"])
source = abspath(options["source"])
output = abspath(options["output"])
bytes2hex(open(sha256, source)) == SOURCE_SHA256 || error("source checksum does not match the pinned WFS response")
ispath(output) && error("output already exists: $(output)")
mkpath(output)

collection = JSON3.read(read(source, String))
length(collection.features) == 11_386 || error("expected 11,386 source features; found $(length(collection.features))")
features = sort(collect(collection.features); by=feature -> Int(feature.properties.gid))
records = NamedTuple[]
for feature in features
    feature.geometry.type == "MultiLineString" || error("gid $(feature.properties.gid): expected MultiLineString")
    for (part_index, part) in enumerate(feature.geometry.coordinates)
        push!(records, (;
            source_id="gid_$(feature.properties.gid)_part_$(part_index)",
            name="",
            coordinates=[(Float64(point[1]), Float64(point[2])) for point in part],
            source_attributes_json=String(JSON3.write(feature.properties)),
        ))
    end
end

normalized = normalize_line_records(
    records;
    coordinate_method="source_geometry_vertex",
    node_note="Node derived from a route endpoint or exact shared geometry vertex; visual crossings and nearby routes are not connected.",
    distance_method="geodesic_polyline",
    distance_note="Calculated along the WGS84 WFS route geometry.",
)
network_id = "grand_lyon_rip"
write_network(output, network_id, normalized.nodes, normalized.edges)
networks = DataFrame([(
    schema_version=1,
    network_id,
    name="La Fibre Grand Lyon public-initiative network",
    description="Metropolitan public-initiative fibre route topology derived from the published WFS layer.",
    source_reference="tel_telecom.fibre_rip_thd",
    node_count=nrow(normalized.nodes),
    edge_count=nrow(normalized.edges),
    component_count=component_count(nrow(normalized.nodes), normalized.edges),
    original_directed=false,
    coordinate_method="source_geometry_vertex",
    distance_method="geodesic_polyline",
    license_identifier=LICENSE,
    license_url=LICENSE_URL,
    citation=CITATION,
    attribution="Métropole de Lyon.",
    redistribution_notes="French Open Licence 2.0; graph topology and distances are derived from route geometry.",
    source_node_count=0,
    source_edge_count=length(features),
    self_loops_removed=normalized.self_loops_removed,
    parallel_edges_combined=normalized.parallel_edges_combined,
    normalized_segment_count=normalized.segment_count,
)])
write_artifact_metadata(output, @__DIR__, networks)
CSV.write(
    joinpath(output, "extraction_report.csv"),
    DataFrame(source_reference=["gid $(feature.properties.gid)" for feature in features],
        network_id=fill(network_id, length(features)), status=fill("published", length(features)),
        detail=["$(length(feature.geometry.coordinates)) geometry part(s)" for feature in features]);
    missingstring="",
)
println("Wrote one network from 11,386 Grand Lyon source features to $(output)")
