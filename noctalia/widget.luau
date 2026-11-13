-- widget.luau — бар-виджет: статичная иконка музыки + "Трек — Артист".
-- Иконка не меняется (никаких play/pause-глифов и обложек): бар остаётся
-- визуально стабильным, состояние читается по тексту и подсказке.
-- Без анимаций: обновление раз в секунду только при воспроизведении.

local ymd = require("./lib/ymd.luau")

local ICON = "music"
local MAX_CHARS = 34

local s = {
  status = "off",
  title = "",
  artists = {},
  rev = -1,
  icon_set = false,
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

local function safe_set_tooltip(text)
  if text == "" then
    if pcall(barWidget.clearTooltip) then
      return
    end
    return
  end
  pcall(barWidget.setTooltip, text)
end

-- Иконка ставится один раз: повторные вызовы бессмысленны и мигают при reload.
local function ensure_icon()
  if s.icon_set then
    return
  end
  safe_set_glyph(ICON)
  s.icon_set = true
end

local function line()
  if s.status == "off" then
    return "ymd off"
  end
  if s.title == "" then
    return ""
  end

  local text = s.title
  if s.artists[1] then
    text = text .. " — " .. s.artists[1]
  end
  if #text > MAX_CHARS then
    text = text:sub(1, MAX_CHARS - 1) .. "…"
  end
  return text
end

local function tooltip()
  if s.title == "" then
    return ""
  end
  local artists = table.concat(s.artists, ", ")
  if artists == "" then
    return s.title
  end
  return s.title .. " — " .. artists
end

local function render()
  ensure_icon()
  safe_set_text(line())
  safe_set_tooltip(tooltip())
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

  if state.track then
    s.title = state.track.title or ""
    s.artists = state.track.artists or {}
  else
    s.title = ""
    s.artists = {}
  end

  render()
end

function update()
  noctalia.setUpdateInterval(s.status == "playing" and 1000 or 3000)
  ymd.get("/v1/state", function(state, err)
    if err then
      s.status = "off"
      s.title = ""
      s.artists = {}
      render()
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
  s.icon_set = false
  ensure_icon()
  noctalia.log("[ym] widget enabled")
end
