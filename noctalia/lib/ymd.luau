-- lib/ymd.luau — мини-клиент демона ymd (P0).
-- Требует plugin_api >= 22 (require относительных модулей).

local M = {}

M.base = "http://127.0.0.1:8765"

-- capability-ключ: $XDG_RUNTIME_DIR/ymd/session.key (0600)
function M.key()
  local rt = noctalia.getenv("XDG_RUNTIME_DIR")
  if not rt then
    return nil
  end
  local ok, data = pcall(noctalia.readFile, rt .. "/ymd/session.key")
  if not ok or type(data) ~= "string" then
    return nil
  end
  local key = data:gsub("%s+$", "")
  if #key < 16 then
    return nil
  end
  return key
end

local function body_of(resp)
  if type(resp) ~= "table" then
    return nil
  end
  return resp.body or resp.text or resp.data
end

local function code_of(resp)
  if type(resp) ~= "table" then
    return -1
  end
  return resp.status or resp.code or resp.statusCode or -1
end

-- GET /v1/... ; cb(data, err)
function M.get(path, cb)
  local key = M.key()
  if not key then
    cb(nil, "no session key (ymd not running?)")
    return
  end

  noctalia.http({
    url = M.base .. path,
    method = "GET",
    headers = { "X-YMD-Session: " .. key },
  }, function(resp)
    local body = body_of(resp)
    if code_of(resp) ~= 200 or not body then
      cb(nil, "http " .. tostring(code_of(resp)))
      return
    end
    local ok, data = pcall(noctalia.json.decode, body)
    if not ok then
      cb(nil, "bad json")
      return
    end
    cb(data, nil)
  end)
end

-- POST /v1/cmd { op = "..." }
function M.cmd(op, cb)
  local key = M.key()
  if not key then
    if cb then cb(false) end
    return
  end

  noctalia.http({
    url = M.base .. "/v1/cmd",
    method = "POST",
    headers = {
      "X-YMD-Session: " .. key,
      "Content-Type: application/json",
    },
    body = noctalia.json.encode({ op = op }),
  }, function(resp)
    if cb then cb(code_of(resp) == 200) end
  end)
end

-- POST /v1/cmd { op = "...", payload = {...} }
function M.cmd_payload(op, payload, cb)
  local key = M.key()
  if not key then
    if cb then cb(false) end
    return
  end

  noctalia.http({
    url = M.base .. "/v1/cmd",
    method = "POST",
    headers = {
      "X-YMD-Session: " .. key,
      "Content-Type: application/json",
    },
    body = noctalia.json.encode({ op = op, payload = payload }),
  }, function(resp)
    if cb then cb(code_of(resp) == 200) end
  end)
end

-- Percent-encoding для query-строк (ASCII + UTF-8 байты).
function M.urlencode(text)
  return (tostring(text):gsub("[^%w%-%._~]", function(char)
    return string.format("%%%02X", string.byte(char))
  end))
end

-- GET /v1/search?q=...
function M.search(query, cb)
  M.get("/v1/search?q=" .. M.urlencode(query), cb)
end

-- SSE: on_state(table), on_close(reason)
function M.subscribe(on_state, on_close)
  local key = M.key()
  if not key then
    if on_close then on_close("no-key") end
    return nil
  end

  return noctalia.httpStream({
    url = M.base .. "/v1/events",
    headers = { "X-YMD-Session: " .. key },
  }, function(line)
    if line:sub(1, 5) == "data:" then
      local payload = line:sub(6):gsub("^%s+", "")
      local ok, state = pcall(noctalia.json.decode, payload)
      if ok and state then
        on_state(state)
      end
    end
  end, function()
    if on_close then on_close("closed") end
  end)
end

return M
