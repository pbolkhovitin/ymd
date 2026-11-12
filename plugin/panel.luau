-- panel.luau — панель плеера: «сейчас играет», транспорт, поиск, очередь.
--
-- Принципы: без анимаций, цвета только из палитры (роли), списки ограничены
-- 4 элементами (панель не скроллится в P0-варианте).

local ymd = require("./lib/ymd.luau")

local MAX_ROWS = 4

local s = {
  rev = -1,
  status = "off",
  title = "—",
  artist = "",
  position = 0,
  duration = 0,
  query = "",
  results = {},
  queue = {},
  repeat = "all",
  shuffle = false,
  hint = "",
}

local function progress()
  if s.duration <= 0 then
    return 0
  end
  return math.min(1, s.position / s.duration)
end

local function short(text, limit)
  local value = tostring(text or "")
  if #value > limit then
    return value:sub(1, limit - 1) .. "…"
  end
  return value
end

local function track_line(item)
  local artist = (item.artists and item.artists[1]) or ""
  if artist ~= "" then
    return short(item.title, 28) .. " · " .. short(artist, 18)
  end
  return short(item.title, 46)
end

local function header()
  return ui.row({ gap = 8, align = "center" }, {
    ui.label({
      text = s.status == "playing" and "▶" or "❚❚",
      color = "primary",
      fontSize = 12,
    }),
    ui.label({
      text = short(s.title, 30),
      color = "on_surface",
      maxLines = 1,
      fontSize = 14,
    }),
    ui.spacer({}),
    ui.label({ text = s.status, color = "on_surface_variant", fontSize = 11 }),
  })
end

local function artist_row()
  local line = s.artist
  if line == "" then
    line = "—"
  end
  return ui.label({
    text = short(line, 46),
    color = "on_surface_variant",
    maxLines = 1,
    fontSize = 12,
  })
end

local function transport()
  return ui.row({ gap = 6 }, {
    ui.button({ text = "◀", variant = "secondary", onClick = "prev" }),
    ui.button({
      text = s.status == "playing" and "❚❚" or "▶",
      variant = "primary",
      onClick = "toggle",
    }),
    ui.button({ text = "▶❚", variant = "secondary", onClick = "next" }),
    ui.button({ text = "♥", variant = "ghost", onClick = "like" }),
    ui.spacer({}),
    ui.button({ text = "×", variant = "ghost", onClick = "hidePanel" }),
  })
end

local function results_block()
  local rows = {}
  for index, item in ipairs(s.results) do
    if index > MAX_ROWS then
      break
    end
    rows[#rows + 1] = ui.button({
      text = track_line(item),
      variant = "ghost",
      onClick = "ym_play_" .. index,
    })
  end

  if #rows == 0 then
    rows[1] = ui.label({
      text = s.query == "" and "Введите запрос в поле выше" or "Ничего не найдено",
      color = "on_surface_variant",
      fontSize = 12,
    })
  end

  return ui.column({ gap = 2 }, rows)
end

local function queue_block()
  local rows = {}
  for index, item in ipairs(s.queue) do
    if index > MAX_ROWS then
      break
    end
    rows[#rows + 1] = ui.button({
      text = tostring(index) .. ". " .. track_line(item),
      variant = "ghost",
      onClick = "ym_queue_" .. index,
    })
  end

  if #rows == 0 then
    rows[1] = ui.label({
      text = "Очередь пуста",
      color = "on_surface_variant",
      fontSize = 12,
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
    placeholder = "Поиск",
    onSubmit = "ym_submit",
    submitOnEnter = true,
    multiline = false,
  })
end

local function mode_row()
  local repeat_text = ({ off = "Повтор: выкл", all = "Повтор: все", one = "Повтор: один" })[s.repeat]
    or "Повтор: все"
  local shuffle_text = s.shuffle and "Перемешать: вкл" or "Перемешать: выкл"

  return ui.row({ gap = 6 }, {
    ui.button({ text = repeat_text, onClick = "ym_repeat", width = 130 }),
    ui.button({ text = shuffle_text, onClick = "ym_shuffle", width = 140 }),
  })
end

local function render()
  panel.render(ui.column({ gap = 8, padding = 12, fill = "surface", radius = 10 }, {
    header(),
    artist_row(),
    ui.progress({
      progress = progress(),
      height = 2,
      fill = "primary",
      track = "surface_variant",
    }),
    transport(),
    mode_row(),
    ui.separator({}),
    search_input(),
    results_block(),
    ui.separator({}),
    ui.label({ text = "Очередь", color = "on_surface_variant", fontSize = 11 }),
    queue_block(),
    ui.label({ text = s.hint, color = "on_surface_variant", fontSize = 10 }),
  }))
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
  end

  local queue = state.queue or {}
  s.queue = queue.items or {}
  s.repeat = queue.repeat or "all"
  s.shuffle = queue.shuffle == true
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

-- ui.button.onClick принимает только имя глобальной функции, поэтому обработчики
-- объявлены явно. MAX_ROWS совпадает с их количеством.
local function play_result(index)
  local item = s.results[index]
  if not item then
    return
  end
  ymd.cmd_payload("play_track", item, function() refresh() end)
end

local function play_queue(index)
  ymd.cmd_payload("queue_play", { index = index - 1 }, function() refresh() end)
end

function ym_play_1() play_result(1) end
function ym_play_2() play_result(2) end
function ym_play_3() play_result(3) end
function ym_play_4() play_result(4) end

function ym_queue_1() play_queue(1) end
function ym_queue_2() play_queue(2) end
function ym_queue_3() play_queue(3) end
function ym_queue_4() play_queue(4) end

function ym_repeat()
  local next_mode = ({ off = "all", all = "one", one = "off" })[s.repeat] or "all"
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
  ymd.search(s.query, function(data, err)
    if err then
      s.hint = "поиск: " .. tostring(err)
      s.results = {}
    else
      s.results = (data and data.tracks) or {}
      s.hint = string.format("найдено: %d", #s.results)
    end
    render()
  end)
end

function update()
  noctalia.setUpdateInterval(2000)
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
  noctalia.togglePanel("pbolkhovitin/yandex-music:panel")
end
