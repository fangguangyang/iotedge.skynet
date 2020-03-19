local skynet = require "skynet.manager"
local api = require "api"

local running = true
local host = "iotedge-host"
local post

local cmd_desc = {
    status = "Show host status"
}

local function reg_cmd()
    for k, v in pairs(cmd_desc) do
        api.reg_cmd(k, v)
    end
end

local function fetch_cpu()
    if running then
        post(host, {["CPU Usage"] = math.random(10000)})
        skynet.timeout(100, fetch_cpu)
    end
end

local function fetch_mem()
    if running then
        post(host, {["Memory Usage"] = math.random(10000)})
        skynet.timeout(100, fetch_mem)
    end
end

function status(dev)
    return dev.." is running"
end

function on_conf()
    reg_cmd()
    skynet.timeout(600, fetch_cpu)
    skynet.timeout(600, fetch_mem)
    skynet.timeout(500, function()
        local conf = {
            desc = "iotedge host"
        }
        api.reg_dev(host, conf)
        api.batch_size(host, 10)
        post = api.post_data
    end)
    return true
end

function on_exit()
    running = false
end
