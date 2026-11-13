# P0 — факты проверок

Заполнять по мере прохождения `docs/09-p0-spikes.md`. Только факты, без «должно
работать». Каждая строка — вывод команды или цитата из лога.

## Уже проверено: демон (2026-11-12)

| Проверка | Факт |
|---|---|
| `cargo build -p ymd` | собирается, 28 s, без warning'ов |
| `/v1/health` | `{"ok":true,"state_rev":0,"uptime_s":1,"version":"0.1.0"}` |
| `/v1/state` без `X-YMD-Session` | `401` |
| `/v1/state` с ключом | JSON: `rev/status/track/position_ms/volume/queue/env/ui` |
| `/v1/cmd {"op":"toggle"}` | `{"ok":true,"rev":1}`, статус меняется на `playing` |
| `/v1/events` | `event: state` + `data: {...}` раз в секунду (тик 1 Гц) |
| `ymd status` | читает состояние через loopback-сокет |
| `session.key` | 32 hex-символа, права `0600` |

### Хост и плагин (2026-11-12, Noctalia v5.4.1)

| Проверка | Факт |
|---|---|
| Noctalia | `noctalia v5.4.1` |
| плагин найден | `pbolkhovitin/yandex-music [local] 0.0.1 enabled` |
| лог | `~/.cache/noctalia/noctalia.log` (не journald) |
| `httpStream` | возвращает table-хендл; работает на libcurl |
| SSE-события | `[bridge] rev=1 status=playing title=Demo Track` (раз в секунду) |
| `readFile` вне плагина | ключ из `$XDG_RUNTIME_DIR/ymd/session.key` прочитан |
| `pluginDataDir` | `~/.local/state/noctalia/plugins/data/pbolkhovitin/yandex-music/` |
| `writeFile` | `last_state.json` создан и обновляется |
| демон выключен | `curl=7 Could not connect`, `stream closed: closed`, реконнект через 5 с |

Осталось: S2, S3 (нужен виджет на баре) и S1 (точный максимум `plugin_api`),
S6–S9 (системные проверки).

## Окружение

| Параметр | Значение |
|---|---|
| Дата проверки | 2026-11-12 |
| Noctalia | v5.4.1 |
| `plugin_api` (максимум хоста) | манифест с `35` принимается (см. S1) |
| niri | 26.04 (8ed0da4), сокет `/run/user/1000/niri.wayland-1.3741.sock` |
| PipeWire | через pulse-shim, протокол 35, `pactl` работает |
| GStreamer | 1.28.9 (`gst-launch-1.0`) |
| dev-пакеты | `gstreamer1-devel`, `libsecret-devel`, `gtk4-devel`, `webkit2gtk4.1-devel` — **нет** (`pkg-config` MISSING) |

### S1. Версия и API

~~~text
$ noctalia --version
noctalia v5.4.1
$ noctalia msg plugins list
pbolkhovitin/yandex-music [local] 0.0.1 enabled
~~~

Плагин с `plugin_api = 35` загружается без предупреждений (лог: `loaded plugin 'pbolkhovitin/yandex-music' (4 entries)`).
Все 4 entry-типа (`widget` ×2, `service`, `panel`) зарегистрированы.

## S2. `barWidget.*` — подтверждён

Полный список (12 методов, дамп `[probe] barWidget (12)`):

~~~text
clearTooltip  isVertical  outputName  render
setColor      setFont     setGlyph    setGlyphColor
setImage      setText     setTooltip  setVisible
~~~

Проверка кандидатов (`[probe] barWidget[]`):

| Метод | Есть | Примечание |
|---|---|---|
| `setText` | ✅ function | используется в `widget.luau` |
| `setGlyph` | ✅ function | |
| `setImage` | ✅ function | обложка трека |
| `setIcon` | ❌ nil | нет — использовать `setGlyph`/`setImage` |
| `setTooltip` | ✅ function | |
| `clearTooltip` | ✅ function | |
| `setColor` | ✅ function | принимает роль палитры |
| `setGlyphColor` | ✅ function | |
| `setFont` | ✅ function | |
| `setTextColor` | ❌ nil | цвет текста — только через `setColor` |
| `setProgress` | ❌ nil | прогресс в баре рисовать через `ui.progress` |
| `setWidth` | ❌ nil | ширина — из конфига бара/`ui` |
| `setBadge` | ❌ nil | нет |
| `setVisible` | ✅ function | |
| `setOpacity` | ❌ nil | |

Следствие для дизайна: полоса прогресса в баре — не `setProgress`, а `ui.progress`
внутри виджета (см. S3) либо текстовый индикатор.

## S3. `ui.*` — подтверждён частично

`[probe] ui (21)`:

~~~text
box button colorPicker column dragSource dropZone glyph graph image input
label markdown pixelStream progress row scroll select separator slider
spacer toggle
~~~

| Проверка | Результат |
|---|---|
| `ui.column` в бар-виджете | ✅ `[probe] ui.column in widget = true table` |
| `ui.progress` в баре | не проверено отдельно (метод есть) |
| панель рендерится | ✅ `[panel] panel manager: opened "pbolkhovitin/yandex-music:panel"` |
| `panel.render` | ✅ вызывается из `panel.luau` |
| `[[widget.setting]]` принимается | не проверено (в манифесте секции нет) |

Расширения против документации: `dragSource`, `dropZone`, `pixelStream` — есть в v5.4.1.

## S4. `httpStream` / SSE


| Проверка | Результат |
|---|---|
| формат ответа | `noctalia.httpStream(req, onLine, onClose)` возвращает **table-хендл** |
| как доставляет | построчно, на libcurl; строка `data: {...}` приходит целиком |
| разрыв detected | да — `stream closed: closed` + `[http] stream ended ... curl=7` |
| реконнект | да — `update()` раз в 5 с переподписывается, пока `handle == nil` |
| лимит длительности | не наблюдался (поток жил минутами) |

Рабочий лог:

~~~text
[script-runtime] [bridge] subscribe -> table: 0x00007ff8faced930
[script-runtime] [bridge] rev=1 status=playing title=Demo Track
[script-runtime] [bridge] rev=2 status=playing title=Demo Track
~~~

## S5. `readFile` вне плагина

~~~text
ключ $XDG_RUNTIME_DIR/ymd/session.key прочитан → SSE авторизован (данные пришли)
побочное подтверждение: last_state.json записан в
~/.local/state/noctalia/plugins/data/pbolkhovitin/yandex-music/
~~~

## S6. MPRIS

~~~text
$ playerctl --list-all
firefox.instance_1_331
$ busctl --user list | grep mpris
org.mpris.MediaPlayer2.firefox.instance_1_331
org.mpris.MediaPlayer2.playerctld          (activatable)
$ playerctl -p firefox.instance_1_331 status
Paused
$ playerctl metadata
firefox xesam:title   Пролетая над нами (Трибьют Дениса Майданова)
firefox xesam:artist  тринадцать карат
firefox mpris:artUrl  file:///home/pbolk/.mozilla/firefox/firefox-mpris/30005_43.png
~~~

Вывод: шина MPRIS и `playerctl` на хосте работают; чужой плеер (Firefox) виден.

## S7. GStreamer → PipeWire

~~~text
$ gst-launch-1.0 --version
gst-launch-1.0 version 1.28.9
GStreamer 1.28.9
$ pactl info
Строка сервера: /run/user/1000/pulse/native
Версия протокола сервера: 35
Выполняется локально: да
$ pkg-config --modversion gstreamer-1.0
MISSING
~~~

Вывод: рантайм GStreamer и PipeWire (pulse-shim, протокол 35) есть, **dev-пакеты нет** —
крейт `gstreamer-rs` не соберётся без `sudo dnf install gstreamer1-devel`.
Fallback на P0/M1: `mpv --no-video --ao=pipewire` (mpv установлен), затем миграция на GStreamer.

## S8. niri

| Проверка | Результат |
|---|---|
| `NIRI_SOCKET` | `/run/user/1000/niri.wayland-1.3741.sock` |
| `niri msg --json event-stream` | отдаёт JSON-строки: `WorkspacesChanged`, `WindowsChanged`, `CastsChanged`, `ConfigLoaded`, `KeyboardLayoutsChanged`, `OverviewOpenedOrClosed` |
| `WorkspaceActivated` | событие есть в протоколе; в 4-секундном срезе не появилось (не переключали воркспейс) |
| `WindowFocusChanged` | не наблюдалось; известен баг niri #1889 (open-then-focus не эмитит событие) |
| поле fullscreen | ❌ в `niri msg --json windows` полей: `app_id, focus_timestamp, id, is_floating, is_focused, is_urgent, layout, pid, title, workspace_id` — **`is_fullscreen` нет** |
| `focused-output` | `{"name":"eDP-1", ...}` — работает |

Следствие: полноэкранный режим определять не через niri IPC, а через
`noctalia.focusedOutputName()` + поведение бара (Noctalia сама скрывает бар в fullscreen),
либо косвенно по `niri msg --json layers`.

## S9. OAuth — заменён на импорт токена

Своё приложение в Яндекс ID зарегистрировано, но **раздела «Доступ к API» в свойствах
нет** — значит новые приложения не могут запросить `music:*`, а публичная
документация Музыкального API удалена (404). Loopback-поток с музыкой недоступен.

| Проверка | Результат |
|---|---|
| свой client_id | приложение создано, но без scope `music:*` |
| `response_type=code` + PKCE | поддерживается Яндексом (по документации), но бесполезен без scope |
| импорт токена из официального клиента | ✅ `ymd auth import --from-official` |
| источник | `~/.config/YandexMusic/Local Storage/leveldb/*` — токен `y0_…` открытым текстом |
| валидация | `GET /account/about` → `login=pbolkhovitin`, `uid=12967407`, `hasPlus=true` |
| хранение | GNOME Keyring (`secret-tool`), `backend=keyring`; файл `0600` — фоллбэк |
| доступ к Музыке | ✅ `/search` с токеном: 20 треков |

### Важное различие схемы ответа

| Запрос | Форма |
|---|---|
| `/search` **без** токена | плоский объект (`tracks`, `albums`, …) |
| `/search` **с** токеном | `{"invocationInfo": …, "result": {…}}` |

Клиент должен поддерживать обе формы (уже сделано в `yandex-music-research/client`).

## Решения по итогам

| Вопрос | Решение | Дата |
|---|---|---|
| `plugin_api` | 35 (принимается хостом v5.4.1) | 2026-11-12 |
| `ui.*` в баре | можно (`ui.column` работает); прогресс — `ui.progress`, не `barWidget.setProgress` | 2026-11-12 |
| транспорт состояния | локальный HTTP + SSE, ключ `X-YMD-Session` из `$XDG_RUNTIME_DIR/ymd/session.key` | 2026-11-12 |
| backend плеера | старт на `mpv --no-video --ao=pipewire`, затем GStreamer после установки `gstreamer1-devel` | 2026-11-12 |
| OAuth | отложен до регистрации client_id; временно `ymd auth import` | 2026-11-12 |
| fullscreen | не через niri IPC (поля нет), а через поведение бара Noctalia | 2026-11-12 |

## Что правим в документации

- [x] `docs/design/noctalia.md` — фактический список методов `barWidget`/`ui`.
- [ ] `docs/04-daemon.md` — уточнить поля niri/fullscreen (нет `is_fullscreen`).
- [ ] `docs/07-roadmap.md` — скорректировать оценки (GStreamer заблокирован dev-пакетами).
