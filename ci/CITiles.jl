module CITiles

using Downloads
using Tyler

const TILE_TEMPLATE = "https://tiles.quantumsavory.org/styles/ci/{z}/{x}/{y}.png"
const TILE_ATTRIBUTION = "Protomaps © OpenStreetMap contributors; hosted by QuantumSavory"
const PNG_SIGNATURE = UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]

function tile_url(template=TILE_TEMPLATE)
    key = get(ENV, "TILE_CI_KEY", "")
    isempty(key) || occursin(r"\A[0-9a-f]{64}\z", key) || throw(ArgumentError(
        "TILE_CI_KEY must contain 64 lowercase hexadecimal characters",
    ))
    return isempty(key) ? template : string(template, "?ci_key=", key)
end

function provider()
    return Tyler.TileProviders.Provider(
        tile_url();
        max_zoom=13,
        attribution=TILE_ATTRIBUTION,
    )
end

function preflight()
    output = IOBuffer()
    response = try
        Downloads.request(
            Tyler.TileProviders.geturl(provider(), 0, 0, 0);
            output,
            throw=false,
        )
    catch
        nothing
    end
    isnothing(response) && error("could not reach the QuantumSavory CI tile server")
    response.status == 200 || error(
        "QuantumSavory CI tile preflight returned HTTP $(response.status)",
    )
    body = take!(output)
    is_png = length(body) >= length(PNG_SIGNATURE) &&
        body[1:length(PNG_SIGNATURE)] == PNG_SIGNATURE
    is_png || error(
        "QuantumSavory CI tile preflight did not return a PNG image",
    )
    return nothing
end

end
