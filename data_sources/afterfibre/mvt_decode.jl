module MVTDecode

import ProtoBuf as PB

struct MVTValue
    kind::Symbol
    value::Any
end

struct MVTFeature
    id::UInt64
    tags::Vector{UInt32}
    geometry_type::UInt32
    geometry::Vector{UInt32}
end

struct MVTLayer
    version::UInt32
    name::String
    features::Vector{MVTFeature}
    keys::Vector{String}
    values::Vector{MVTValue}
    extent::UInt32
end

struct MVTTile
    layers::Vector{MVTLayer}
end

function PB.decode(d::PB.AbstractProtoDecoder, ::Type{MVTValue})
    kind, value = :missing, nothing
    while !PB.message_done(d)
        field, wire = PB.decode_tag(d)
        if field == 1
            kind, value = :string, PB.decode(d, String)
        elseif field == 2
            kind, value = :float, PB.decode(d, Float32)
        elseif field == 3
            kind, value = :double, PB.decode(d, Float64)
        elseif field == 4
            kind, value = :int, PB.decode(d, Int64)
        elseif field == 5
            kind, value = :uint, PB.decode(d, UInt64)
        elseif field == 6
            kind, value = :sint, PB.decode(d, Int64, Val{:zigzag})
        elseif field == 7
            kind, value = :bool, PB.decode(d, Bool)
        else
            PB.skip(d, wire)
        end
    end
    kind == :missing && error("MVT value has no variant")
    return MVTValue(kind, value)
end

function PB.decode(d::PB.AbstractProtoDecoder, ::Type{MVTFeature})
    id = zero(UInt64)
    tags = PB.BufferedVector{UInt32}()
    geometry_type = zero(UInt32)
    geometry = PB.BufferedVector{UInt32}()
    while !PB.message_done(d)
        field, wire = PB.decode_tag(d)
        if field == 1
            id = PB.decode(d, UInt64)
        elseif field == 2
            PB.decode!(d, wire, tags)
        elseif field == 3
            geometry_type = PB.decode(d, UInt32)
        elseif field == 4
            PB.decode!(d, wire, geometry)
        else
            PB.skip(d, wire)
        end
    end
    return MVTFeature(id, tags[], geometry_type, geometry[])
end

function PB.decode(d::PB.AbstractProtoDecoder, ::Type{MVTLayer})
    version = zero(UInt32)
    name = ""
    features = PB.BufferedVector{MVTFeature}()
    keys = PB.BufferedVector{String}()
    values = PB.BufferedVector{MVTValue}()
    extent = zero(UInt32)
    while !PB.message_done(d)
        field, wire = PB.decode_tag(d)
        if field == 15
            version = PB.decode(d, UInt32)
        elseif field == 1
            name = PB.decode(d, String)
        elseif field == 2
            PB.decode!(d, features)
        elseif field == 3
            PB.decode!(d, keys)
        elseif field == 4
            PB.decode!(d, values)
        elseif field == 5
            extent = PB.decode(d, UInt32)
        else
            PB.skip(d, wire)
        end
    end
    return MVTLayer(version, name, features[], keys[], values[], extent)
end

function PB.decode(d::PB.AbstractProtoDecoder, ::Type{MVTTile})
    layers = PB.BufferedVector{MVTLayer}()
    while !PB.message_done(d)
        field, wire = PB.decode_tag(d)
        if field == 3
            PB.decode!(d, layers)
        else
            PB.skip(d, wire)
        end
    end
    return MVTTile(layers[])
end

function decode_tile(bytes)
    return PB.decode(PB.ProtoDecoder(IOBuffer(bytes)), MVTTile)
end

function properties(feature::MVTFeature, layer::MVTLayer)
    iseven(length(feature.tags)) || error("MVT feature has an odd property-tag count")
    result = Dict{String,Any}()
    for index in 1:2:length(feature.tags)
        key_index = Int(feature.tags[index]) + 1
        value_index = Int(feature.tags[index + 1]) + 1
        checkbounds(Bool, layer.keys, key_index) || error("MVT property key index is out of bounds")
        checkbounds(Bool, layer.values, value_index) || error("MVT property value index is out of bounds")
        key = layer.keys[key_index]
        haskey(result, key) && error("MVT feature repeats property $(key)")
        result[key] = layer.values[value_index].value
    end
    return result
end

zigzag(value::UInt32) = Int64(value >> 1) ⊻ -Int64(value & 1)

function line_parts(feature::MVTFeature, tile_x::Int, tile_y::Int, extent::Int)
    feature.geometry_type == 2 || error("MVT feature is not a line")
    parts = Vector{Vector{Tuple{Int64,Int64}}}()
    cursor_x = Int64(0)
    cursor_y = Int64(0)
    current = nothing
    index = 1
    while index <= length(feature.geometry)
        command = feature.geometry[index]
        index += 1
        command_id = command & 0x7
        count = Int(command >> 3)
        count > 0 || error("MVT geometry command has zero repetitions")
        if command_id == 1
            for _ in 1:count
                index + 1 <= length(feature.geometry) || error("truncated MVT MoveTo command")
                cursor_x += zigzag(feature.geometry[index])
                cursor_y += zigzag(feature.geometry[index + 1])
                index += 2
                current = Tuple{Int64,Int64}[]
                push!(current, (
                    Int64(tile_x) * extent + cursor_x,
                    Int64(tile_y) * extent + cursor_y,
                ))
                push!(parts, current)
            end
        elseif command_id == 2
            isnothing(current) && error("MVT LineTo appears before MoveTo")
            for _ in 1:count
                index + 1 <= length(feature.geometry) || error("truncated MVT LineTo command")
                cursor_x += zigzag(feature.geometry[index])
                cursor_y += zigzag(feature.geometry[index + 1])
                index += 2
                push!(current, (
                    Int64(tile_x) * extent + cursor_x,
                    Int64(tile_y) * extent + cursor_y,
                ))
            end
        else
            error("unsupported MVT line command $(command_id)")
        end
    end
    all(length(part) >= 2 for part in parts) || error("MVT line contains a degenerate part")
    return parts
end

export MVTFeature, MVTLayer, MVTTile, decode_tile, properties, line_parts

end
