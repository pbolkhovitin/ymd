-- bridge.luau — S4: подписка на SSE демона (noctalia.httpStream).
-- Пишет последнее состояние в pluginDataDir для остальных entry.

local ymd = require("./lib/ymd.luau")

local handle = nil
local last_rev = -1

local function save(state)
  local dir = noctalia.pluginDataDir()
  if not dir then
    return
  end
  local ok = pcall(noctalia.writeFile, dir .. "/last_state.json", noctalia.json.encode(state))
  if not ok then
    noctalia.log("[bridge] writeState failed")
  end
end

local function on_state(state)
  if (state.rev or -1) <= last_rev then
    return
  end
  last_rev = state.rev or 0

  local title = "-"
  if state.track and state.track.title then
    title = state.track.title
  end
  noctalia.log(string.format("[bridge] rev=%d status=%s title=%s", last_rev, tostring(state.status), title))
  save(state)
end

local function subscribe()
  handle = ymd.subscribe(on_state, function(reason)
    noctalia.log("[bridge] stream closed: " .. tostring(reason))
    handle = nil
  end)
  noctalia.log("[bridge] subscribe -> " .. tostring(handle))
end

function update()
  noctalia.setUpdateInterval(5000)
  if handle == nil then
    subscribe()
  end
end

function onEnable()
  subscribe()
end

function onExit(signal, reason)
  noctalia.log("[bridge] exit " .. tostring(signal) .. " " .. tostring(reason))
end
