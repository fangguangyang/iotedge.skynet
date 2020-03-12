#!/bin/sh

ROOT=$(dirname $0)/..
LUA=${ROOT}/skynet/3rd/lua/lua
export LUA_CPATH="${ROOT}/bin/?.so;${ROOT}/bin/prebuilt/?.so"
export LUA_PATH="${ROOT}/lualib/?.lua"

STAT="load(\" \
    local cjson = require 'cjson' \
    local env = {} \
    loadfile('$1', 't', env)() \
    print(cjson.encode(env)) \
    \")()"

if [ -n "$2" ]; then
    ${LUA} -e "${STAT}" |jq '.' > $2
else
    ${LUA} -e "${STAT}" |jq
fi
