# 02. Архитектура

## Обзор

~~~text
┌──────────────────────────── KDE Plasma 6 ───────────────────────────────────┐
│  панель ── компактный виджет ──┐                                           │
│  попап ── FullRepresentation ──┼──> QML-плазмоид                            │
│  окно ymd-qt ──────────────────┘                                           │
│  виджет media / медиа-клавиши ──> MPRIS                                    │
│                                          │ HTTP 127.0.0.1:8765             │
└──────────────────────────────────────────┼──────────────────────────────────┘
                                           │ JSON (+ SSE для отладки)
┌──────────────────────────────────────────▼──────────────────────────────────┐
│ ymd (Rust, systemd --user)                                                  │
│  httpd ──┬── state (очередь, команды)                                       │
│          ├── player (GStreamer → PipeWire)                                  │
│          ├── api (Яндекс Музыка, подписи)                                   │
│          ├── cache (encraw + AES-CTR)                                       │
│          ├── auth (OAuth Device Flow + keyring)                             │
│          └── mpris_server (zbus)                                            │
│  MPRIS ── org.mpris.MediaPlayer2.ymd ──> Plasma media widget / shell        │
└──────────────────────────────────────────┬──────────────────────────────────┘
                                           │ HTTPS
                                 api.music.yandex.ru
~~~

## Почему так

| Альтернатива | Вердикт |
|---|---|
| Только QML-плазмоид | Невозможно: нет аудио, AES-CTR, keyring, MPRIS |
| Electron-обёртка | Тяжело, анимации, второе окно |
| **Демон + плазмоид + `ymd-qt`** | Нативный UI панели и отдельное окно; вся тяжёлая работа в Rust |

Плазмоид **никогда** не обращается к API Яндекса и не видит токен. Это и
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
| `main.qml` | `PlasmoidItem`: ключ, polling, команды, поиск |
| `CompactRepresentation.qml` | компакт в панели: иконка, «Трек — Артист», клики/колесо |
| `FullRepresentation.qml` | попап: обложка, seek, громкость, транспорт, режимы, поиск, очередь |
| `TrackRow.qml` | строка трека для результатов и очереди |
| `format.js` | чистые функции: обрезка, время, качество, repeat |

Плазмоид — один QML-пакет; отдельного процесса и второй VM нет.

### Приложение `ymd-qt`

| Файл | Назначение |
|---|---|
| `src/ymdclient.{h,cpp}` | ключ, HTTP/JSON, polling, команды, поиск, 401-retry |
| `src/tray.{h,cpp}` | `KStatusNotifierItem`: окно, play/pause, next/prev, выход |
| `src/main.cpp` | `QApplication`, связка QML ↔ клиент ↔ трей |
| `qml/Main.qml` | окно: обложка, seek, громкость, транспорт, режимы, поиск, очередь |
| `qml/TrackRow.qml` | строка трека |
| `qml/format.js` | копия `plasmoid/contents/ui/format.js` |

Приложение — тонкий клиент: не хранит токен и не обращается к API Яндекса.
Закрытие окна прячет его в трей; воспроизведение остаётся в демоне.

## IPC-контракт

Транспорт: loopback HTTP, порт по умолчанию `8765` (настраивается в плазмоиде).
Аутентификация: capability-файл `$XDG_RUNTIME_DIR/ymd/session.key` (0600).
Плазмоид получает ключ через `ymd session-key`, `ymd-qt` — из файла ключа
или через `ymd session-key`; оба передают его в `X-YMD-Session`.
Демон слушает только `127.0.0.1`; `/v1/health` доступен без ключа.

### Эндпоинты

| Метод | Путь | Назначение |
|---|---|---|
| GET | `/v1/health` | `{ok, version, uptime}` без ключа |
| GET | `/v1/state` | снимок состояния |
| GET | `/v1/search?q=&page=` | поиск, `{query, tracks: [...]}` |
| POST | `/v1/cmd` | `{op, payload}` — команда |
| GET | `/v1/events` | SSE: события состояния (плазмоид не использует) |

### Состояние

~~~json
{
  "rev": 42,
  "status": "playing",
  "track": {
    "id": "12345", "title": "Кино", "artists": ["MACAN"],
    "album": "…", "durationMs": 184000, "liked": true,
    "cover": "https://…"
  },
  "positionMs": 61000,
  "volume": 0.8,
  "queue": {
    "items": [{"id": "…", "title": "…", "artists": ["…"], "durationMs": 184000, "cover": "…"}],
    "length": 32, "index": 3, "shuffle": false, "repeat": "all"
  },
  "wave": {"sessionId": "…", "batchId": "…", "active": true},
  "quality": "lossless",
  "codec": "flac-mp4",
  "env": {"fullscreen": false, "overview": false, "idle": false, "onBattery": false},
  "ui": {"mode": "full"}
}
~~~

`rev` монотонно растёт — плазмоид применяет ответ только при смене `rev`.

### Команды `POST /v1/cmd`

`toggle`, `play`, `pause`, `stop`, `next`, `prev`, `like`, `wave_stop`, `wave`,
`quality{value}`, `mode{value}`, `play_track{...track}`, `enqueue{...track}`,
`queue_play{index}`, `queue_clear`, `queue_remove{index}`, `volume{value}`,
`seek{positionMs}`, `repeat{value}`, `shuffle{value}`.

Асинхронные (резолвят поток через API): `wave_start`, `wave_more`,
`wave_feedback{kind, trackId?}`.

Ответ: `{ok, rev}`. Плазмоид после успешной команды сразу перечитывает
`/v1/state`.

## Потоки

**Play/pause.** Плазмоид → `POST /v1/cmd {op:"toggle"}` → демон меняет
GStreamer → MPRIS `PlaybackStatus` → следующий polling забирает `state`.

**Смена трека.** GStreamer EOS → тикер зовёт `next` → `api::stream` резолвит URL
(или локальный кэш) → `playbin3.set_uri` → MPRIS `Metadata` обновляется.

**Поиск.** Плазмоид → `GET /v1/search?q=…` → демон подписывает запрос и ходит в
API → `{tracks}` → четыре строки в попапе.

**Офлайн.** `ymd download` → `encraw`-чанки → AES-128-CTR → файл + индекс;
`resolve_url` отдаёт `file://` без сети.

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
