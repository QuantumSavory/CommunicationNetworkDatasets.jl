module NaturalEarthBasemap

using CairoMakie
using JSON3: JSON3
using SHA: sha256

const SOURCE_PATH = joinpath(@__DIR__, "ne_110m_land.geojson")
const SOURCE_SHA256 = "9e0729ee253ca7d7a5c4ae9395fb1902264c5377c52e224d13dd85010e2835d9"
const OCEAN_COLOR = RGBf(0.82, 0.90, 0.96)
const LAND_COLOR = RGBf(0.86, 0.84, 0.73)
const COAST_COLOR = RGBf(0.55, 0.58, 0.52)

function exterior_rings(geometry)
    geometry.type == "Polygon" && return [first(geometry.coordinates)]
    geometry.type == "MultiPolygon" && return [first(polygon) for polygon in geometry.coordinates]
    error("unsupported Natural Earth geometry $(geometry.type)")
end

function load_polygons(source=SOURCE_PATH)
    bytes2hex(open(sha256, source)) == SOURCE_SHA256 ||
        error("Natural Earth source checksum does not match")
    collection = JSON3.read(read(source, String))
    collection.type == "FeatureCollection" || error("expected a GeoJSON FeatureCollection")
    polygons = CairoMakie.Polygon[]
    for feature in collection.features, ring in exterior_rings(feature.geometry)
        points = CairoMakie.Point2f[
            (Float32(point[1]), Float32(point[2])) for point in ring
        ]
        push!(polygons, CairoMakie.Polygon(points))
    end
    isempty(polygons) && error("Natural Earth source contains no land polygons")
    return polygons
end

function draw!(axis, polygons; depth=-5)
    land = poly!(
        axis,
        polygons;
        color=LAND_COLOR,
        strokecolor=COAST_COLOR,
        strokewidth=0.25,
    )
    translate!(land, 0, 0, depth)
    return land
end

ocean_tile(data) = fill(OCEAN_COLOR, size(data))

end
