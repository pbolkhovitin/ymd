# 02. Архитектура

## Обзор

~~~text
┌───────────────────────────── клиенты ────────────────────────────────────────┐
│ KDE Plasma 6:  панельный виджет, попап (QML), окно ymd-qt (Qt/Kirigami)     │
│ niri+Noctalia: бар-виджет и панель (Luau, plugin_api 35)                    │
│ MPRIS:         медиа-клавиши, виджет media, блокировка                      │
└──────────────────────────────────┬───────────────────────────────────────────┘
                                   │ HTTP 127.0.0.1:8765 (JSON + SSE)
┌──────────────────────────────────▼───────────────────────────────────────────┐
│ ymd (Rust, systemd --user)                                                   │
│  httpd ──┬── state (очередь, команды)                                        │
│          ├── player (GStreamer → PipeWire)                                   │
│          ├── api (Яндекс Музыка, подписи)                                    │
│          ├── cache (encraw + AES-CTR)                                        │
│          ├── auth (OAuth Device Flow + keyring)                              │
│          └── mpris_server (zbus)                                             │
│  MPRIS ── org.mpris.MediaPlayer2.ymd ──> Plasma media widget / shell         │
└──────────────────────────────────┬───────────────────────────────────────────┘
                                   │ HTTPS
                         api.music.yandex.ru
~~~

## Почему так

| Альтернатива | Вердикт |
|---|---|
| Только QML-плазмоид | Невозможно: нет аудио, AES-CTR, keyring, MPRIS |
| Electron-обёртка | Тяжело, анимации, второе окно |
| **Демон + тонкие клиенты** | Нативный UI каждой среды; вся тяжёлая работа в Rust |

Клиенты **никогда** не обращаются к API Яндекса и не видят токен. Это и
безопасность, и ремонтопригодность: API меняется в одном месте.

## Компоненты

### Демон `ymd`

| Модуль | Ответственность | Зависимости |
|---|---|---|
| `auth` | OAuth Device Flow, импорт токена, keyring/файл | `secret-tool`, файл 0600 |
| `api` | HTTP-клиент: заголовки, ретраи, поиск, поток, волна | `reqwest`, `hmac` |
| `player` | GStreamer `playbin3`, seek, громкость | `gstreamer` |
| `state` | состояние, очередь, команды, тикер | `tokio`, `serde` |
| `mpris_server` | `org.mpris.MediaPlayer2` + `Player` | `zbus` |
| `mpris` | чтение внешнего MPRIS через `playerctl` (резерв) | `playerctl` |
| `cache` | файлы `encraw`, AES-128-CTR, индекс, LRU | `aes`, `ctr` |
| `httpd` | локальный HTTP API + SSE | `axum` |
| `session` | capability-ключ `0600`, `ymd session-key` | `std::fs` |
| `doctor` | проверка окружения | CLI |
| `config` | качество, лимит кэша, настройки | `toml` |
| `oauth` | Device Flow | `reqwest` |

Один процесс, один tokio-runtime, состояние в `Arc<RwLock<State>>`.

### Плазмоид `io.github.pbolkhovitin.ymd`

| Файл | Назначение |
|---|---|
| `main.qml` | `PlasmoidItem`: ключ, polling, команды, поиск, плейлисты |
| `CompactRepresentation.qml` | компакт в панели: иконка, «Трек — Артист», клики/колесо |
| `FullRepresentation.qml` | попап: обложка, seek, громкость, транспорт, режимы, поиск, плейлисты, очередь, скачивание |
| `TrackRow.qml` | строка трека для результатов и очереди |
| `format.js` | чистые функции: обрезка, время, качество, repeat, cached-маркер |

Плазмоид — один QML-пакет; отдельного процесса и второй VM нет.

### Приложение `ymd-qt`

| Файл | Назначение |
|---|---|
| `src/ymdclient.{h,cpp}` | ключ, HTTP/JSON, polling, команды, поиск, плейлисты, кэш, 401-retry |
| `src/tray.{h,cpp}` | `KStatusNotifierItem`: окно, play/pause, next/prev, выход |
| `src/main.cpp` | `QApplication`, тема KDE, связка QML ↔ клиент ↔ трей |
| `qml/Main.qml` | окно: обложка, транспорт, поиск, очередь (drag&drop), плейлисты (создание/поиск/удаление), кэш, кодек/битрейт |
| `qml/TrackRow.qml` | строка трека: скачивание, контекстное меню, drag&drop |
| `qml/format.js` | общие функции форматирования, включая размеры кэша |

Приложение — тонкий клиент: не хранит токен и не обращается к API Яндекса.
Закрытие окна прячет его в трей; воспроизведение остаётся в демоне.

### Плагин Noctalia `noctalia/`

| Файл | Назначение |
|---|---|
| `plugin.toml` | манифест: `bar`, `probe`, `bridge`, `panel` |
| `widget.luau` | бар: иконка, «Трек — Артист», клики и колесо |
| `panel.luau` | панель: шапка, обложка, прогресс, транспорт, поиск, очередь |
| `lib/ymd.luau` | ключ из `$XDG_RUNTIME_DIR`, GET, `/v1/cmd`, SSE |
| `bridge.luau` | фоновая SSE-подписка (service) |
| `probe.luau` | диагностика методов `barWidget`/`ui`/`noctalia` |

Плагин — набор Luau-entry в VM хоста; отдельного процесса нет. Пишет только
в `pluginDataDir()` (обложки), не в каталог плагина.

## IPC-контракт

Транспорт: loopback HTTP, порт по умолчанию `8765` (настраивается в плазмоиде).
Аутентификация: capability-файл `$XDG_RUNTIME_DIR/ymd/session.key` (0600).
Плазмоид получает ключ через `ymd session-key`, `ymd-qt` — из файла ключа
или через `ymd session-key`, плагин Noctalia читает файл напрямую; все
передают его в `X-YMD-Session`.
Демон слушает только `127.0.0.1`; `/v1/health` доступен без ключа.

### Эндпоинты

| Метод | Путь | Назначение |
|---|---|---|
| GET | `/v1/health` | `{ok, version, uptime}` без ключа |
| GET | `/v1/state` | снимок состояния |
| GET | `/v1/search?q=&page=` | поиск, `{query, tracks: [...]}` |
| GET | `/v1/playlists` | плейлисты пользователя, `{playlists: [...]}` |
| GET | `/v1/playlist?uid=&kind=` | плейлист и треки, `{playlist, tracks: [...]}` |
| GET | `/v1/album?id=` | альбом и треки (volumes сплющены), `{album, tracks}` |
| GET | `/v1/favorites` | «Мне нравится» (`kind = 3`): `{playlist, tracks}` |
| GET | `/v1/home` | блоки главной: `{blocks: [{id, title, type, items}]}` |
| GET | `/v1/discovery/metatags` | группы подборок: `{groups: [{id, title, tags: [{tag, title, children}]}]}` |
| GET | `/v1/discovery/genres` | жанры и поджанры, `station` для радио |
| GET | `/v1/discovery/tag?tag=` | плейлисты тега + `station` |
| POST | `/v1/radio` | `{station}` — запустить радио (`genre:rock`, `mood:calm`, `artist:42`) |
| GET | `/v1/config` | эффективные настройки демона |
| PATCH | `/v1/config` | `{quality?, fallbackHq?, cacheLimitMb?}` |
| GET | `/v1/account` | `{login, uid, plus, backend, savedAt}` или 401 |
| POST | `/v1/auth/device` | начать вход по Device Flow: `{state, userCode, url, expiresIn}` |
| GET | `/v1/auth/device` | состояние входа (`pending/authorized/expired/…`) |
| DELETE | `/v1/auth/device` | отменить ожидание |
| POST | `/v1/auth/logout` | удалить токен и метаданные аккаунта |
| GET | `/v1/cache` | `{items, totalBytes, limitBytes, dir}` |
| POST | `/v1/cmd` | `{op, payload}` — команда |
| GET | `/v1/events` | SSE: события состояния (использует `bridge.luau`) |

### Состояние

~~~json
{
  "rev": 42,
  "status": "playing",
  "track": {
    "id": "12345", "title": "Кино", "artists": ["MACAN"],
    "album": "…", "durationMs": 184000, "liked": true,
    "cover": "https://…", "cached": false
  },
  "positionMs": 61000,
  "volume": 0.8,
  "queue": {
    "items": [{"id": "…", "title": "…", "artists": ["…"], "albumId": "456", "durationMs": 184000, "liked": false, "cover": "…", "cached": false}],
    "length": 32, "index": 3, "shuffle": false, "repeat": "all"
  },
  "downloads": [
    {"id": "…", "title": "…", "state": "downloading", "bytes": 1048576, "total": 3993120, "error": null}
  ],
  "wave": {"sessionId": "…", "batchId": "…", "active": true},
  "quality": "lossless",
  "codec": "flac-mp4",
  "bitrateKbps": 1411,
  "env": {"fullscreen": false, "overview": false, "idle": false, "onBattery": false},
  "ui": {"mode": "full"}
}
~~~

`rev` монотонно растёт — клиенты применяют ответ только при смене `rev`.

### Команды `POST /v1/cmd`

`toggle`, `play`, `pause`, `stop`, `next`, `prev`, `like`, `wave_stop`, `wave`,
`quality{value}`, `mode{value}`, `play_track{...track}`, `enqueue{...track}`,
`queue_play{index}`, `queue_set{tracks,index,play}`, `queue_clear`,
`queue_remove{index}`, `queue_move{from,to}`, `volume{value}`, `seek{positionMs}`,
`repeat{value}`, `shuffle{value}`, `download_track{track}`, `cache_remove{id}`,
`cache_clear`, `cache_limit{limitMb}`, `playlist_create{title,visibility}`,
`playlist_delete{kind}`, `playlist_add_tracks{kind,tracks}`,
`playlist_remove_track{kind,index}`, `like_track{id,liked}`.

Асинхронные (резолвят поток через API): `wave_start`, `wave_more`,
`wave_feedback{kind, trackId?}`, `download_track` (загрузка идёт в фоне,
прогресс — в `state.downloads`), операции с плейлистами (сначала получают
актуальный `revision`).

Ответ: `{ok, rev}`. Плазмоид после успешной команды сразу перечитывает
`/v1/state`.

## Потоки

**Play/pause.** Плазмоид → `POST /v1/cmd {op:"toggle"}` → демон меняет
GStreamer → MPRIS `PlaybackStatus` → следующий polling забирает `state`.

**Смена трека.** GStreamer EOS → тикер зовёт `next` → `api::stream` резолвит URL
(или локальный кэш) → `playbin3.set_uri` → MPRIS `Metadata` обновляется.

**Поиск.** Плазмоид → `GET /v1/search?q=…` → демон подписывает запрос и ходит в
API → `{tracks}` → четыре строки в попапе.

**Офлайн.** `ymd download` или кнопка `⤓` в UI → `download_track` → `encraw`-чанки
→ AES-128-CTR → файл + индекс; `resolve_url` отдаёт `file://` без сети.
Прогресс виден в `state.downloads`, лимит и LRU — через `cache_limit`.

**Волна.** `wave_start` → `/rotor/session/new` → очередь заменяется партией;
когда до конца остаётся один трек, тикер зовёт `wave_more`.

## Жизненный цикл и отказы

| Ситуация | Поведение |
|---|---|
| Демон не запущен | плазмоид и `ymd-qt`: «Ключ не найден», кнопка «Повторить» |
| Демон упал | `Restart=on-failure`, `RestartSec=2`; клиенты опрашивают снова |
| Нет сети | играет кэш; ошибки — в попапе |
| Токен истёк | `ymd auth login`; плазмоид показывает ошибку ключа/авторизации |
| Нет GStreamer | демон стартует без плеера, состояние доступно |

## Безопасность

- Демон слушает только `127.0.0.1`; ключ `0600`.
- Токен — keyring (`secret-tool`), файл `0600` как фоллбэк; в плазмоид и
  `ymd-qt` не попадает.
- Плазмоид не выполняет `sh -c`; ключ читается argv-вызовом `ymd session-key`.
- Обложки — URL в `Image.source`, без HTML.
