using CairoMakie
using JSON3: JSON3
using SHA: sha256

const SOURCE_SHA256 = "9e0729ee253ca7d7a5c4ae9395fb1902264c5377c52e224d13dd85010e2835d9"

function parse_cli(arguments)
    iseven(length(arguments)) || error("expected --option value pairs")
    options = Dict(arguments[index][3:end] => arguments[index + 1] for index in 1:2:length(arguments))
    all(haskey(options, name) for name in ("source", "output")) || error("required: --source and --output")
    return options
end

function exterior_rings(geometry)
    geometry.type == "Polygon" && return [first(geometry.coordinates)]
    geometry.type == "MultiPolygon" && return [first(polygon) for polygon in geometry.coordinates]
    error("unsupported Natural Earth geometry $(geometry.type)")
end

options = parse_cli(ARGS)
source = abspath(options["source"])
output = abspath(options["output"])
bytes2hex(open(sha256, source)) == SOURCE_SHA256 || error("Natural Earth source checksum does not match")
ispath(output) && error("output already exists: $(output)")

collection = JSON3.read(read(source, String))
collection.type == "FeatureCollection" || error("expected a GeoJSON FeatureCollection")

figure = Figure(; size=(256, 256), figure_padding=0, backgroundcolor=RGBf(0.82, 0.90, 0.96))
axis = Axis(
    figure[1, 1];
    aspect=DataAspect(),
    backgroundcolor=RGBf(0.82, 0.90, 0.96),
    xautolimitmargin=(0, 0),
    yautolimitmargin=(0, 0),
)
for feature in collection.features, ring in exterior_rings(feature.geometry)
    points = Point2f[(Float32(point[1]), Float32(point[2])) for point in ring]
    poly!(axis, points; color=RGBf(0.86, 0.84, 0.73), strokecolor=RGBf(0.55, 0.58, 0.52), strokewidth=0.25)
end
limits!(axis, -180, 180, -85.05113, 85.05113)
hidedecorations!(axis)
hidespines!(axis)

tile_root = joinpath(output, "0", "0")
mkpath(tile_root)
save(joinpath(tile_root, "0.png"), figure; px_per_unit=1)
cp(joinpath(@__DIR__, "README.md"), joinpath(output, "README.md"))
cp(joinpath(@__DIR__, "LICENSE.md"), joinpath(output, "LICENSE.md"))
println("Wrote Natural Earth z0 basemap tile to $(output)")
