-- panel.luau — панель плеера: «сейчас играет», транспорт, поиск, очередь.
--
-- Принципы: без анимаций, цвета только из ролей палитры, иконки — tabler
-- (ui.button.glyph), списки живут в ui.scroll и не вылезают за панель.

local ymd = require("./lib/ymd.luau")

-- бюджет символов для одной строки списка: ширина панели ~396 px,
-- моноширинный шрифт 12 px ≈ 7 px/символ
local TITLE_BUDGET = 30
local ARTIST_BUDGET = 18

local s = {
  rev = -1,
  status = "off",
  title = "—",
  artist = "",
  position = 0,
  duration = 0,
  liked = false,
  query = "",
  cover_url = "",
  cover_path = "",
  track_id = "",
  results = {},
  queue = {},
  loop_mode = "all",
  shuffle = false,
  quality = "lossless",
  codec = nil,
  hint = "",
}

-- ui.image принимает ТОЛЬКО локальный путь (проп `path`), поэтому обложку
-- скачиваем в pluginDataDir и рисуем файлом.
-- forward declarations: ensure_cover зовёт render; ряды списков зовут play_*
local render
local play_result, play_queue

local function cover_file()
  return noctalia.pluginDataDir() .. "/cover_" .. tostring(s.track_id) .. ".img"
end

local function ensure_cover()
  if s.cover_url == "" or s.cover_path ~= "" then
    return
  end
  local dest = cover_file()
  noctalia.download(s.cover_url, dest, function(ok, err)
    if ok then
      s.cover_path = dest
      render()
    else
      s.cover_url = ""
      s.hint = "обложка: " .. tostring(err)
    end
  end)
end

local function cover_block()
  if s.cover_path == "" then
    return nil
  end
  return ui.image({ path = s.cover_path, fit = "cover", width = 44, height = 44 })
end

local function progress()
  if s.duration <= 0 then
    return 0
  end
  return math.min(1, s.position / s.duration)
end

local function fmt_time(ms)
  local value = math.max(0, math.floor((tonumber(ms) or 0) / 1000))
  return string.format("%d:%02d", math.floor(value / 60), value % 60)
end

local function short(text, limit)
  local value = tostring(text or "")
  local length = utf8.len(value)
  if not length or length <= limit then
    return value
  end
  -- режем по кодовым точкам, иначе кириллица ломается на середине байта
  local cut = utf8.offset(value, limit) or (#value + 1)
  return value:sub(1, cut - 1) .. "…"
end

local function track_line(item)
  local prefix = item.cached and "✓ " or ""
  local title = short(item.title, TITLE_BUDGET)
  local artist = (item.artists and item.artists[1]) or ""
  if artist ~= "" then
    return prefix .. title .. " · " .. short(artist, ARTIST_BUDGET)
  end
  return prefix .. title
end

local QUALITY_LABELS = {
  lossless = "FLAC",
  hq = "AAC 256",
  nq = "AAC 192",
  lq = "AAC 64",
  cache = "кэш",
}

local function quality_label()
  return QUALITY_LABELS[s.quality] or s.quality
end

-- Компактная иконка-кнопка: один набор (tabler), один размерный ряд.
local function icon_button(glyph, tooltip, action, variant, selected)
  return ui.button({
    glyph = glyph,
    tooltip = tooltip,
    variant = variant or "ghost",
    controlSize = "sm",
    glyphSize = 16,
    selected = selected,
    onClick = action,
  })
end

local function header()
  local children = {
    ui.label({
      text = short(s.title, 30),
      color = "on_surface",
      maxLines = 1,
      fontSize = 15,
      fontWeight = "bold",
    }),
    ui.spacer({}),
    ui.button({
      text = quality_label(),
      variant = "ghost",
      controlSize = "sm",
      tooltip = "Качество звука",
      onClick = "ym_quality",
    }),
    icon_button("x", "Закрыть", "hidePanel"),
  }
  return ui.row({ gap = 6, align = "center" }, children)
end

-- Обложка + артист: один блок, чтобы текст не «прыгал» при появлении картинки.
local function track_block()
  local cover = cover_block()
  local artist = ui.label({
    text = short(s.artist ~= "" and s.artist or "—", 46),
    color = "on_surface_variant",
    maxLines = 1,
    fontSize = 12,
  })

  if cover then
    return ui.row({ gap = 10, align = "center" }, { cover, artist })
  end
  return artist
end

local function progress_block()
  if s.duration <= 0 then
    return ui.progress({ progress = 0, height = 2, fill = "primary", track = "outline/0.4" })
  end
  return ui.column({ gap = 2 }, {
    ui.progress({
      progress = progress(),
      height = 2,
      fill = "primary",
      track = "outline/0.4",
    }),
    ui.row({ justify = "space_between" }, {
      ui.label({ text = fmt_time(s.position), color = "on_surface_variant", fontSize = 10 }),
      ui.label({ text = fmt_time(s.duration), color = "on_surface_variant", fontSize = 10 }),
    }),
  })
end

local function transport()
  local repeat_glyph = ({
    off = "repeat-off",
    all = "repeat",
    one = "repeat-once",
  })[s.loop_mode] or "repeat"
  local repeat_tip = ({
    off = "Повтор выключен",
    all = "Повтор: вся очередь",
    one = "Повтор: один трек",
  })[s.loop_mode] or "Повтор"

  return ui.row({ gap = 2, align = "center" }, {
    icon_button("player-track-prev", "Предыдущий трек", "prev"),
    icon_button(
      s.status == "playing" and "player-pause" or "player-play",
      s.status == "playing" and "Пауза" or "Играть",
      "toggle",
      "primary"
    ),
    icon_button("player-track-next", "Следующий трек", "next"),
    ui.spacer({}),
    icon_button(
      s.liked and "heart-filled" or "heart",
      s.liked and "Убрать из любимых" or "В любимые",
      "like",
      "ghost",
      s.liked
    ),
    icon_button(repeat_glyph, repeat_tip, "ym_repeat", "ghost", s.loop_mode ~= "off"),
    icon_button(
      "arrows-shuffle",
      s.shuffle and "Перемешивание включено" or "Перемешивание выключено",
      "ym_shuffle",
      "ghost",
      s.shuffle
    ),
    ui.button({
      text = "Волна",
      glyph = "wave-sine",
      variant = "ghost",
      controlSize = "sm",
      tooltip = "Моя волна",
      onClick = "ym_wave",
    }),
  })
end

local function section_title(text)
  return ui.label({ text = text, color = "on_surface_variant", fontSize = 11 })
end

local function results_block()
  if s.query == "" then
    return nil
  end
  if #s.results == 0 then
    return ui.label({
      text = "Ничего не найдено",
      color = "on_surface_variant",
      fontSize = 12,
    })
  end

  local rows = { section_title("Найдено · " .. #s.results) }
  for index, item in ipairs(s.results) do
    rows[#rows + 1] = ui.button({
      text = track_line(item),
      variant = "ghost",
      controlSize = "sm",
      contentAlign = "start",
      onClick = function()
        play_result(index)
      end,
    })
  end
  return ui.column({ gap = 2 }, rows)
end

local function queue_block()
  if #s.queue == 0 then
    return ui.column({ gap = 2 }, {
      section_title("Очередь"),
      ui.label({ text = "Очередь пуста", color = "on_surface_variant", fontSize = 12 }),
    })
  end

  local rows = { section_title("Очередь · " .. #s.queue) }
  for index, item in ipairs(s.queue) do
    rows[#rows + 1] = ui.button({
      text = string.format("%2d. ", index) .. track_line(item),
      variant = "ghost",
      controlSize = "sm",
      contentAlign = "start",
      onClick = function()
        play_queue(index)
      end,
    })
  end
  return ui.column({ gap = 2 }, rows)
end

local function search_input()
  if ui.input == nil then
    return ui.label({
      text = "Поиск: ymd search <текст>",
      color = "on_surface_variant",
      fontSize = 12,
    })
  end

  return ui.input({
    value = s.query,
    placeholder = "Поиск: трек, артист, альбом",
    onSubmit = "ym_submit",
    submitOnEnter = true,
    multiline = false,
    fontSize = 13,
  })
end

render = function()
  ensure_cover()

  local body = {
    header(),
    track_block(),
    progress_block(),
    transport(),
    search_input(),
  }

  local found = results_block()
  local lists = {}
  if found then
    lists[#lists + 1] = found
  end
  lists[#lists + 1] = queue_block()
  body[#body + 1] = ui.scroll({ flexGrow = 1, gap = 10 }, lists)

  if s.hint ~= "" then
    body[#body + 1] = ui.label({ text = s.hint, color = "on_surface_variant", fontSize = 10 })
  end

  panel.render(ui.column({ flexGrow = 1, gap = 6, padding = 10, fill = "surface", radius = 10 }, body))
end

local function apply(state)
  if type(state) ~= "table" then
    return
  end
  if (state.rev or -1) <= s.rev and state.track == nil then
    return
  end

  s.rev = state.rev or 0
  s.status = state.status or "idle"
  s.position = state.positionMs or 0

  if state.track then
    s.title = state.track.title or "—"
    s.duration = state.track.durationMs or 0
    s.artist = table.concat(state.track.artists or {}, ", ")
    s.liked = state.track.liked == true
    local new_id = tostring(state.track.id or "")
    if new_id ~= s.track_id then
      s.track_id = new_id
      s.cover_path = ""
    end
    s.cover_url = state.track.cover or ""
  end

  local queue = state.queue or {}
  s.queue = queue.items or {}
  s.loop_mode = queue["repeat"] or "all"
  s.shuffle = queue.shuffle == true
  s.quality = state.quality or s.quality
  s.codec = state.codec
end

local function refresh()
  ymd.get("/v1/state", function(state, err)
    if err then
      s.hint = "демон недоступен"
    else
      s.hint = ""
      apply(state)
    end
    render()
  end)
end

-- forward declarations: обработчики ссылаются друг на друга
play_result = function(index)
  local item = s.results[index]
  if not item then
    return
  end
  ymd.cmd_payload("play_track", item, function() refresh() end)
end

play_queue = function(index)
  ymd.cmd_payload("queue_play", { index = index - 1 }, function() refresh() end)
end

function ym_repeat()
  local next_mode = ({ off = "all", all = "one", one = "off" })[s.loop_mode] or "all"
  ymd.cmd_payload("repeat", { value = next_mode }, function() refresh() end)
end

function ym_shuffle()
  ymd.cmd_payload("shuffle", { value = not s.shuffle }, function() refresh() end)
end

function ym_submit(value)
  local text = value
  if type(value) == "table" then
    text = value.text or value.value
  end
  s.query = tostring(text or "")
  if s.query == "" then
    render()
    return
  end
  s.hint = "поиск…"
  render()
  ymd.search(s.query, function(data, err)
    if err then
      s.hint = "поиск: " .. tostring(err)
      s.results = {}
    else
      s.results = (data and data.tracks) or {}
      s.hint = ""
    end
    render()
  end)
end

function update()
  noctalia.setUpdateInterval(2000)
  ensure_cover()
  refresh()
end

function onOpen(context)
  update()
end

function toggle()
  ymd.cmd("toggle", function() refresh() end)
end

function prev()
  ymd.cmd("prev", function() refresh() end)
end

function next()
  ymd.cmd("next", function() refresh() end)
end

function like()
  ymd.cmd("like", function() refresh() end)
end

function hidePanel()
  panel.close()
end

local QUALITY_ORDER = { "lossless", "hq", "nq", "lq" }

function ym_quality()
  local current = s.quality
  local next_quality = QUALITY_ORDER[1]
  for index, value in ipairs(QUALITY_ORDER) do
    if value == current then
      next_quality = QUALITY_ORDER[(index % #QUALITY_ORDER) + 1]
      break
    end
  end
  s.quality = next_quality
  ymd.cmd_payload("quality", { value = next_quality }, function()
    render()
  end)
end

function ym_wave()
  ymd.cmd_payload("wave_start", {}, function() refresh() end)
end
