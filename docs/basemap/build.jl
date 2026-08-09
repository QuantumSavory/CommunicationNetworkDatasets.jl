using CairoMakie

include("NaturalEarthBasemap.jl")

function parse_cli(arguments)
    iseven(length(arguments)) || error("expected --option value pairs")
    options = Dict(arguments[index][3:end] => arguments[index + 1] for index in 1:2:length(arguments))
    all(haskey(options, name) for name in ("source", "output")) || error("required: --source and --output")
    return options
end

options = parse_cli(ARGS)
source = abspath(options["source"])
output = abspath(options["output"])
ispath(output) && error("output already exists: $(output)")

polygons = NaturalEarthBasemap.load_polygons(source)

figure = Figure(;
    size=(256, 256),
    figure_padding=0,
    backgroundcolor=NaturalEarthBasemap.OCEAN_COLOR,
)
axis = Axis(
    figure[1, 1];
    backgroundcolor=NaturalEarthBasemap.OCEAN_COLOR,
    xautolimitmargin=(0, 0),
    yautolimitmargin=(0, 0),
)
NaturalEarthBasemap.draw!(axis, polygons; depth=0)
limits!(axis, -180, 180, -85.05113, 85.05113)
hidedecorations!(axis)
hidespines!(axis)

tile_root = joinpath(output, "0", "0")
mkpath(tile_root)
save(joinpath(tile_root, "0.png"), figure; px_per_unit=1)
cp(joinpath(@__DIR__, "README.md"), joinpath(output, "README.md"))
cp(joinpath(@__DIR__, "LICENSE.md"), joinpath(output, "LICENSE.md"))
println("Wrote Natural Earth z0 basemap tile to $(output)")
