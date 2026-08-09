using CSV: CSV
using DataFrames: DataFrame
using HTTP: HTTP
using JSON3: JSON3
using SHA: sha256

include(joinpath(@__DIR__, "..", "common.jl"))
using .ExtractionCommon: parse_cli

const TILEJSON_URL = "https://d316kar6yg8hyq.cloudfront.net/africa-fiber.json"
const TILE_TEMPLATE = "https://d316kar6yg8hyq.cloudfront.net/africa-fiber/{z}/{x}/{y}.mvt"
const TILEJSON_SHA256 = "a33196caad678c330ca73aed7fbff93e51eb49fbf921180e88829d87a8987e39"
const BOUNDS = [-17.422046, -34.499567, 55.744624, 36.867184]
const ZOOM = 8
const X_RANGE = 115:167
const Y_RANGE = 99:154

function checked_get(url)
    response = nothing
    for attempt in 1:8
        response = HTTP.get(
            url,
            ["Accept-Encoding" => "identity"];
            status_exception=false,
            decompress=false,
            retry=true,
            retries=3,
            connect_timeout=30,
            readtimeout=60,
        )
        response.status ∉ (429, 500, 502, 503, 504) && break
        attempt == 8 && break
        retry_after = tryparse(Int, HTTP.header(response, "Retry-After", ""))
        sleep(isnothing(retry_after) ? min(2.0^(attempt - 1), 30.0) : retry_after)
    end
    response.status in (200, 204) || error("$(url): HTTP status $(response.status)")
    encoding = lowercase(HTTP.header(response, "Content-Encoding", ""))
    encoding in ("", "identity") || error("$(url): unexpected content encoding $(encoding)")
    return response
end

options = parse_cli(ARGS; required=["output"])
output = abspath(options["output"])
ispath(output) && error("output already exists: $(output)")
mkpath(output)

tilejson_response = checked_get(TILEJSON_URL)
tilejson_response.status == 200 || error("TileJSON request returned no content")
tilejson_bytes = tilejson_response.body
bytes2hex(sha256(tilejson_bytes)) == TILEJSON_SHA256 || error("TileJSON checksum changed")
tilejson = JSON3.read(tilejson_bytes)
String(tilejson.scheme) == "xyz" || error("TileJSON scheme is not xyz")
length(tilejson.tiles) == 1 && String(only(tilejson.tiles)) == TILE_TEMPLATE ||
    error("TileJSON template changed")
[Float64(value) for value in tilejson.bounds] == BOUNDS || error("TileJSON bounds changed")
write(joinpath(output, "africa-fiber.json"), tilejson_bytes)

tiles = [(; z=ZOOM, x, y) for x in X_RANGE for y in Y_RANGE]
length(tiles) == 2_968 || error("unexpected tile enumeration")
for x in X_RANGE
    mkpath(joinpath(output, "tiles", string(ZOOM), string(x)))
end

rows = asyncmap(tiles; ntasks=4) do tile
    url = replace(
        TILE_TEMPLATE,
        "{z}" => string(tile.z),
        "{x}" => string(tile.x),
        "{y}" => string(tile.y),
    )
    response = checked_get(url)
    bytes = response.body
    response.status == 204 && !isempty(bytes) && error("$(url): HTTP 204 has a body")
    response.status == 200 && isempty(bytes) && error("$(url): HTTP 200 has an empty body")
    if !isempty(bytes)
        write(joinpath(
            output,
            "tiles",
            string(tile.z),
            string(tile.x),
            "$(tile.y).mvt",
        ), bytes)
    end
    return (;
        tile.z,
        tile.x,
        tile.y,
        status=response.status,
        byte_count=length(bytes),
        sha256=bytes2hex(sha256(bytes)),
        etag=HTTP.header(response, "ETag", ""),
    )
end

count(row -> row.status == 200, rows) == 937 || error("unexpected nonempty tile count")
count(row -> row.status == 204, rows) == 2_031 || error("unexpected empty tile count")
CSV.write(joinpath(output, "tile_inventory.csv"), DataFrame(rows); missingstring="")
println("Saved 937 nonempty and 2,031 empty zoom-8 tiles to $(output)")
