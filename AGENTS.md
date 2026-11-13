# AGENTS.md — контекст проекта

Клиент Яндекс Музыки для **KDE Plasma 6** и **Noctalia**: плазмоид в панели,
приложение `ymd-qt` на Qt/Kirigami, плагин Noctalia (Luau) + Rust-демон `ymd`.
Этап: **KDE-порт и Qt-приложение готовы**; плагин Noctalia сведён с KDE-веткой
в один репозиторий (каталог `noctalia/`).

## Читать в этом порядке

1. `README.md` — обзор, установка, статус.
2. `docs/01-concept.md` — зачем и как выглядит.
3. `docs/02-architecture.md` — компоненты и IPC-контракт (общий для всех клиентов).
4. `docs/03-kde-plasmoid.md` / `docs/04-daemon.md` — детали слоёв.
5. `docs/11-qt-app.md` — отдельное приложение.
6. `docs/design/ui-rules.md` → `docs/design/plasma.md` / `docs/design/noctalia.md`.
7. `docs/07-roadmap.md` — что дальше.
8. `notes/kde-port-findings.md` — факты порта и грабли; `notes/design-audit.md` — аудит панели Noctalia.

## Состояние кода

| Путь | Что | Статус |
|---|---|---|
| `daemon/src/main.rs` | CLI: `serve`, `session-key`, `doctor`, `status`, `ctl`, … | готов |
| `daemon/src/httpd.rs` | `/v1/health`, `/v1/state`, `/v1/search`, `/v1/cmd`, `/v1/events` | готов |
| `daemon/src/state.rs` | состояние плеера, очередь, команды, волна | готов |
| `daemon/src/session.rs` | capability-ключ `0600`, `ymd session-key` | готов |
| `daemon/src/player.rs` | GStreamer `playbin3` → PipeWire | готов |
| `daemon/src/mpris_server.rs` | исходящий MPRIS (zbus) | готов |
| `daemon/src/mpris.rs` | внешний MPRIS через `playerctl` (резерв) | готов |
| `daemon/src/cache.rs` | офлайн-кэш `encraw` + AES-CTR | готов |
| `daemon/src/api.rs` | HTTP-клиент API, поток, поиск, волна | готов |
| `daemon/src/doctor.rs` | проверка окружения (`ymd doctor`), KDE/apt | готов |
| `plasmoid/contents/ui/main.qml` | ключ, polling, команды, поиск | готов |
| `plasmoid/contents/ui/CompactRepresentation.qml` | компакт в панели | готов |
| `plasmoid/contents/ui/FullRepresentation.qml` | попап: обложка, seek, транспорт, поиск, очередь | готов |
| `app/src/ymdclient.{h,cpp}` | HTTP-клиент приложения: ключ, polling, команды, поиск | готов |
| `app/src/tray.{h,cpp}` | трей: окно, play/pause, next/prev, выход | готов |
| `app/qml/Main.qml` | окно `ymd-qt`: обложка, seek, транспорт, поиск, очередь | готов |
| `noctalia/lib/ymd.luau` | HTTP-клиент демона: ключ, GET, cmd, SSE | готов |
| `noctalia/widget.luau` | бар-виджет: иконка + «трек — артист», клики и колесо | готов |
| `noctalia/panel.luau` | панель Noctalia: шапка, прогресс, транспорт, поиск, очередь | готов |
| `noctalia/bridge.luau` | фоновая SSE-подписка | готов |
| `scripts/install-noctalia.sh` | симлинк плагина в Noctalia + reload | готов |
| `packaging/` | Docker, `.deb`, systemd unit | готов |
| `scripts/` | сборка, установка, проверки | готов |

## Ограничения окружения агента

- **Shell доступен**: `cargo`, `git`, Docker можно запускать и проверять.
  `sudo` требует пароль пользователя (askpass без `/dev/tty` не работает).
- На хосте нет Rust/GStreamer dev — тесты идут через `packaging/run-tests.sh`
  (Docker, Ubuntu 26.04).
- CIFS не хранит exec-бит: скрипты запускаются через `bash`, режим `100755`
  ставится в git через `git update-index --chmod=+x`.
- Сеть есть; `websearch` может отдавать 403 — тогда использовать `duckduckgo`.

## Публикация

Репозиторий: `git@github.com:pbolkhovitin/ym-noctalia.git` (private).
После каждого завершённого этапа — коммит + `git push`.

Перед пушем: gitleaks в Docker:

```bash
docker run --rm -v "$PWD:/repo" zricethezav/gitleaks:latest \
  detect --source /repo --no-banner
```

## Документация обновляется автоматически

Документация — часть этапа, а не отдельная задача. Этап не считается завершённым,
пока доки не приведены в соответствие с кодом; коммит и пуш — сразу после.

Чек-лист после каждой фичи:

1. `README.md` — статус и новые команды.
2. `docs/0X-*.md` — раздел по теме: что и почему, а не пересказ кода.
3. `notes/<тема>-findings.md` — что проверено живьём, цифры, грабли.
4. `AGENTS.md` — таблица состояния и «Следующий шаг».
5. `docs/07-roadmap.md` — статус этапа.
6. `bash scripts/docs-check.sh` — скрипт должен выдать `ok`.
7. gitleaks → `git commit` → `git push`.

Правило факта: в `docs/` попадает только проверенное на хосте; догадки живут
в `notes/` с пометкой «гипотеза». Устаревшие обещания удаляются, а не остаются
рядом с реализацией.

## Правила

- Плазмоид, `ymd-qt` и плагин Noctalia **не** обращаются к API Яндекса и **не**
  хранят токен — только демон.
- В QML нет `#rrggbb`: цвета — `Kirigami.Theme` / `PlasmaComponents3`.
- В Luau нет `#rrggbb`: цвета — только `noctalia.getColor(role)`.
- Ноль анимаций по умолчанию: никаких Behavior, marquee, интерполяций.
- Ключ — только через `ymd session-key` (плазмоид — Plasma5Support executable
  engine; `ymd-qt` — файл ключа или `QProcess`; Noctalia — файл
  `$XDG_RUNTIME_DIR/ymd/session.key`), без `sh -c`.
- Сетевые запросы асинхронны; результат — в callback, не в `Component.onCompleted`.
- Плазмоид не пишет в свой каталог; обложки грузятся по URL.
- Плагин Noctalia пишет только в `pluginDataDir()`, не в `pluginDir()`;
  `runAsync` — только argv-форма.
- Корень панели Noctalia — `ui.column({ flexGrow = 1 })`, списки — в
  `ui.scroll({ flexGrow = 1 })`: без этого контент вылезает за панель.
- `ymd-qt` не дублирует `format.js`: копия должна совпадать с
  `plasmoid/contents/ui/format.js` (`cmp`).
- Факт попадает в `docs/` только после проверки; иначе — в `notes/`.

## Следующий шаг

1. **Noctalia-панель**: обложка (`cover` в `/v1/state` приходит null), артист в
   баре (хост режет ~22 символа), различимость паузы в баре, err/loading.
2. **Тексты песен**: `api::lyrics()`, `GET /v1/lyrics`, `ymd lyrics`, кнопка в
   попапе (разведка — `notes/lyrics-findings.md`).
3. **Докачка после обрыва**: `.part` + `Range`, не начинать с нуля.
4. **Ynison**: WebSocket-синхронизация между устройствами (опционально).

Ограничение `ymd-qt`: меню трея на Wayland может не открываться при вызове
через DBus (`ContextMenu` без input serial); клик по иконке и средняя кнопка
работают. Подробности — `docs/11-qt-app.md`.

Связанный проект: `~/github/yandex-music-research` — реверс-инжиниринг
официального клиента (API, подписи, `encraw`) и крейты `ym-api`/`ym-auth`/`ym-media`.
