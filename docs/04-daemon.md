# 04. Демон `ymd`

## Границы

Демон — единственный, кто знает про Яндекс Музыку: токен, эндпоинты, подписи,
аудиопоток, кэш и MPRIS. Плазмоид видит только локальный HTTP API `/v1/*`
и никогда не обращается к API Яндекса.

```
plasmoid (QML) ──HTTP/JSON──> ymd ──HTTPS──> Яндекс Музыка
      │                         │
      └── ymd session-key       ├── GStreamer → PipeWire
                                ├── MPRIS (zbus)
                                └── ~/.local/share/ymd/cache
```

## Состав workspace

```text
Cargo.toml            workspace, версия 0.2.0
daemon/
  Cargo.toml          бинарь ymd
  src/main.rs         CLI и запуск
  src/httpd.rs        локальный HTTP API
  src/state.rs        состояние, очередь, команды, волна
  src/api.rs          клиент API Яндекса, подписи, поток
  src/auth.rs         импорт токена, keyring/файл
  src/oauth.rs        Device Flow
  src/media.rs        HMAC-подписи, AES-CTR
  src/player.rs       GStreamer playbin3
  src/mpris.rs        внешний MPRIS через playerctl (резерв)
  src/mpris_server.rs исходящий MPRIS через zbus
  src/cache.rs        офлайн-кэш encraw
  src/config.rs       config.toml
  src/session.rs      capability-ключ
  src/doctor.rs       проверка окружения
packaging/            Docker, .deb, systemd unit
plasmoid/             QML-плазмоид Plasma 6
```

## Модули

### `auth` и `oauth`

Основной вход — `ymd auth login`: OAuth Device Flow без собственного
`client_id` (пользователь вводит код на `https://oauth.yandex.ru/device`).
Альтернатива — `ymd auth import --from-official` (токен из Local Storage
официального клиента) или `--token`.

Токен хранится в GNOME Keyring / KWallet через `secret-tool`; если keyring
недоступен — файл `0600` в конфигурационном каталоге. Плазмоид токен не видит.

### `api`

HTTP-клиент с заголовками `x-yandex-music-client`, `x-yandex-music-device`,
`accept-language`; ретраи 429/5xx; толерантный разбор JSON.

Реализовано: `search`, `track`, `album`, `artist`, `playlists`, `likes`,
`stream`, `encraw`, `wave_start`, `wave_more`, `wave_feedback`.

Прямой поток: `/get-file-info` с парой «заголовок клиента + ключ», ответ —
`result.downloadInfo.url` (CDN `strm.yandex.net`). Качества: `lossless` →
`flac-mp4`, `hq` → `aac-mp4 256`, `nq` → `aac-mp4 192`, `lq` → ниже.
Если запрошенное качество недоступно и `fallback_hq = true`, запрос
повторяется в `hq`.

### `player`

GStreamer `playbin3` с `autoaudiosink` (на KDE это PipeWire). Умеет
`load/play/pause/toggle/stop`, `seek_ms`, `position_ms`, `duration_ms`,
`set_volume`, `poll_eos`. Тикер раз в секунду забирает позицию, на EOS
переходит к следующему треку.

Очередь: `Vec<QueueItem>` + `index`, `repeat` (`off|all|one`), `shuffle`.
`play_track` не дублирует трек, а переключается на существующий.
`queue_play`, `queue_remove`, `queue_clear` меняют очередь без перезапуска.

### `mpris_server` и `mpris`

`mpris_server.rs` публикует `org.mpris.MediaPlayer2.ymd` и `/Player` через
zbus: свойства `PlaybackStatus`, `Metadata`, `Position`, `Volume`,
`CanSeek/CanGoNext/CanGoPrevious`, методы `Play/Pause/PlayPause/Stop/Next/
Previous/Seek/SetPosition/Set(Volume)`, сигнал `Seeked`.

`mpris.rs` — резервный источник: если локальный плеер ещё не брал управление,
демон читает состояние и отправляет команды внешнему MPRIS-плееру через
`playerctl`. После первого локального воспроизведения внешний MPRIS больше
не подменяет состояние.

Практический эффект: медиа-клавиши, виджет `media` Plasma и lockscreen
работают без плазмоида.

### `cache`

Каталог `~/.local/share/ymd/cache/`, индекс `index.json`. Загрузка `encraw`
чанками по 1 МиБ, расшифровка AES-128-CTR (`counter = offset/16`,
`skip = offset%16`), запись `.part` → итоговый файл. `resolve_url` сначала
проверяет кэш и отдаёт `file://…`, поэтому скачанный трек играет без сети.

CLI: `ymd download <id>`, `ymd download-album <id>`, `ymd cache list|path|
remove|info`. Лимит `[cache] limit_mb` (по умолчанию 2048) проверяется после
каждой загрузки, старые записи вытесняются по `at`. Докачка после обрыва
пока начинается с нуля.

### `session`

Ключ `$XDG_RUNTIME_DIR/ymd/session.key`, права `0600`, создаётся при
`ymd serve`. Плазмоид получает его командой `ymd session-key` и передаёт
в заголовке `X-YMD-Session`. Без ключа доступен только `/v1/health`.

### `doctor`

`ymd doctor` печатает таблицу проверок: ключ, KDE Plasma/plasmashell,
`playerctl`, `gst-launch-1.0`, `mpv`, `secret-tool`, `curl`, порт 8765.
Подсказки — для apt/Ubuntu. Предупреждение не является ошибкой: без части
пакетов доступны не все возможности.

## Локальный HTTP API

Все эндпоинты, кроме `/v1/health`, требуют заголовок
`X-YMD-Session: <ключ>`.

| Метод | Путь | Назначение |
|---|---|---|
| GET | `/v1/health` | `{ok, version, uptime_s, state_rev}` без ключа |
| GET | `/v1/state` | снимок состояния (camelCase) |
| GET | `/v1/search?q=…&page=…` | `{query, tracks:[…]}` |
| POST | `/v1/cmd` | `{op, payload}` → `{ok, rev}` |
| GET | `/v1/events` | SSE-поток состояний (для отладки) |

### Состояние

`/v1/state` отдаёт:

```json
{
  "rev": 12,
  "status": "playing",
  "track": {
    "id": "123", "title": "…", "artists": ["…"], "album": "…",
    "durationMs": 214000, "liked": false, "cover": "https://…"
  },
  "positionMs": 42000,
  "volume": 0.8,
  "queue": {
    "items": [{"id":"…","title":"…","artists":["…"],"durationMs":0,"cover":null}],
    "length": 1, "index": 0, "shuffle": false, "repeat": "all"
  },
  "env": {"fullscreen": false, "overview": false, "idle": false, "onBattery": false},
  "ui": {"mode": "full"},
  "wave": {"sessionId": "…", "batchId": "…", "active": true},
  "quality": "lossless",
  "codec": "flac-mp4"
}
```

`quality`/`codec` — фактическое качество текущего потока, а не только
значение из конфига. `wave` отсутствует, если волна не запущена.

### Команды

| `op` | `payload` |
|---|---|
| `toggle`, `play`, `pause`, `stop`, `next`, `prev` | — |
| `like` | — |
| `wave_start`, `wave_more`, `wave_feedback`, `wave_stop` | `feedback` для feedback |
| `quality` | `{"value":"lossless|hq|nq|lq"}` |
| `mode` | — (переключает `full`/`compact`) |
| `play_track` | объект трека (`id`, `title`, `artists`, …) |
| `enqueue` | объект трека |
| `queue_play`, `queue_remove` | `{"index":0}` |
| `queue_clear` | — |
| `volume` | `{"value":0.0…1.0}` |
| `seek` | `{"positionMs":42000}` |
| `repeat` | `{"value":"off|all|one"}` |
| `shuffle` | `{"value":true}` |

`wave_start`/`wave_more`/`wave_feedback` — асинхронные: сначала резолвят
радио-сессию, затем меняют очередь.

## Конфигурация

`~/.config/ymd/config.toml` (файл необязателен):

```toml
[playback]
quality = "lossless"   # lossless | hq | nq | lq
fallback_hq = true

[cache]
limit_mb = 2048
```

Смена качества: `ymd quality hq` или команда `quality`; применяется со
следующего трека, конфиг сохраняется.

## CLI

| Команда | Смысл |
|---|---|
| `ymd serve [--port 8765]` | запуск демона |
| `ymd session-key` | напечатать capability-ключ |
| `ymd doctor` | проверка окружения |
| `ymd status [--json]` | снимок состояния |
| `ymd ctl <op>` | отправить команду |
| `ymd search "…" [--json]` | поиск |
| `ymd track <id> [--json]` | метаданные трека |
| `ymd stream <id> [--quality]` | подписанный URL (отладка) |
| `ymd quality [value]` | показать/сменить качество |
| `ymd wave [--json]` | включить «Мою волну» |
| `ymd download <id>`, `download-album <id>` | офлайн-кэш |
| `ymd cache list|path|remove|info` | управление кэшем |
| `ymd auth login|import|status|logout` | авторизация |

## Установка и автозапуск

### .deb

```bash
bash packaging/build-deb.sh --arch arm64   # или amd64
sudo apt install ./dist/ymd_0.2.0_arm64.deb \
                 ./dist/plasma-widget-ymd_0.2.0_all.deb
systemctl --user enable --now ymd.service
```

Пакет `ymd` ставит `/usr/bin/ymd` и unit
`/usr/lib/systemd/user/ymd.service`; `plasma-widget-ymd` — плазмоид в
`/usr/share/plasma/plasmoids/io.github.pbolkhovitin.ymd`.

### Из репозитория

```bash
bash scripts/install-user-service.sh
```

Скрипт собирает release, кладёт бинарь в `~/.local/bin/ymd`, unit — в
`~/.config/systemd/user/ymd.service`, включает и запускает сервис.

Unit: `ExecStart=%h/.local/bin/ymd serve`, `Restart=on-failure`,
`RuntimeDirectory=ymd` (`0700`), `WantedBy=default.target`.

## M1–M4: что уже работает

| Этап | Содержание |
|---|---|
| M1 | поиск, поток, `search/track/album/artist/stream`, вход по токену |
| M2 | GStreamer-плеер, исходящий MPRIS, очередь, обложки, качество |
| M3 | офлайн-кэш `encraw` + AES-CTR, LRU, `download-album` |
| M4 | «Моя волна» с автодогрузкой, `wave_feedback` |

## Тексты песен (запланировано)

Разведка API выполнена: `GET /tracks/{id}/lyrics?format=TEXT|LRC|RICH_JSON`
подписывается иначе, чем `file-info`; ответ содержит `downloadUrl` на S3,
текст забирается вторым GET без авторизации. План: `api::lyrics()`,
`GET /v1/lyrics`, `ymd lyrics`, кнопка «Текст» в попапе. Детали —
`notes/lyrics-findings.md`.

## Безопасность

- Слушает только `127.0.0.1`; ключ — 32 hex-символа, `0600`.
- Плазмоид не хранит токен и не ходит в API Яндекса.
- `ymd doctor` и логи не печатают токен.
- В `.deb` зависимости библиотек разрешены через `dpkg-shlibdeps`.
