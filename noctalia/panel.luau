-- panel.luau — панель плеера и навигация по библиотеке.
--
-- Принципы: без анимаций, цвета только из ролей палитры, иконки — tabler
-- (ui.button.glyph), списки живут в ui.scroll и не вылезают за панель.
-- Клавиатурного фокуса у панели нет: всё управление мышью.

local ymd = require("./lib/ymd.luau")

-- бюджет символов для одной строки списка: ширина панели ~396 px,
-- моноширинный шрифт 12 px ≈ 7 px/символ
local TITLE_BUDGET = 30
local ARTIST_BUDGET = 18
local ROW_BUDGET = 46

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
  -- навигация
  view = "now",
  prev = nil,
  loading = false,
  error = "",
  home = nil,
  groups = nil,
  group = nil,
  genres = nil,
  tag = nil,
  list = nil,
  account = nil,
  account_err = "",
  auth = nil,
  cache = nil,
}

-- ui.image принимает ТОЛЬКО локальный путь (проп `path`), поэтому обложку
-- скачиваем в pluginDataDir и рисуем файлом.
-- forward declarations: обработчики ссылаются друг на друга
local render
local open_playlist, open_album, open_tag, open_home, open_genres, open_favorites
local start_auth, poll_auth
local refresh, refresh_account, play_list, cache_line

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

local function artists_of(item)
  local list = item.artists or {}
  return table.concat(list, ", ")
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

-- Строка списка: текст слева, без «прыгающего» центра.
local function row_button(text, action, glyph)
  return ui.button({
    text = text,
    glyph = glyph,
    variant = "ghost",
    controlSize = "sm",
    contentAlign = "start",
    onClick = action,
  })
end

local function section_title(text)
  return ui.label({ text = text, color = "on_surface_variant", fontSize = 11 })
end

local function muted(text, size)
  return ui.label({
    text = text,
    color = "on_surface_variant",
    fontSize = size or 12,
    maxLines = 2,
  })
end

local function retry_row(action)
  return ui.button({
    text = "Повторить",
    glyph = "refresh",
    variant = "secondary",
    controlSize = "sm",
    onClick = action,
  })
end

-- ── шапка и транспорт ─────────────────────────────────────────────────────

local VIEW_TITLES = {
  now = nil,
  home = "Главная",
  genres = "Жанры и настроения",
  tag = nil,
  tag_group = nil,
  list = nil,
  auth = "Вход в аккаунт",
  settings = "Настройки",
}

-- Заголовок панели: у списков и подборок — их собственное название,
-- у «Сейчас» — трек, у остальных видов — название вида.
local function view_title()
  if s.view == "now" then
    return s.title
  end
  if s.view == "tag" then
    local tag = s.tag or {}
    return tag.title or tag.tag or "Подборка"
  end
  if s.view == "tag_group" then
    local group = s.group or {}
    return group.title or "Подборка"
  end
  if s.view == "list" then
    local list = s.list or {}
    return list.title or VIEW_TITLES[s.view] or s.title
  end
  return VIEW_TITLES[s.view] or s.title
end

local function header()
  local title = view_title() or "Яндекс Музыка"
  local children = {
    ui.label({
      text = short(title, 30),
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
    icon_button("settings", "Настройки", "ym_settings"),
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
    icon_button(repeat_glyph, repeat_tip, "ym_repeat"),
    icon_button(
      "arrows-shuffle",
      s.shuffle and "Перемешивание включено" or "Перемешивание выключено",
      "ym_shuffle"
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

-- ── навигация ─────────────────────────────────────────────────────────────

local NAV = {
  { view = "now", text = "Сейчас" },
  { view = "home", text = "Обзор" },
  { view = "genres", text = "Жанры" },
  { view = "favorites", text = "Любимое" },
}

local function nav()
  local buttons = {}
  for _, item in ipairs(NAV) do
    buttons[#buttons + 1] = ui.button({
      text = item.text,
      variant = "ghost",
      controlSize = "sm",
      width = 112,
      selected = s.view == item.view,
      onClick = function()
        if item.view == "now" then
          s.view = "now"
          s.prev = nil
          render()
        elseif item.view == "home" then
          open_home()
        elseif item.view == "genres" then
          open_genres()
        else
          open_favorites()
        end
      end,
    })
  end
  return ui.row({ gap = 2, justify = "space_between" }, buttons)
end

local function back_row(target)
  return ui.button({
    text = "← Назад",
    variant = "ghost",
    controlSize = "sm",
    contentAlign = "start",
    onClick = function()
      s.view = target or "home"
      s.prev = nil
      render()
    end,
  })
end

-- ── «сейчас играет» ───────────────────────────────────────────────────────

local function queue_block()
  if #s.queue == 0 then
    return ui.column({ gap = 2 }, {
      section_title("Очередь"),
      muted("Очередь пуста"),
    })
  end

  local rows = { section_title("Очередь · " .. #s.queue) }
  for index, item in ipairs(s.queue) do
    rows[#rows + 1] = row_button(
      string.format("%2d. ", index) .. track_line(item),
      function()
        ymd.cmd_payload("queue_play", { index = index - 1 }, function() refresh() end)
      end
    )
  end
  return ui.column({ gap = 2 }, rows)
end

-- ── поиск ─────────────────────────────────────────────────────────────────

local function results_block()
  if s.query == "" then
    return nil
  end
  if #s.results == 0 then
    return muted("Ничего не найдено")
  end

  local rows = { section_title("Найдено · " .. #s.results) }
  for index, item in ipairs(s.results) do
    rows[#rows + 1] = row_button(track_line(item), function()
      ymd.cmd_payload("play_track", item, function() refresh() end)
    end)
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

local function now_content()
  local items = {}
  local found = results_block()
  if found then
    items[#items + 1] = found
  end
  items[#items + 1] = queue_block()
  return items
end

-- ── главная ───────────────────────────────────────────────────────────────

local function home_item_row(item)
  local kind = item.kind or "track"
  local text, glyph
  if kind == "playlist" then
    local count = item.trackCount and (", " .. item.trackCount .. " тр.") or ""
    text = short(item.title or "Плейлист", 28) .. count
    glyph = "playlist"
  elseif kind == "album" then
    text = short(item.title or "Альбом", 26) .. " · " .. short(item.subtitle or "", 14)
    glyph = "disc"
  else
    text = track_line(item)
  end

  return row_button(text, function()
    if kind == "playlist" and item.uid and item.playlistKind then
      open_playlist(item.uid, item.playlistKind, item.title)
    elseif kind == "album" and item.id then
      open_album(item.id, item.title)
    else
      ymd.cmd_payload("play_track", item, function() refresh() end)
    end
  end, glyph)
end

local function home_content()
  local items = { search_input() }
  if s.loading and not s.home then
    items[#items + 1] = muted("Загрузка главной…")
    return items
  end
  if s.error ~= "" and not s.home then
    items[#items + 1] = muted(s.error)
    items[#items + 1] = retry_row(function() open_home(true) end)
    return items
  end
  if not s.home then
    items[#items + 1] = muted("Главная не загружена")
    items[#items + 1] = retry_row(function() open_home(true) end)
    return items
  end

  for _, block in ipairs(s.home or {}) do
    local rows = { section_title(block.title or "") }
    for _, item in ipairs(block.items or {}) do
      rows[#rows + 1] = home_item_row(item)
    end
    items[#items + 1] = ui.column({ gap = 2 }, rows)
  end
  return items
end

-- ── жанры и настроения ────────────────────────────────────────────────────

local function genres_content()
  local items = {}
  if s.loading then
    items[#items + 1] = muted("Загрузка…")
    return items
  end
  if s.error ~= "" then
    items[#items + 1] = muted(s.error)
    items[#items + 1] = retry_row(function() open_genres(true) end)
    return items
  end

  local groups = s.groups or {}
  for _, group in ipairs(groups) do
    local tags = group.tags or {}
    if #tags > 0 then
      local rows = { section_title(group.title or group.id or "Подборки") }
      for _, tag in ipairs(tags) do
        local title = tag.title or tag.tag or "?"
        local children = tag.children or {}
        if #children > 0 then
          rows[#rows + 1] = row_button(short(title, 30) .. " · " .. #children, function()
            s.view = "tag_group"
            s.group = { title = title, children = children }
            render()
          end)
        else
          rows[#rows + 1] = row_button(short(title, 30), function()
            open_tag(tag.tag or "", title)
          end)
        end
      end
      items[#items + 1] = ui.column({ gap = 2 }, rows)
    end
  end

  if s.genres and #s.genres > 0 then
    local rows = { section_title("Жанры") }
    for _, genre in ipairs(s.genres) do
      rows[#rows + 1] = row_button(short(genre.title or genre.id or "?", 30), function()
        open_tag("genre:" .. tostring(genre.id), genre.title)
      end)
    end
    items[#items + 1] = ui.column({ gap = 2 }, rows)
  end

  if #items == 0 then
    items[#items + 1] = muted("Пусто: демон не вернул жанры")
  end
  return items
end

local function group_content()
  local group = s.group or {}
  local rows = { back_row("genres"), section_title(group.title or "Подборка") }
  for _, tag in ipairs(group.children or {}) do
    local id = tag.tag or ""
    local title = tag.title or id
    rows[#rows + 1] = row_button(short(title, 34), function()
      open_tag(id, title)
    end)
  end
  if #rows == 2 then
    rows[#rows + 1] = muted("В этой группе нет тегов")
  end
  return { ui.column({ gap = 2 }, rows) }
end

local function tag_content()
  local data = s.tag or {}
  local items = { back_row("genres") }
  if s.loading then
    items[#items + 1] = muted("Загрузка…")
    return items
  end
  if s.error ~= "" then
    items[#items + 1] = muted(s.error)
    items[#items + 1] = retry_row(function()
      open_tag(data.tag or "", data.title)
    end)
    return items
  end

  if data.station then
    items[#items + 1] = ui.button({
      text = "Радио по подборке",
      glyph = "wave-sine",
      variant = "secondary",
      controlSize = "sm",
      onClick = function()
        ymd.radio(data.station, function(_, err)
          if err then
            s.hint = "радио: " .. tostring(err)
            render()
          else
            s.view = "now"
            refresh()
          end
        end)
      end,
    })
  end

  local rows = { section_title("Плейлисты · " .. #(data.playlists or {})) }
  for _, item in ipairs(data.playlists or {}) do
    local count = item.trackCount and (" · " .. item.trackCount) or ""
    rows[#rows + 1] = row_button(short(item.title or "Плейлист", 30) .. count, function()
      open_playlist(item.uid, item.playlistKind, item.title)
    end)
  end
  items[#items + 1] = ui.column({ gap = 2 }, rows)
  return items
end

-- ── списки треков: плейлист, альбом, избранное ────────────────────────────

local function list_content()
  local data = s.list or {}
  local items = { back_row(s.prev or "home") }
  if s.loading then
    items[#items + 1] = muted("Загрузка…")
    return items
  end
  if s.error ~= "" then
    items[#items + 1] = muted(s.error)
    items[#items + 1] = retry_row(function()
      if data.kind == "album" then
        open_album(data.id, data.title)
      elseif data.kind == "favorites" then
        open_favorites(true)
      else
        open_playlist(data.uid, data.playlistKind, data.title)
      end
    end)
    return items
  end

  local tracks = data.tracks or {}
  if data.subtitle and data.subtitle ~= "" then
    items[#items + 1] = muted(short(data.subtitle, 44), 11)
  end
  if #tracks > 0 then
    items[#items + 1] = ui.button({
      text = "Играть все · " .. #tracks,
      glyph = "player-play",
      variant = "secondary",
      controlSize = "sm",
      onClick = function()
        play_list(tracks)
      end,
    })
  end

  local rows = {}
  for index, item in ipairs(tracks) do
    rows[#rows + 1] = row_button(string.format("%2d. ", index) .. track_line(item), function()
      ymd.cmd_payload("play_track", item, function()
        s.view = "now"
        refresh()
      end)
    end)
  end
  if #rows == 0 then
    rows[1] = muted("Здесь нет треков")
  end
  items[#items + 1] = ui.column({ gap = 2 }, rows)
  return items
end

play_list = function(tracks)
  if #tracks == 0 then
    return
  end
  ymd.cmd_payload("queue_set", { tracks = tracks, index = 0 }, function(ok)
    if not ok then
      s.hint = "очередь: не удалось поставить"
      render()
      return
    end
    ymd.cmd("play", function()
      s.view = "now"
      refresh()
    end)
  end)
end

-- ── вход через Device Flow ────────────────────────────────────────────────

local function auth_content()
  local auth = s.auth
  local items = {}

  if auth == nil then
    items[#items + 1] = muted(
      "Вход нужен для главной, избранного и рекомендаций. Демон покажет код, его нужно ввести на странице Яндекса.",
      12
    )
    items[#items + 1] = ui.button({
      text = "Получить код",
      glyph = "player-play",
      variant = "primary",
      controlSize = "sm",
      onClick = function()
        start_auth()
      end,
    })
    items[#items + 1] = back_row("settings")
    return items
  end

  if auth.state == "pending" then
    items[#items + 1] = section_title("Код для входа")
    items[#items + 1] = ui.label({
      text = auth.userCode or "····",
      color = "on_surface",
      fontSize = 22,
      fontWeight = "bold",
    })
    items[#items + 1] = muted("Откройте страницу и введите код. Ожидание подтверждения…", 12)
    items[#items + 1] = ui.row({ gap = 6 }, {
      ui.button({
        text = "Открыть страницу",
        variant = "secondary",
        controlSize = "sm",
        onClick = function()
          if auth.url and auth.url ~= "" then
            noctalia.runAsync({ "xdg-open", auth.url }, function() end)
          end
        end,
      }),
      ui.button({
        text = "Отмена",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          ymd.del("/v1/auth/device", function()
            s.auth = nil
            render()
          end)
        end,
      }),
    })
    return items
  end

  if auth.state == "error" or auth.state == "expired" then
    items[#items + 1] = muted("Не удалось войти: " .. tostring(auth.error or auth.state), 12)
    items[#items + 1] = retry_row(function()
      start_auth()
    end)
    return items
  end

  items[#items + 1] = muted("Статус входа: " .. tostring(auth.state), 12)
  items[#items + 1] = back_row("settings")
  return items
end

-- ── настройки ─────────────────────────────────────────────────────────────

local function settings_content()
  local items = { search_input() }
  local account = s.account
  local rows = { section_title("Аккаунт") }

  if account then
    local plus = account.plus and " · Plus" or ""
    rows[#rows + 1] = ui.row({ gap = 6, align = "center" }, {
      ui.label({
        text = short(account.login or "аккаунт", 24) .. plus,
        color = "on_surface",
        fontSize = 12,
        maxLines = 1,
      }),
      ui.spacer({}),
      ui.button({
        text = "Выйти",
        glyph = "logout",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          ymd.post("/v1/auth/logout", {}, function()
            s.account = nil
            s.home = nil
            s.list = nil
            render()
          end)
        end,
      }),
    })
  else
    rows[#rows + 1] = muted(s.account_err ~= "" and s.account_err or "Вход не выполнен", 12)
    rows[#rows + 1] = ui.button({
      text = "Войти",
      glyph = "login",
      variant = "secondary",
      controlSize = "sm",
      onClick = function()
        s.view = "auth"
        render()
      end,
    })
  end
  items[#items + 1] = ui.column({ gap = 4 }, rows)

  items[#items + 1] = ui.column({ gap = 4 }, {
    section_title("Звук и кэш"),
    ui.row({ gap = 6, align = "center" }, {
      muted("Качество:", 12),
      ui.button({
        text = quality_label(),
        variant = "ghost",
        controlSize = "sm",
        tooltip = "Переключить качество",
        onClick = "ym_quality",
      }),
    }),
    muted(cache_line(), 11),
  })

  items[#items + 1] = muted(
    "Панель не забирает клавиатуру: управление мышью, медиа-клавиши — через MPRIS.",
    10
  )
  return items
end

cache_line = function()
  if not s.cache then
    return "Кэш: нет данных"
  end
  local used = math.floor((tonumber(s.cache.totalBytes) or 0) / (1024 * 1024))
  local limit = math.floor((tonumber(s.cache.limitBytes) or 0) / (1024 * 1024))
  return string.format("Кэш: %d МБ из %d МБ", used, limit)
end

-- ── сборка панели ─────────────────────────────────────────────────────────

local function content_for_view()
  if s.view == "home" then
    return home_content()
  elseif s.view == "genres" then
    return genres_content()
  elseif s.view == "tag_group" then
    return group_content()
  elseif s.view == "tag" then
    return tag_content()
  elseif s.view == "list" then
    return list_content()
  elseif s.view == "auth" then
    return auth_content()
  elseif s.view == "settings" then
    return settings_content()
  end
  return now_content()
end

render = function()
  ensure_cover()

  local body = { header() }

  if s.view == "now" then
    body[#body + 1] = track_block()
    body[#body + 1] = progress_block()
  end

  if s.view ~= "auth" and s.view ~= "settings" then
    body[#body + 1] = transport()
  end
  if s.view ~= "auth" then
    body[#body + 1] = nav()
  end

  if s.hint ~= "" then
    body[#body + 1] = ui.label({ text = s.hint, color = "on_surface_variant", fontSize = 10 })
  end

  -- Скролл — последний ребёнок: только так Noctalia ограничивает его остатком
  -- высоты панели, и список не выдавливает шапку и вкладки.
  body[#body + 1] = ui.scroll({ flexGrow = 1, gap = 8 }, content_for_view())

  panel.render(ui.column({ flexGrow = 1, gap = 6, padding = 10, fill = "surface", radius = 10 }, body))
end

-- ── загрузчики ────────────────────────────────────────────────────────────

local function begin(view)
  s.view = view
  s.loading = true
  s.error = ""
  s.hint = ""
  render()
end

local function fail(message)
  s.loading = false
  s.error = message
  render()
end

open_home = function(force)
  if s.home and not force then
    s.view = "home"
    s.prev = nil
    render()
    return
  end
  begin("home")
  ymd.home(function(data, err)
    s.loading = false
    if err then
      s.error = err == "unauthorized" and "Нужен вход в аккаунт" or ("Главная: " .. tostring(err))
      render()
      return
    end
    s.home = (data and data.blocks) or {}
    s.error = ""
    render()
  end)
end

open_genres = function(force)
  if s.groups and s.genres and not force then
    s.view = "genres"
    s.prev = nil
    render()
    return
  end
  begin("genres")
  ymd.metatags(function(tags, tags_err)
    if tags_err and tags_err ~= "unauthorized" then
      fail("Теги: " .. tostring(tags_err))
      return
    end
    ymd.genres(function(list, genres_err)
      s.loading = false
      if tags_err and genres_err then
        s.error = genres_err == "unauthorized" and "Нужен вход в аккаунт"
          or ("Жанры: " .. tostring(genres_err))
        render()
        return
      end
      s.groups = (tags and tags.groups) or {}
      s.genres = (list and list.genres) or {}
      s.error = ""
      render()
    end)
  end)
end

open_tag = function(tag, title)
  s.tag = { tag = tag, title = title }
  begin("tag")
  ymd.tag(tag, function(data, err)
    s.loading = false
    if err then
      s.error = err == "unauthorized" and "Нужен вход в аккаунт" or ("Подборка: " .. tostring(err))
      render()
      return
    end
    s.tag = data or s.tag
    s.error = ""
    render()
  end)
end

open_playlist = function(uid, kind, title)
  s.list = { kind = "playlist", uid = uid, playlistKind = kind, title = title, tracks = {} }
  s.prev = (s.view == "list") and s.prev or s.view
  begin("list")
  ymd.playlist(uid, kind, function(data, err)
    s.loading = false
    if err then
      s.error = err == "unauthorized" and "Нужен вход в аккаунт" or ("Плейлист: " .. tostring(err))
      render()
      return
    end
    local playlist = (data and data.playlist) or {}
    s.list = {
      kind = "playlist",
      uid = uid,
      playlistKind = kind,
      title = playlist.title or title,
      subtitle = playlist.subtitle,
      tracks = (data and data.tracks) or {},
    }
    s.error = ""
    render()
  end)
end

open_album = function(id, title)
  s.list = { kind = "album", id = id, title = title, tracks = {} }
  s.prev = (s.view == "list") and s.prev or s.view
  begin("list")
  ymd.album(id, function(data, err)
    s.loading = false
    if err then
      s.error = err == "unauthorized" and "Нужен вход в аккаунт" or ("Альбом: " .. tostring(err))
      render()
      return
    end
    local album = (data and data.album) or {}
    s.list = {
      kind = "album",
      id = id,
      title = album.title or title,
      subtitle = table.concat(album.artists or {}, ", "),
      tracks = (data and data.tracks) or {},
    }
    s.error = ""
    render()
  end)
end

open_favorites = function(force)
  if s.list and s.list.kind == "favorites" and not force then
    s.view = "list"
    render()
    return
  end
  s.list = { kind = "favorites", title = "Мне нравится", tracks = {} }
  s.prev = "now"
  begin("list")
  ymd.favorites(function(data, err)
    s.loading = false
    if err then
      s.error = err == "unauthorized" and "Нужен вход в аккаунт" or ("Избранное: " .. tostring(err))
      render()
      return
    end
    local playlist = (data and data.playlist) or {}
    s.list = {
      kind = "favorites",
      title = playlist.title or "Мне нравится",
      subtitle = playlist.subtitle,
      tracks = (data and data.tracks) or {},
    }
    s.error = ""
    render()
  end)
end

start_auth = function()
  s.auth = nil
  s.view = "auth"
  s.hint = "запрос кода…"
  render()
  ymd.post("/v1/auth/device", {}, function(data, err)
    s.hint = ""
    if err then
      s.auth = { state = "error", error = tostring(err) }
    else
      s.auth = data or { state = "error", error = "пустой ответ" }
    end
    render()
    poll_auth()
  end)
end

poll_auth = function()
  if not s.auth or s.auth.state ~= "pending" then
    return
  end
  -- панель перерисовывается раз в 2 с через update(); здесь — только опрос статуса
  ymd.get("/v1/auth/device", function(data, err)
    if err then
      return
    end
    if data and data.state and data.state ~= s.auth.state then
      s.auth = data
      if data.state == "authorized" then
        s.hint = ""
        refresh_account(function()
          open_home(true)
        end)
      else
        render()
      end
    end
  end)
end

-- ── состояние плеера ──────────────────────────────────────────────────────

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

refresh = function()
  ymd.get("/v1/state", function(state, err)
    local before = s.rev
    if err then
      s.hint = "демон недоступен"
    else
      s.hint = ""
      apply(state)
    end
    -- На списках перерисовка каждые 2 с сбрасывала бы позицию скролла:
    -- обновляем только «Сейчас» или когда демон реально поменял состояние.
    if s.view == "now" or s.rev ~= before or err ~= nil then
      render()
    end
  end)
end

refresh_account = function(then_fn)
  ymd.account(function(data, err)
    if err then
      s.account = nil
      s.account_err = err == "unauthorized" and "Вход не выполнен" or "аккаунт недоступен"
    else
      s.account = data
      s.account_err = ""
    end
    if then_fn then
      then_fn()
    else
      render()
    end
  end)
end

local function refresh_cache()
  ymd.get("/v1/cache", function(data)
    s.cache = data
    if s.view == "settings" then
      render()
    end
  end)
end

-- ── действия ──────────────────────────────────────────────────────────────

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
  s.view = "now"
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

function ym_settings()
  if s.view == "settings" then
    s.view = "now"
    render()
    return
  end
  s.view = "settings"
  render()
  refresh_account()
  refresh_cache()
end

function ym_wave()
  ymd.cmd_payload("wave_start", {}, function() refresh() end)
end

function update()
  noctalia.setUpdateInterval(2000)
  ensure_cover()
  refresh()
  poll_auth()
  if s.view == "settings" then
    refresh_cache()
  end
end

function onOpen(context)
  update()
  refresh_account()
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
  if s.track_id == "" then
    return
  end
  ymd.cmd_payload("like_track", { id = s.track_id, liked = not s.liked }, function() refresh() end)
end

function hidePanel()
  panel.close()
end

-- Переключение раздела из бара/скриптов: `noctalia msg plugin … view home`.
function onIpc(event, payload)
  local target = payload
  if type(payload) == "table" then
    target = payload.view or payload.value
  end
  if event == "view" and type(target) == "string" then
    if target == "home" then
      open_home(true)
    elseif target == "genres" then
      open_genres(true)
    elseif target == "favorites" then
      open_favorites(true)
    elseif target == "settings" then
      s.view = "settings"
      render()
      refresh_account()
      refresh_cache()
    elseif target == "auth" then
      if s.auth == nil then
        start_auth()
      else
        s.view = "auth"
        render()
      end
    else
      s.view = "now"
      render()
    end
    return
  end
  if event == "tag" and type(target) == "string" then
    open_tag(target, target)
    return
  end
  if event == "refresh" then
    refresh()
  end
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
