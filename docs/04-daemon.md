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
                                └── ~/.local/share/ymd/media
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
  src/mpris.rs        внешний MPRIS через playerctl (резерв, Linux)
  src/mpris_stub.rs   та же сигнатура для macOS: внешних плееров нет
  src/mpris_server.rs исходящий MPRIS через zbus (Linux)
  src/cache.rs        офлайн-кэш encraw
  src/config.rs       config.toml
  src/session.rs      capability-ключ
  src/doctor.rs       проверка окружения
packaging/            Docker, .deb, .rpm, systemd unit
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

Реализовано: `search`, `track`, `album`, `artist`, `playlists`, `playlist`,
`likes`, `stream`, `encraw`, `wave_start`, `wave_more`, `wave_feedback`,
`create_playlist`, `delete_playlist`, `change_playlist`, `like_track`.

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

Каталог `~/.local/share/ymd/media/`, индекс `index.json`. Загрузка `encraw`
чанками по 1 МиБ, расшифровка AES-128-CTR (`counter = offset/16`,
`skip = offset%16`), запись `.part` → итоговый файл. `resolve_url` сначала
проверяет кэш и отдаёт `file://…`, поэтому скачанный трек играет без сети.

Скачивание доступно из CLI (`ymd download`, `ymd download-album`), из окна
`ymd-qt` (кнопка `⤓`) и командами `download_track`/`download_tracks`.
Загрузки идут строго последовательно: команда только добавляет треки в
очередь и сразу отвечает, воркер качает по одному. Прогресс публикуется в
`state.downloads`, число ожидающих — в `state.downloadPending`, по завершении
обновляется флаг `cached` у трека и очереди. Лимит `[cache] limit_mb` (по умолчанию 2048)
проверяется после каждой загрузки, старые записи вытесняются по `at`;
изменить лимит можно командой `cache_limit`.

Докачка после обрыва работает по умолчанию: частичный файл называется
`<id>.<codec>.<quality>.part`, рядом лежит `<…>.json` с отпечатком ключа
расшифровки и полным размером. При повторном запуске загрузка продолжается
с `Range: bytes=<размер части>-`, если метаданные совпали; иначе файл
пересоздаётся. AES-CTR допускает расшифровку с любого смещения, поэтому
возобновление корректно даже при обрыве посреди чанка.

### `session`

Ключ `$XDG_RUNTIME_DIR/ymd/session.key`, права `0600`, создаётся при
`ymd serve`. Плазмоид получает его командой `ymd session-key` и передаёт
в заголовке `X-YMD-Session`. Без ключа доступен только `/v1/health`.

### `config`, `media`, `httpd`, `state`

| Модуль | Ответственность |
|---|---|
| `config` | чтение `~/.config/ymd/config.toml` (`playback.quality`, `fallback_hq`, `cache.limit_mb`), запись качества из UI |
| `media` | подписи `file-info`/`lyrics`, `direct_link`, AES-128-CTR для `encraw` |
| `httpd` | axum-роутер `/v1/*`, авторизация по capability-ключу, SSE `/v1/events`, нормализация ответов API для клиентов |
| `state` | `State`/`AppState`: очередь, команды, резолв потока, тикер, MPRIS-синхронизация, волна |

### `doctor`

`ymd doctor` печатает таблицу проверок: ключ, KDE Plasma/plasmashell,
`playerctl`, `gst-launch-1.0`, `mpv`, `secret-tool`, `curl`, порт 8765,
путь и размер файла логов, симлинк плагина Noctalia (ловит «висячую» ссылку
после переименования каталога репозитория). Подсказки — для apt/Ubuntu.
Предупреждение не является ошибкой: без части пакетов доступны не все
возможности.

### `logging`

Один `tracing`-подписчик пишет в **stderr (journald)** и в файл
`~/.local/state/ymd/ymd.log`. Файл нужен, когда сервис перезапускался или
событие было ночью: `journalctl --user -u ymd` хранит не всё и неудобен
для поиска.

| Переменная | По умолчанию | Смысл |
|---|---|---|
| `YMD_LOG` | `info` | уровень: `trace`, `debug`, `info`, `warn`, `error`; понимает и `ymd=debug` |
| `RUST_LOG` | — | используется, если `YMD_LOG` не задан |
| `YMD_LOG_DIR` | `$XDG_STATE_HOME/ymd` | каталог лога |
| `YMD_LOG_MAX_MB` | `5` | предел файла до ротации в `ymd.log.1` |

Ротация выполняется при старте демона: переросший файл переименовывается в
`ymd.log.1`, старый `.1` удаляется. Хвост читается без `sudo`:

```bash
ymd logs            # последние 100 строк
ymd logs -n 50      # последние 50
ymd logs -f         # следить за новыми
ymd logs --path     # только путь
```

Что пишется на уровне `info` (специально — для разбора «зациклило трек»):

* `eos -> next` — конец потока: `track`, `index`, `len`, `repeat`, `shuffle`;
* `queue step` — решение по очереди: какой `index` выбран и какой трек в итоге;
* `stream resolved` — `track`, `codec`, `bitrate` (или `play from cache`);
* `player: load <url>` — что реально отдано GStreamer.

Пара `queue step` + `stream resolved` с одинаковым `track` — признак, что
состояние и звук не разъехались. Если `track` в этих строках разный, значит
URL резолвился для другого трека (историческая ошибка `repeat=one`).


## Локальный HTTP API

Все эндпоинты, кроме `/v1/health`, требуют заголовок
`X-YMD-Session: <ключ>`.

| Метод | Путь | Назначение |
|---|---|---|
| GET | `/v1/health` | `{ok, version, uptime_s, state_rev}` без ключа |
| GET | `/v1/state` | снимок состояния (camelCase) |
| GET | `/v1/search?q=…&page=…` | `{query, tracks:[…]}` |
| GET | `/v1/playlists` | `{playlists:[…]}` — плейлисты текущего пользователя |
| GET | `/v1/playlist?uid=…&kind=…` | `{playlist, tracks:[…]}` |
| GET | `/v1/artist?id=…` | `{artist, tracks:[…]}` — карточка и треки исполнителя |
| GET | `/v1/album?id=…` | `{album, tracks:[…]}` — альбом и все треки |
| GET | `/v1/cache` | `{items, totalBytes, limitBytes, dir}` |
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
    "albumId": "456", "durationMs": 214000, "liked": false,
    "cover": "https://…", "cached": false
  },
  "positionMs": 42000,
  "volume": 0.8,
  "queue": {
    "items": [{"id":"…","title":"…","artists":["…"],"albumId":"456","durationMs":0,"liked":false,"cover":null,"cached":false}],
    "length": 1, "index": 0, "shuffle": false, "repeat": "all"
  },
  "downloads": [
    {"id":"…","title":"…","state":"downloading","bytes":1048576,"total":3993120,"error":null}
  ],
  "downloadPending": 12,
  "env": {"fullscreen": false, "overview": false, "idle": false, "onBattery": false},
  "ui": {"mode": "full"},
  "wave": {"sessionId": "…", "batchId": "…", "active": true},
  "quality": "lossless",
  "codec": "flac-mp4",
  "bitrateKbps": 1411
}
```

`quality`/`codec` — фактическое качество текущего потока, а не только
значение из конфига. `bitrateKbps` — битрейт из ответа API; если API отдаёт
`0` (битрейт неизвестен), поле равно `null`. `wave` отсутствует, если волна
не запущена. `cover` —
всегда полный URL: `coverUri` из API (`%%` заменяется на `400x400`) или
готовый URL, присланный UI. `cached` показывает, есть ли трек в офлайн-кэше.
`downloads` — текущая и последние завершённые загрузки (`state`:
`downloading|done|error`); очередь целиком не сериализуется, её длина —
`downloadPending`.

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
| `queue_move` | `{"from":2,"to":0}` — переставить трек |
| `station_start` | `{"station":"track:123"}` или `{"station":"artist:456"}` — станция по треку/исполнителю |
| `queue_clear` | — |
| `queue_set` | `{"tracks":[…],"index":0,"play":true}` — заменить очередь |
| `download_track` | `{"track":{…}}` — поставить трек в очередь |
| `download_tracks` | `{"tracks":[…]}` — поставить плейлист в очередь |
| `cache_remove` | `{"id":"123"}` |
| `cache_clear` | — |
| `cache_limit` | `{"limitMb":2048}` |
| `volume` | `{"value":0.0…1.0}` |
| `seek` | `{"positionMs":42000}` |
| `repeat` | `{"value":"off|all|one"}` |
| `shuffle` | `{"value":true}` |
| `playlist_create` | `{"title":"…","visibility":"private"}` |
| `playlist_delete` | `{"kind":1234}` |
| `playlist_add_tracks` | `{"kind":1234,"tracks":[…]}` |
| `playlist_remove_track` | `{"kind":1234,"index":5}` |
| `like_track` | `{"id":"123","liked":true}` |

`wave_start`/`wave_more`/`wave_feedback` — асинхронные: сначала резолвят
радио-сессию, затем меняют очередь. `queue_set` с `play: true` тоже
резолвит поток и запускает трек. `download_track`/`download_tracks` сразу
отвечают `{ok, rev}`, воркер качает очередь по одному треку: прогресс виден в
`state.downloads`, длина очереди — в `state.downloadPending`.
`playlist_add_tracks`/`playlist_remove_track` сами получают актуальный
`revision` плейлиста; `like_track` обновляет лайк в очереди и текущем треке.
Очередь, текущий трек, позиция, громкость и качество сохраняются в
`~/.local/share/ymd/state.json` и восстанавливаются при старте (статус
`paused`); `play`/`toggle` после рестарта резолвят поток заново.

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
| `ymd logs [-n N] [-f] [--path]` | хвост файла логов демона |
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

### .deb и .rpm

```bash
ver=$(bash scripts/version.sh)
bash packaging/build-deb.sh --arch arm64   # или amd64 → dist/*.deb
bash packaging/build-rpm.sh --arch arm64   # → dist/*.rpm (Fedora-контейнер)

sudo apt install ./dist/ymd_${ver}_arm64.deb \
                 ./dist/plasma-widget-ymd_${ver}_all.deb
# или Fedora:
sudo dnf install ./dist/ymd-${ver}-1.fc44.*.rpm \
                 ./dist/plasma-widget-ymd-${ver}-1.fc44.noarch.rpm
systemctl --user enable --now ymd.service
```

Оба пакета `ymd` ставят `/usr/bin/ymd` и unit
`/usr/lib/systemd/user/ymd.service`; `plasma-widget-ymd` — плазмоид в
`/usr/share/plasma/plasmoids/io.github.pbolkhovitin.ymd`.
В RPM зависимости заданы именами Fedora (`gstreamer1`, `libsecret`,
`playerctl`), а библиотечные дописывает `rpmbuild` автоматически.

Оба сборщика запускают контейнер через `packaging/container-env.sh`: под
rootless podman нужны `--userns=keep-id` и `--security-opt label=disable`,
иначе SELinux не пускает контейнер к файлам рабочего каталога, а `-u $(id -u)`
даёт «Permission denied» на файлы с режимом 0600.

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

## Тексты песен

`api::lyrics(track_id, LyricsFormat::{Text, Lrc})`:

1. подписанный `GET /tracks/{id}/lyrics?format=…&timeStamp=…&sign=…`
   (ключ **windows**, данные `trackId + ts`, base64 **с паддингом** —
   отличается от `file-info`);
2. из ответа берётся `result.downloadUrl` (presigned S3, без авторизации);
3. текст скачивается вторым запросом и отдаётся клиенту.

`GET /v1/lyrics?id=&format=lrc|text` → `{id, format, text, writers, lyricId, major}`.
Нет текста — `404`; нет токена — `503`; без ключа — `401`.
CLI: `ymd lyrics <id> [--text] [--json]`.

Ссылка S3 живёт минуты, поэтому кэшировать нужно **текст**, а не URL.
Панель Noctalia парсит LRC, показывает окно ±2 строки и подсвечивает текущую
строку по `positionMs`. Плазмоид и `ymd-qt` кнопку пока не получили.

## Безопасность

- Слушает только `127.0.0.1`; ключ — 32 hex-символа, `0600`.
- Плазмоид не хранит токен и не ходит в API Яндекса.
- `ymd doctor` и логи не печатают токен.
- В `.deb` зависимости библиотек разрешены через `dpkg-shlibdeps`.
