local skynet = require "skynet"
local api = require "api"
local lfs = require "lfs"
local sys = require "sys"
local log = require "log"
local sqlite3 = require('lsqlite3complete')
local text = require("text").store

local running = false
local applist = {}
local devlist = {}

local db_root = sys.db_root

local open_f = sqlite3.OPEN_READWRITE +
               sqlite3.OPEN_URI +
               sqlite3.OPEN_NOMUTEX

local function db_name(name)
    return string.format("file:/%s/%s/%s",
        lfs.currentdir(),
        db_root,
        name)
end

local function opendb(name, create)
    local n = db_name(name)
    if create then
        local db, _, err = sqlite3.open(n, open_f + sqlite3.OPEN_CREATE)
        if not db then
            log.error(text.open_fail, err)
        end
        return db
    else
        local db = sqlite3.open(n, open_f)
        return db
    end
end

local function enabled(dev)
    return devlist[dev]
end

local function start_post(app, addr)
end

local command = {}
function command.stop(addr)
    running = false
end

function command.online(addr, name)
    log.error(text.online, name)
    if not applist[addr] then
        applist[addr] = {}
    end
    local app = applist[addr]
    app.name = name
    if not app.db then
        app.db = opendb(name)
    end
    if app.db then
        start_post(app, addr)
    end
end

function command.offline(addr)
end

function command.data(addr, dev, data)
    local app = applist[addr]
    if app then
        if not app.db then
            app.db = opendb(app.name, true)
        end
    end
end

function command.dev_online(addr, dev, conf)
    if conf then
        devlist[dev] = conf
    end
end

skynet.start(function()
    pcall(lfs.mkdir, db_root)
    skynet.dispatch("lua", function(session, addr, cmd, ...)
        local f = command[cmd]
        if f then
            f(addr, ...)
        end
    end)
end)
