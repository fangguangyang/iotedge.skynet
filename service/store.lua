local skynet = require "skynet"
local api = require "api"
local log = require "log"
local sqlite3 = require('lsqlite3complete')

local running = false
local applist = {}
local command = {}

function command.stop(addr)
    running = false
end
function command.connected(addr, name)
end
function command.disconnected(addr, name)
end
function command.post(addr, dev, data)
end

skynet.start(function()
    skynet.dispatch("lua", function(session, addr, cmd, ...)
        local f = command[cmd]
        if f then
            f(addr, ...)
        end
    end)
end)
