local api = require "api"

local calc

local f_map = {
    multiply = function(arg)
        return function(v) return v * arg end
    end
}

function on_data(dev, data)
    for _, d in ipairs(data) do
        local vlist = api.data_value(d)
        for k, v in pairs(vlist) do
            vlist[k] = calc(v)
        end
    end
    api.route_data(dev, data)
end

function on_conf(conf)
    local f = f_map[conf.f]
    calc = f(conf.arg)
end
