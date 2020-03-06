local skynet = require "skynet"
local sys = require "sys"

local function call(addr, ...)
    return skynet.call(addr, "lua", ...)
end

local function send(addr, ...)
    skynet.send(addr, "lua", ...)
end

local api = {}

function api.datetime(time)
    if time then
        return os.date("%Y-%m-%d %H:%M:%S", time)
    else
        return os.date("%Y-%m-%d %H:%M:%S", math.floor(skynet.time()))
    end
end

function api.reg_cmd(name, desc, internal)
    if not internal and type(_ENV[name]) ~= "function" then
        return
    end
    send(sys.gateway_addr, "reg_cmd", name, desc)
end

local dpname
local devlist = {}
local function dev_name(name, dpname)
    return name.."@"..dpname
end

function api.reg_dev(name, desc)
    if desc == true then
        dpname = name
        send(sys.gateway_addr, "reg_dev", name, desc)
    else
        if dpname and
            type(name) == "string" and
            type(desc) == "string" and
            not devlist[name] then
            devlist[name] = {
                buffer = {},
                cov = {}
            }
            local dev = dev_name(name, dpname)
            send(sys.gateway_addr, "reg_dev", dev, desc)
            send(sys.gateway_mqtt_addr, "post", "online", dev)
        end
    end
end

function api.unreg_dev(name)
    if name == true then
        send(sys.gateway_addr, "unreg_dev", name)
        local dev
        for n, _ in pairs(devlist) do
            dev = dev_name(n, dpname)
            send(sys.gateway_mqtt_addr, "post", "offline", dev)
        end
        dpname = nil
        devlist = {}
    else
        if dpname and devlist[name] then
            devlist[name] = nil
            local dev = dev_name(name, dpname)
            send(sys.gateway_addr, "unreg_dev", dev)
            send(sys.gateway_mqtt_addr, "post", "offline", dev)
        end
    end
end

function api.post_attr(dev, attr)
    if dpname and devlist[dev] then
        send(sys.gateway_mqtt_addr, "post", "attributes", dev_name(dev, dpname), attr)
    end
end

------------------------------------------
local r_table = {}
function api.pack_data(data)
    local p = {
        ts = skynet.time()*1000,
        values = data
    }
    return {p}
end

function api.ts_value(data)
    return data.ts
end

function api.data_value(data)
    return data.values
end

local function raw_post(dev, data)
    local d = dev_name(dev, dpname)
    for _, targets in pairs(r_table) do
        for t, _ in pairs(targets) do
            send(t, "data", d, data)
        end
    end
end
local function do_post(dev, data)
    local p = api.pack_data(data)
    raw_post(dev, p)
end
function api.post_data(dev, data)
    if dpname and devlist[dev] and
        type(data) == "table" and next(data) then
        do_post(dev, data)
    end
end

local function filter_cov(dev, data)
    local c = devlist[dev].cov
    if next(c) then
        local last
        for k, v in pairs(data) do
            last = c[k]
            if last == nil then
                c[k] = v
            end
            if last == v then
                data[k] = nil
            end
        end
    else
        devlist[dev].cov = data
    end
    return data
end
function api.cov_post(dev, data)
    if dpname and devlist[dev] and
        type(data) == "table" and next(data) then
        data = filter_cov(dev, data)
        if next(data) then
            do_post(dev, data)
        end
    end
end

function api.batch_post(size)
    if type(size) == "number" and size <= 200 then
        return function(dev, data)
            if dpname and devlist[dev] and
                type(data) == "table" and next(data) then
                local p = api.pack_data(data)
                local b = devlist[dev].buffer
                table.move(p, 1, #p, #b+1, b)
                if #b >= size then
                    raw_post(dev, b)
                    devlist[dev].buffer = {}
                end
            end
        end
    else
        return false
    end
end

function api.route_data(dev, data)
    local s = tonumber(dev:match("_(%d+)$"))
    if s and r_table[s] then
        for t, _ in pairs(r_table[s]) do
            send(t, "data", dev, data)
        end
    end
end

function api.route_add(source, target)
    if not r_table[source] then
        r_table[source] = {}
    end
    local v = r_table[source][target]
    if v then
        r_table[source][target] = v + 1
    else
        r_table[source][target] = 1
    end
end

function api.route_del(source, target)
    if r_table[source] then
        local v = r_table[source][target]
        if v == 1 then
            r_table[source][target] = nil
        else
            r_table[source][target] = v - 1
        end
    end
end

------------------------------------------
return setmetatable({}, {
  __index = api,
  __newindex = function(t, k, v)
                 error("Attempt to modify read-only table")
               end,
  __metatable = false
})
