-- widget.luau — бар-виджет P0: глиф состояния + "Трек — Артист".
-- Без анимаций: обновление раз в секунду только при воспроизведении.

local ymd = require("./lib/ymd.luau")

local s = {
  status = "off",
  title = "",
  artists = {},
  position = 0,
  duration = 0,
  rev = -1,
  track_id = "",
  cover_url = "",
  cover_path = "",
}

local GLYPH = {
  playing = "player-play",
  paused = "player-pause",
  idle = "music",
  off = "music-off",
  error = "alert-triangle",
}

local function safe_set_text(text)
  local ok = pcall(barWidget.setText, text)
  if not ok then
    noctalia.log("[ym] barWidget.setText unavailable")
  end
end

local function safe_set_glyph(name)
  local ok = pcall(barWidget.setGlyph, name)
  if not ok then
    noctalia.log("[ym] barWidget.setGlyph unavailable: " .. name)
  end
end

-- баровый виджет умеет картинку (setImage), но только локальным путём:
-- обложку скачиваем в pluginDataDir и переиспользуем файл из панели.
local function safe_set_image(path)
  local ok = pcall(barWidget.setImage, path)
  if not ok then
    noctalia.log("[ym] barWidget.setImage unavailable")
  end
end

local function ensure_cover()
  if s.cover_url == "" or s.cover_path ~= "" then
    return
  end
  local dest = noctalia.pluginDataDir() .. "/cover_" .. tostring(s.track_id) .. ".img"
  s.cover_path = dest
  if noctalia.readFile(dest) then
    safe_set_image(dest)
    return
  end
  noctalia.download(s.cover_url, dest, function(ok)
    if ok then
      safe_set_image(dest)
    else
      s.cover_path = ""
    end
  end)
end

local function render()
  safe_set_glyph(GLYPH[s.status] or GLYPH.idle)

  if s.status == "off" then
    safe_set_text("ymd off")
    return
  end

  if s.title == "" then
    safe_set_text("")
    return
  end

  local line = s.title
  if s.artists[1] then
    line = line .. " — " .. s.artists[1]
  end
  if #line > 34 then
    line = line:sub(1, 33) .. "…"
  end
  safe_set_text(line)
end

local function apply(state)
  if type(state) ~= "table" then
    return
  end
  if (state.rev or -1) <= s.rev then
    return
  end

  s.rev = state.rev or 0
  s.status = state.status or "idle"
  s.position = state.positionMs or 0

  if state.track then
    s.title = state.track.title or ""
    s.artists = state.track.artists or {}
    s.duration = state.track.durationMs or 0

    local id = tostring(state.track.id or "")
    if id ~= s.track_id then
      s.track_id = id
      s.cover_path = ""
    end
    s.cover_url = state.track.cover or ""
  else
    s.title = ""
    s.artists = {}
    s.duration = 0
    s.cover_url = ""
    s.cover_path = ""
    s.track_id = ""
  end

  ensure_cover()
  render()
end

function update()
  noctalia.setUpdateInterval(s.status == "playing" and 1000 or 3000)
  ymd.get("/v1/state", function(state, err)
    if err then
      s.status = "off"
      safe_set_glyph(GLYPH.off)
      safe_set_text("ymd off")
      return
    end
    apply(state)
  end)
end

function onClick()
  ymd.cmd("toggle")
end

function onRightClick()
  noctalia.togglePanel("pbolkhovitin/yandex-music:panel")
end

function onMiddleClick()
  ymd.cmd("like")
end

function onScroll(axis, steps, startsGesture)
  if axis ~= "vertical" or not startsGesture then
    return
  end
  if steps < 0 then
    ymd.cmd("prev")
  else
    ymd.cmd("next")
  end
end

function onIpc(event, payload)
  noctalia.log("[ym] ipc " .. tostring(event))
  update()
end

function onEnable()
  noctalia.log("[ym] widget enabled")
end
