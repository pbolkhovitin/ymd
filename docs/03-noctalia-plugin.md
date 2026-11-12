# 03. Плагин Noctalia

## Манифест

~~~toml
id = "pbolkhovitin/yandex-music"
name = "Yandex Music"
version = "0.1.0"
plugin_api = 35          # 24: argv-runAsync, 26: getSetting, 31: getColor, 34: hover_highlight, 35: idle.watch
author = "pbolkhovitin"
license = "MIT"
icon = "music"
description = "Яндекс Музыка в баре: play/pause, трек, панель библиотеки."
tags = ["music", "media", "yandex"]
dependencies = ["ymd"]   # метаданные: демон должен быть установлен

[widget]
id = "bar"
entry = "widget.luau"
hover_highlight = false  # 34: без подсветки всей плашки

[widget.actions]
middle = "none"          # освобождаем СКМ под «лайк»
right = "none"           # правый клик обрабатываем сами (панель)

[widget.setting]
key = "mode"
type = "string"
label_key = "settings.mode"
default = "auto"          # auto | full | compact | dot | hidden

[[widget.setting]]        # заметка: в Noctalia схема — массив блоков
key = "show_artist"
type = "boolean"
default = true

[[panel]]
id = "panel"
entry = "panel.luau"

[[service]]
id = "bridge"
entry = "bridge.luau"
~~~

> Точный синтаксис схемы настроек (массив `[[widget.setting]]` против `[widget.setting]`)
> уточняется в спайке P0 — см. `07-roadmap.md`.

## Entry `bar` — виджет

Правила:

1. **Никаких анимаций.** Нет `setNeedsFrameTick`, нет `onFrameTick`. Обновление —
   `update()` раз в 1 с при воспроизведении и раз в 5 с в паузе.
2. **Ширина ограничена**: `max_width` (по умолчанию 260 px), обрезка — хостом
   (`ui.label.maxWidth/maxLines`) или вручную по глифам, без marquee.
3. **Один акцент**: `primary` только для состояния `playing`; `on_surface` — текст;
   `error` — ошибка.

### Фактический API `barWidget` (проверено, Noctalia v5.4.1)

Доступно ровно 12 методов:

~~~text
clearTooltip  isVertical  outputName  render  setColor  setFont
setGlyph      setGlyphColor  setImage  setText  setTooltip  setVisible
~~~

Чего **нет** (важно для дизайна):

| Нет | Как обойти |
|---|---|
| `setProgress` | `ui.progress` внутри виджета или текстовый индикатор |
| `setWidth` | ширина — из конфига бара / `ui`-дерева |
| `setBadge` | `setText` с префиксом или `ui.row` |
| `setOpacity` | прозрачность — только у `ui.box` |
| `setIcon`, `setTextColor`, `setIconColor` | `setGlyph` + `setColor`/`setGlyphColor` |

~~~lua
-- widget.luau (эскиз; имена barWidget.* подтверждены на v5.4.1)
local s = { status = "idle", title = "", artist = "", liked = false }

local GLYPH = {
  playing = "player-play", paused = "player-pause",
  idle = "music", off = "music-off", error = "alert-triangle",
}

local function text()
  if s.status == "idle" then return "" end
  if s.status == "off"  then return "ymd off" end
  local artist = noctalia.getConfig("show_artist") ~= false and s.artist or nil
  local line = artist and (s.title .. " — " .. artist) or s.title
  local limit = noctalia.getConfig("max_width") or 34
  if #line > limit then line = line:sub(1, limit - 1) .. "…" end
  return line
end

function update()
  noctalia.setUpdateInterval(s.status == "playing" and 1000 or 5000)
  barWidget.setGlyph(GLYPH[s.status] or GLYPH.idle)
  barWidget.setText(text())
end

function onClick()      cmd("toggle") end
function onRightClick() noctalia.togglePanel("pbolkhovitin/yandex-music:panel") end

function onScroll(axis, steps, startsGesture)
  if axis ~= "vertical" or not startsGesture then return end
  cmd(steps < 0 and "prev" or "next")     -- один жест = один шаг
end
~~~

## Entry `bridge` — состояние

Отдельная VM: держит SSE-подписку и раздаёт состояние виджету/панели.

~~~lua
-- bridge.luau (эскиз)
local key  = noctalia.readFile(noctalia.expandPath("$XDG_RUNTIME_DIR/ymd/session.key"))
local BASE = "http://127.0.0.1:8765"

local function subscribe()
  noctalia.httpStream({
    url = BASE .. "/v1/events",
    headers = { "X-YMD-Session: " .. (key or "") },
  }, function(line)
    if line:sub(1, 5) == "data:" then
      local ok, state = pcall(noctalia.json.decode, line:sub(6))
      if ok and state then push(state) end
    end
  end, function() schedule_reconnect() end)
end
~~~

- Реконнект: `update()` раз в 2 с проверяет `/v1/health`, при `ok` — переподписка
  (никаких таймеров-штормов, backoff только при неудачах).
- Состояние дублируется в `noctalia.state` (in-memory) и в
  `pluginDataDir()/last_state.json` — чтобы виджет показал последний трек до
  первого SSE-события (без «мигания пустоты»).

## Entry `panel` — библиотека

Декларативное дерево `ui.*`, один экран, без вкладок-анимаций:

~~~text
┌──────────────────────────────────────────────┐
│ [🔍 поиск…                    ] [Волна] [⚙] │  ui.row
├──────────────────────────────────────────────┤
│ ▶ Кино — MACAN                    3:04  ♥    │  ui.scroll
│ ▶ Кино — ЛСП, GONE.Fludd          3:30  ♥    │
│ …                                            │
├──────────────────────────────────────────────┤
│ ▁▂▃▅▂▁  Кино — MACAN          1:01 / 3:04   │  ui.progress + ui.row
└──────────────────────────────────────────────┘
~~~

- `ui.input` с `submitOnEnter = true` (поиск по Enter, не по каждой букве).
- `ui.scroll` для списка; `ui.select` для качества и типа выдачи.
- `ui.progress` — статичный индикатор (без `marker`-анимации).
- Обложка — `ui.image{path = <локальный файл>, fit = "cover"}`; сетевые URL не
  поддерживаются, поэтому файл сначала скачивается в `pluginDataDir()`
  (`noctalia.download`). В баре — `barWidget.setImage(path)`.
- `repeat` — ключевое слово Luau: JSON-поле читать как `queue["repeat"]`.
- Тексты песен — `ui.label` в скролле; автопрокрутка отсутствует.

## Адаптивность к окружению

| Вход | Источник | Влияние |
|---|---|---|
| Палитра | `noctalia.getColor(role)` | цвета (primary/on_surface/error) |
| Тёмная тема | `noctalia.isDarkMode()` | выбор роли фона, контраст |
| Fullscreen | `env.fullscreen` (niri) | `auto` → `compact` |
| Overview открыт | `env.overview` | `auto` → `hidden` |
| Простой | `noctalia.idle.watch(...)` | `auto` → `hidden` через N мин |
| Батарея | `env.onBattery` | `compact` (меньше текста) |
| Ширина бара | `noctalia.getSetting("bar…")` | лимит символов |
| `mode` пользователя | настройка виджета | приоритет выше `auto` |

Логика `auto` живёт **в демоне** (`env` → `ui.mode`), плагин — исполнитель.
Исключение: `idle.watch` — нативная возможность хоста, дублирует `env.idle`.

## Настройки (черновик)

| Ключ | Тип | По умолчанию | Смысл |
|---|---|---|---|
| `mode` | enum | `auto` | режим виджета |
| `show_artist` | bool | `true` | артист в строке |
| `max_width` | int | `34` | символов до обрезки |
| `show_progress` | bool | `false` | тонкая полоса прогресса |
| `cover_in_panel` | bool | `false` | обложки в панели |
| `notify_track` | bool | `false` | уведомление о смене трека |
| `animations` | bool | `false` | единственный переключатель анимаций |
| `quality` | enum | `hq` | качество стрима |
| `offline_mode` | bool | `false` | играть только из кэша |

## Разработка и отладка

~~~bash
# локальная разработка: path-источник, без git-источника
noctalia msg plugins source add ym-dev path ~/github/ym-noctalia/plugin
noctalia msg plugins enable pbolkhovitin/yandex-music

# правки .luau подхватываются хот-релоадом
# ручной IPC-вызов entry (таргет — focused output)
noctalia msg plugin pbolkhovitin/yandex-music:bar focused refresh

# панель
noctalia msg panel-toggle pbolkhovitin/yandex-music:panel
~~~

Структура репозитория плагина (каталог = часть id после `/`):

~~~text
plugin/
├── plugin.toml
├── widget.luau
├── bridge.luau
├── panel.luau
├── lib/{api.luau,format.luau,theme.luau}
├── translations/en.json, ru.json
├── thumbnail.webp
└── README.md
~~~

## Ограничения, которые надо помнить

1. **Своя VM на каждый entry** — общих глобалов нет.
2. **Бюджеты времени на вызов** — тяжёлую работу нельзя делать в `update()`;
   всё сетевое — асинхронно, результат приходит в callback.
3. **`onMiddleClick` по умолчанию занят** настройками виджета — освобождается
   только явным `middle = "none"`.
4. **Связывания действий побеждают скрипт**: если пользователь назначил `right`,
   `onRightClick` не вызовется.
5. **`plugin_api` — минимум необходимого**: поднимать только при использовании
   новой возможности и заводить `[[plugin.release]]` для старых хостов.
6. **Не писать в `pluginDir()`** — при обновлении из git каталог перезаписывается;
   только `pluginDataDir()`.
