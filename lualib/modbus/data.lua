local strpack = string.pack
local strunpack = string.unpack
local strrep = string.rep
local strfmt = string.format
local strb = string.byte
local tblunpack = table.unpack
local tblins = table.insert
local tblcon = table.concat
local tblremove = table.remove

local data = {}
function data.pack_be(fc, ...)
    local f = p_be[fc]
    assert(f, err.unknown_fc)
    return f(fc, ...)
end

function data.pack_le(fc, ...)
    local f = p_le[fc]
    assert(f, err.unknown_fc)
    return f(fc, ...)
end

function data.unpack_be(fc, data)
    local f = u_be[fc]
    assert(f, err.unknown_fc)
    return fc, f(data)
end

function data.unpack_le(fc, data)
    local f = u_le[fc]
    assert(f, err.unknown_fc)
    return fc, f(data)
end

return data
