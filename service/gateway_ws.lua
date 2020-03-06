local skynet = require "skynet"
local websocket = require "http.websocket"
local socket = require "skynet.socket"
local sys = require "sys"
local log = require "log"
local text = require("text").ws

local port = ...

local handle = {}
function handle.connect(id)
    print("ws connect from: " .. tostring(id))
end

function handle.handshake(id, header, url)
    local addr = websocket.addrinfo(id)
    print("ws handshake from: " .. tostring(id), "url", url, "addr:", addr)
    print("----header-----")
    for k,v in pairs(header) do
        print(k,v)
    end
    print("--------------")
end

function handle.message(id, msg)
    websocket.write(id, msg)
end

function handle.ping(id)
    print("ws ping from: " .. tostring(id) .. "\n")
end

function handle.pong(id)
    print("ws pong from: " .. tostring(id))
end

function handle.close(id, code, reason)
    print("ws close from: " .. tostring(id), code, reason)
end

function handle.error(id)
    print("ws error from: " .. tostring(id))
end

skynet.start(function ()
    skynet.dispatch("lua", function (_,_, id, protocol, addr)
        local ok, err = websocket.accept(id, handle, protocol, addr)
        if not ok then
            print(err)
        end
    end)
end)

skynet.start(function ()
    local agent = {}
    for i= 1, 20 do
        agent[i] = skynet.newservice(SERVICE_NAME, "agent")
    end
    local balance = 1
    local protocol = "ws"
    local id = socket.listen("0.0.0.0", port)
    skynet.error(string.format("Listen websocket port 9948 protocol:%s", protocol))
    socket.start(id, function(id, addr)
        print(string.format("accept client socket_id: %s addr:%s", id, addr))
        skynet.send(agent[balance], "lua", id, protocol, addr)
        balance = balance + 1
        if balance > #agent then
            balance = 1
        end
    end)
end)
