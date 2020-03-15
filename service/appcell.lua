local skynet = require "skynet"
local api = require "api"
local log = require "log"
local text = require("text").app

local tpl, name, gateway_addr, gateway_mqtt_addr = ...
local command = {}

local memlimit = require("sys").memlimit()
if memlimit then
    skynet.memlimit(memlimit)
end

local function load_app()
    --local cache = require "skynet.codecache"
    --cache.mode("OFF")
    require(tpl)
    --cache.mode("ON")
end

function command.route_add(s, t)
    api.route_add(s, t)
end

function command.route_del(s, t)
    api.route_del(s, t)
end

setmetatable(command, { __index = function(t, cmd)
    local f
    if cmd == "conf" then
        if type(_ENV.on_conf) == "function" then
            f = function(conf)
                skynet.ret(skynet.pack(_ENV.on_conf(conf)))
            end
        else
            f = function()
                skynet.ret(skynet.pack(false, text.no_conf_handler))
            end
        end
    elseif cmd == "data" then
        if type(_ENV.on_data) == "function" then
            f = _ENV.on_data
        else
            f = function()
                log.error(text.no_data_handler)
            end
        end
    elseif cmd == "exit" then
        if type(_ENV.on_exit) == "function" then
            f = function()
                _ENV.on_exit()
                api.unreg_dev(true)
                skynet.exit()
            end
        else
            f = function()
                api.unreg_dev(true)
                skynet.exit()
            end
        end
    elseif type(_ENV[cmd]) == "function" then
        f = function(dev, arg)
            local d = string.match(dev, "^(.+)@")
            if d then
                skynet.ret(skynet.pack(_ENV[cmd](d, arg)))
            else
                skynet.ret(skynet.pack(_ENV[cmd](arg)))
            end
        end
    else
        f = function()
            skynet.ret(skynet.pack(false, text.unknown_cmd))
        end
    end
    t[cmd] = f
    return f
end})

skynet.start(function()
    load_app()
    api.init(gateway_addr, gateway_mqtt_addr)
    api.reg_dev(name, true)
    skynet.dispatch("lua", function(_, _, cmd, ...)
        command[cmd](...)
    end)
end)
