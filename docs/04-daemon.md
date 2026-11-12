# 04. Демон `ymd`

## Границы

Демон — единственный, кто знает про Яндекс Музыку: токен, эндпоинты, подписи,
медиа, кэш. Плагин видит только `/v1/*`. Демон не знает про Noctalia (кроме
необязательного `open-panel` через `noctalia` CLI — лучше без этого).

## Workspace

~~~text
ymd/
├── crates/
│   ├── ym-api/      # HTTP: заголовки, ретраи, эндпоинты, модели, подписи
│   ├── ym-auth/     # OAuth loopback, libsecret, профили
│   ├── ym-media/    # file-info, encraw, AES-CTR, кэш-файлы
│   ├── ym-player/   # GStreamer, очередь, состояние
│   ├── ym-mpris/    # zbus: MediaPlayer2 + Player
│   ├── ym-env/      # niri IPC, idle, power
│   ├── ymd/         # бинарь: httpd, mpris, wiring
│   └── ymctl/       # CLI (входит в ymd как подкоманды)
└── Cargo.toml
~~~

Переиспользуем наработки из `yandex-music-research/client` (`ym-api`, `ym-auth`,
`ym-media` — уже собираются и покрыты тестами).

~~~toml
[workspace.dependencies]
tokio = { version = "1", features = ["rt-multi-thread", "macros", "time", "signal"] }
reqwest = { version = "0.12", default-features = false, features = ["json", "stream", "rustls-tls"] }
axum = "0.8"                 # локальный HTTP + SSE
zbus = "5"                   # MPRIS
gstreamer = "0.23"
niri-ipc = "25"              # следует версии niri
rusqlite = { version = "0.32", features = ["bundled"] }
keyring = { version = "3", features = ["linux-native"] }
aes = "0.8"; ctr = "0.9"; hmac = "0.12"; sha2 = "0.10"; base64 = "0.22"
tokio-tungstenite = "0.24"   # Ynison
clap = { version = "4", features = ["derive"] }
~~~

## Модули

### `auth`

> **Факт (2026-11-12):** новым приложениям в Яндекс ID не дают доступ к Музыкальному
> API — в свойствах приложения нет раздела «Доступ к API», документация Music API
> удалена. Поэтому основной путь — импорт токена из официального клиента, а не
> OAuth-поток. Реализовано: `ymd auth import --from-official|--token`, `auth status`,
> `auth logout`; хранение — GNOME Keyring (`secret-tool`), файл `0600` как фоллбэк.

OAuth-поток (оставлен на случай, если доступ к API вернут):

1. `ymd auth login` генерирует `state` + `PKCE` `verifier/challenge`.
2. Поднимает `127.0.0.1:<port>/callback` (`tiny_http`), печатает URL, открывает
   браузер (`xdg-open`).
3. Пользователь входит; Яндекс редиректит на loopback с `code`.
4. Обмен `code → access_token + refresh_token`, сохранение в libsecret:
   `service=ymd, user=<login>`.
5. `ymd auth status` / `ymd auth logout`.

> Требуется **свой** OAuth-клиент: `redirect_uri` официального привязан к
> `music-application://desktop` и loopback не примет.
>
> Регистрация проверена по документации 2026-11-12: `response_type=code` и PKCE
> (`S256`) поддерживаются, код живёт 10 минут, при `code_verifier` `client_secret`
> не нужен. Пошаговая инструкция — [`10-oauth-registration.md`](10-oauth-registration.md).
>
> Не подтверждено: доступна ли группа scope `music:*` новым приложениям (документация
> Музыкального API закрыта). Проверяется в свойствах приложения за минуту.

Фоллбэк: `ymd auth import` — вставить URL с `#access_token` (как в текущем
`ymc login`), если свой клиент недоступен.

### `api`

Заголовки (`x-yandex-music-client`, `x-yandex-music-device`, `accept-language`),
ретраи 429/5xx (2 попытки, backoff 300/900 мс), `x-request-id`, типизированные
модели (`Track`, `Album`, `Artist`, `Playlist`, `Liked`). Схемы непубличные —
неизвестные поля игнорируются (`#[serde(default)]`), ошибки валидации — в лог.

### `player`

~~~text
GStreamer: playbin3 (uri = resolved stream url)
  audio-sink = pipewiresink (fallback: autoaudiosink)
  volume    = cubic, 0..1
  about-to-finish → next()
~~~

- Очередь: `VecDeque<Track>` + `index`, `shuffle` (seed), `repeat (off|one|all)`.
- `seek` — `SeekFlags::FLUSH | ACCURATE`; позиция — `query_position` раз в 250 мс
  (только пока играет; наружу — по SSE с троттлингом 1 Гц).
- Ошибки: `error`-сообщение GStreamer → `skip` + `notify` через плагин (`error` в state).
- Фоллбэк без GStreamer-dev: `mpv --no-video` через `Command` (опция `player = "mpv"`).

### `mpris`

`org.mpris.MediaPlayer2.ymd` + `/Player`:

| Свойство | Значение |
|---|---|
| `PlaybackStatus` | `Playing` / `Paused` / `Stopped` |
| `Metadata` | `mpris:trackid`, `xesam:title`, `xesam:artist`, `xesam:album`, `mpris:length`, `mpris:artUrl` |
| `Position` | мкс, из `player` |
| `Volume` | 0..1 |
| `CanSeek/CanGoNext/CanGoPrevious` | `true` |

Методы: `Play`, `Pause`, `PlayPause`, `Stop`, `Next`, `Previous`, `Seek`, `SetPosition`,
`Set`(`Volume`). Сигнал `Seeked`.

Практический эффект: **встроенный виджет `media` Noctalia, медиа-клавиши, GNOME-шелл
и lockscreen работают без нашего плагина.** Наш виджет — надстройка с
яндекс-спецификой (лайк, волна, офлайн).

### `cache`

`~/.local/share/ymd/cache/` + SQLite:

~~~sql
CREATE TABLE track (id INTEGER PRIMARY KEY, title TEXT, artists TEXT,
                    album_id INTEGER, duration_ms INTEGER, updated_at INTEGER);
CREATE TABLE file  (track_id INTEGER, quality TEXT, path TEXT,
                    bytes INTEGER, key BLOB, etag TEXT, complete INTEGER,
                    PRIMARY KEY (track_id, quality));
CREATE TABLE queue_state (id INTEGER PRIMARY KEY CHECK (id = 1),
                          payload TEXT, updated_at INTEGER);
~~~

- Загрузка: `encraw` чанками (`Range`), расшифровка AES-128-CTR
  (counter = `offset/16`, `skip = offset%16`), запись `.part` → rename.
- LRU: лимит `cache_limit_gb` (по умолчанию 5), вытеснение по `last_played`.
- Проверка целостности: размер + `sha256` из `file-info` (если отдан).

### `ynison`

Опционально (`ynison = false` по умолчанию): WebSocket-подписка на состояние
аккаунта, `PutYnisonState` при локальных изменениях, `Device-Id` = `uuid` из
конфига. Не блокирует основной путь: без него плеер полностью работоспособен.

### `env`

- niri: подключение к `$NIRI_SOCKET`, `Request::EventStream`; отслеживаем
  `WorkspaceActivated`, `WindowFocusChanged`, `WindowOpenedOrChanged` (fullscreen).
  Кратковременный разрыв сокета — реконнект 1 с.
- Idle: `ext-idle-notify-v1` через `noctalia` не нужен демону — берём из
  `logind` (`IdleHint`) или оставляем плагину.
- Power: `UPower` `OnBattery` → `compact`.
- Результат: `env{fullscreen, overview, idle, onBattery}` в `/v1/state` и правило
  `ui.mode` (`03`).

## Конфигурация

`~/.config/ymd/config.toml`:

~~~toml
[http]
port = 8765            # 0 = только UNIX-socket
bind = "127.0.0.1"

[player]
backend = "gstreamer"  # gstreamer | mpv
quality = "hq"         # lossless | hq | nq | lq
crossfade_ms = 0       # 0 = выключено

[cache]
enabled = true
limit_gb = 5
dir = "~/.local/share/ymd/cache"

[env]
follow_niri = true
idle_minutes = 10
compact_on_battery = true

[ynison]
enabled = false
~~~

## systemd (user)

~~~ini
[Unit]
Description=Yandex Music daemon
After=network-online.target
PartOf=graphical-session.target

[Service]
ExecStart=%h/.local/bin/ymd serve
Restart=on-failure
RestartSec=1
Environment=RUST_LOG=ymd=info

[Install]
WantedBy=graphical-session.target
~~~

`ymd serve` пишет `$XDG_RUNTIME_DIR/ymd/session.key` (`0600`) при старте; плагин
читает его для `X-YMD-Session`.

## CLI

| Команда | Смысл |
|---|---|
| `ymd auth login` / `status` / `logout` | авторизация |
| `ymd play <id\|url>`, `pause`, `toggle`, `next`, `prev` | управление |
| `ymd status --json` | снимок состояния (для скриптов и отладки) |
| `ymd search "…"` | поиск в терминале |
| `ymd download <trackId>` | офлайн |
| `ymd serve` | запуск демона (для systemd) |
| `ymd doctor` | проверки: keyring, GStreamer, niri socket, API, токен |

`ymd doctor` — важный инструмент поддержки: печатает таблицу «что работает / что нет»
без секретов.


## M2: собственный плеер

| Модуль | Что делает |
|---|---|
| `player.rs` | `playbin3` → autoaudiosink (PipeWire): `load/play/pause/toggle/stop`, `seek_ms`, `position_ms`, `duration_ms`, `set_volume`, `poll_eos` |
| `mpris_server.rs` | исходящий MPRIS (`org.mpris.MediaPlayer2` + `.Player`) через zbus 5 |

Цепочка `play_track`: плагин → `POST /v1/cmd` → `command_async` резолвит URL
через `api::stream` → `command` кладёт трек в очередь и грузит URL в плеер.
Тикер раз в секунду берёт позицию у плеера, на EOS зовёт `next`
(с резолвом следующего трека). MPRIS публикуется отдельной задачей; соединение
удерживается живым, иначе шина отпускает имя.

Проверено: `playerctl --player=ymd metadata` отдаёт трек, `play-pause` работает,
медиа-клавиши и виджет `media` получают состояние.

Очередь: `play_track` не дублирует трек, а переключается на существующий;
`repeat` (`off|all|one`), `shuffle`, `queue_remove`. После первого запуска
локального плеера внешний MPRIS больше не подменяет состояние (флаг `owned`).

## M1: источник состояния

| Модуль | Что делает | Статус |
|---|---|---|
| `api.rs` | HTTP-клиент API: `search`, `track`, `album`, `artist`, `playlists`, `likes`, `stream`; ретраи и толерантный разбор (`result` опционален) | готов |
| `media.rs` | HMAC-подпись `file-info`/`lyrics`, `secretKey` по платформам | готов (для `encraw`) |
| `mpris.rs` | чтение состояния и командование внешним MPRIS-плеером через `playerctl` | готов (временный источник) |

Порядок выбора источника в тикере (1 Гц):

1. есть MPRIS-плеер → состояние берётся у него, команды идут в `playerctl`;
2. плеера нет → работает встроенная симуляция (`state.rs`).

Прямой поток работает (2026-11-12):

- основной путь — `/get-file-info` с парой «`X-Yandex-Music-Client:
  YandexMusicDesktopAppWindows/5.95.0` + ключ `kzqU4XhfCaY6B6JTHODeq5`»;
  ответ — `result.downloadInfo.url`, прямые CDN-ссылки `strm.yandex.net`;
- резерв — `/tracks/{id}/download-info` → XML → `md5`-подпись → `/get-mp3/...`;
- качества: `lossless` → `flac-mp4`, `hq` → `aac-mp4 256`, `nq` → `aac-mp4 192`.

Вход: `ymd auth login` — OAuth Device Flow (`daemon/src/oauth.rs`), без своего
OAuth-приложения. Пользователю показывается канонический адрес
`https://oauth.yandex.ru/device` и 8-символьный код; `ya.ru/device` из ответа API —
короткий редирект на него. Альтернатива — `ymd auth import --from-official`.

`mpris.rs` остаётся источником состояния, пока не поднят собственный плеер (M2).


## M3: офлайн-кэш

| Модуль | Что делает |
|---|---|
| `cache.rs` | скачивание `encraw`, почанковая расшифровка, индекс `index.json` |
| `media::decrypt_chunk` | AES-128-CTR, counter = `offset/16`, skip = `offset%16` |

Поток: `get-file-info(transports=encraw)` → `urls[0]` + `key` (hex) →
`Range: bytes=0-0` для размера → чанки по 1 МиБ → расшифровка → `.part` →
`<id>.<ext>` → запись в `index.json`.

`resolve_url` сначала проверяет кэш: локальный файл отдаётся как `file://…`,
поэтому скачанный трек играет без сети и без токена.

CLI: `ymd download <id> [--quality]`, `ymd cache list|path|remove|info`.

Лимит кэша задаётся в `~/.config/ymd/config.toml` (`[cache] limit_mb`, по
умолчанию 2048) и проверяется после каждой загрузки: самые старые записи
вытесняются по `at`. `ymd download-album <id>` качает альбом целиком, пропуская
уже скачанное; `/v1/search` помечает треки полем `cached`.

Ограничения: докачка после обрыва начинается с нуля (`.part` перезаписывается).


## M4: «Моя волна»

| Модуль | Что делает |
|---|---|
| `api::wave_start` | `POST /rotor/session/new` → `radioSessionId`, `batchId`, партия треков |
| `api::wave_more` | `POST /rotor/session/{id}/tracks` → следующая партия |
| `api::wave_feedback` | `POST /rotor/session/{id}/feedbacks` (`like`/`dislike`/`skip`/`trackStarted`) |
| `state::WaveInfo` | `sessionId`, `batchId`, `active` — в `/v1/state` как `wave` |

Команды: `wave_start` (заменяет очередь партией радио и запускает первый трек),
`wave_more`, `wave_feedback`, `wave_stop`.

Догрузка автоматическая: когда до конца очереди остаётся один трек, тикер
запускает `wave_more` (флаг `wave_pending` не даёт плодить параллельные запросы).
Треки волны попадают в общую очередь, поэтому `repeat`/`shuffle` и кэш работают
без отдельного кода.

Тонкость: одиночный `POST …/feedback` не отвечает (соединение закрывается),
используется только множественный `/feedbacks` с `{"feedback":[…]}`.
Подробности — `notes/m4-findings.md`.

## Тексты песен (разведка, код не начат)

`GET /tracks/{id}/lyrics?format=TEXT|LRC|RICH_JSON&timeStamp=…&sign=…`

Подпись **не такая**, как у `file-info`: ключ `kzqU4XhfCaY6B6JTHODeq5` (windows),
данные `trackId + timeStamp` без разделителя, base64 без обрезки последнего символа.
Любая другая комбинация даёт `403 Invalid Sign`.

Ответ содержит не текст, а `downloadUrl` (presigned S3) плюс `lyricId`,
`externalLyricId`, `writers`, `major` (например Musixmatch). Сам текст забирается
вторым GET без авторизации; `LRC` — строки вида `[00:19.67] …`, `TEXT` — без таймкодов.

План реализации: `api::lyrics()` (подпись + второй GET), `GET /v1/lyrics?id=`
в демоне (кэш текста в `cache`), `ymd lyrics <id>`, кнопка «Текст» в панели с
подсветкой текущей строки по `positionMs`.

Детали и матрица проверок — `notes/lyrics-findings.md`.


## Качество звука (lossless)

Проверено на аккаунте: `lossless` доступен и отдаётся как **FLAC в MP4**
(`codec=flac-mp4`), `hq` → `aac-mp4 256`, `nq` → `aac-mp4 192`.

Настройка — `~/.config/ymd/config.toml`:

```toml
[playback]
quality = "lossless"   # lossless | hq | nq | lq
fallback_hq = true     # если lossless недоступен — играть в hq

[cache]
limit_mb = 2048
```

`quality` читается при каждом резолве URL, поэтому смена не требует перезапуска
(достаточно поставить следующий трек). Если запрошенное качество недоступно и
`fallback_hq = true`, демон повторяет запрос в `hq` и пишет warn в лог.

Логируется фактический выбор: `stream resolved track=… codec=flac-mp4`.
