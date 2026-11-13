-- lib/ymd.luau — мини-клиент демона ymd (HTTP /v1).
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

-- Универсальный запрос: cb(data, err, status).
-- err — короткий код для UI ("unauthorized", "offline", "bad json", …).
function M.request(method, path, body, cb)
  local key = M.key()
  if not key then
    cb(nil, "no-key", 0)
    return
  end

  local headers = { "X-YMD-Session: " .. key }
  if body ~= nil then
    headers[#headers + 1] = "Content-Type: application/json"
  end

  noctalia.http({
    url = M.base .. path,
    method = method,
    headers = headers,
    body = body ~= nil and noctalia.json.encode(body) or nil,
  }, function(resp)
    local status = code_of(resp)
    if status == 401 then
      cb(nil, "unauthorized", status)
      return
    end
    if status ~= 200 then
      cb(nil, "http " .. tostring(status), status)
      return
    end
    local raw = body_of(resp)
    if not raw then
      cb(nil, "empty", status)
      return
    end
    local ok, data = pcall(noctalia.json.decode, raw)
    if not ok then
      cb(nil, "bad json", status)
      return
    end
    cb(data, nil, status)
  end)
end

function M.get(path, cb)
  M.request("GET", path, nil, cb)
end

function M.post(path, body, cb)
  M.request("POST", path, body or {}, cb)
end

function M.del(path, cb)
  M.request("DELETE", path, nil, cb)
end

-- POST /v1/cmd { op = "..." } / { op, payload }
function M.cmd(op, cb)
  M.post("/v1/cmd", { op = op }, function(_, err)
    if cb then
      cb(err == nil)
    end
  end)
end

function M.cmd_payload(op, payload, cb)
  M.post("/v1/cmd", { op = op, payload = payload }, function(_, err)
    if cb then
      cb(err == nil)
    end
  end)
end

-- Percent-encoding для query-строк (ASCII + UTF-8 байты).
function M.urlencode(text)
  return (tostring(text):gsub("[^%w%-%._~]", function(char)
    return string.format("%%%02X", string.byte(char))
  end))
end

-- GET-обёртки под конкретные разделы.
function M.search(query, cb)
  M.get("/v1/search?q=" .. M.urlencode(query), cb)
end

function M.home(cb)
  M.get("/v1/home", cb)
end

function M.metatags(cb)
  M.get("/v1/discovery/metatags", cb)
end

function M.genres(cb)
  M.get("/v1/discovery/genres", cb)
end

function M.tag(tag, cb)
  M.get("/v1/discovery/tag?tag=" .. M.urlencode(tag), cb)
end

function M.playlist(uid, kind, cb)
  M.get("/v1/playlist?uid=" .. tostring(uid) .. "&kind=" .. tostring(kind), cb)
end

function M.album(id, cb)
  M.get("/v1/album?id=" .. M.urlencode(id), cb)
end

function M.favorites(cb)
  M.get("/v1/favorites", cb)
end

function M.account(cb)
  M.get("/v1/account", cb)
end

function M.radio(station, cb)
  M.post("/v1/radio", { station = station }, cb)
end

-- SSE: on_state(table), on_close(reason)
function M.subscribe(on_state, on_close)
  local key = M.key()
  if not key then
    if on_close then
      on_close("no-key")
    end
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
    if on_close then
      on_close("closed")
    end
  end)
end

return M
