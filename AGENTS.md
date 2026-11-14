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
8. `docs/13-versioning.md` — версии, теги и релизы; `docs/14-macos.md` — macOS;
   `docs/15-macos-brief.md` — бриф для контрибьютора по `/macos/`; `CHANGELOG.md`.
9. `notes/kde-port-findings.md` — факты порта и грабли; `notes/design-audit.md` — аудит панели Noctalia.

## Состояние кода

| Путь | Что | Статус |
|---|---|---|
| `daemon/src/main.rs` | CLI: `serve`, `session-key`, `doctor`, `status`, `ctl`, … | готов |
| `daemon/src/httpd.rs` | `/v1/*`: состояние, поиск, главная, discovery, радио, лайки, config, auth | готов |
| `daemon/src/state.rs` | состояние плеера, очередь, команды, волна | готов |
| `daemon/src/session.rs` | capability-ключ `0600`, `ymd session-key` | готов |
| `daemon/src/player.rs` | GStreamer `playbin3` → PipeWire | готов |
| `daemon/src/mpris_server.rs` | исходящий MPRIS (zbus) | готов |
| `daemon/src/mpris.rs` | внешний MPRIS через `playerctl` (резерв, Linux) | готов |
| `daemon/src/mpris_stub.rs` | заглушка MPRIS для macOS | готов |
| `daemon/src/cache.rs` | офлайн-кэш `encraw` + AES-CTR | готов |
| `daemon/src/api.rs` | HTTP-клиент API, поток, поиск, волна | готов |
| `daemon/src/doctor.rs` | проверка окружения (`ymd doctor`), KDE/apt | готов |
| `daemon/src/logging.rs` | файл лога `~/.local/state/ymd/ymd.log`, `ymd logs` | готов |
| `plasmoid/contents/ui/main.qml` | ключ, polling, команды, поиск | готов |
| `plasmoid/contents/ui/CompactRepresentation.qml` | компакт в панели | готов |
| `plasmoid/contents/ui/FullRepresentation.qml` | попап: обложка, seek, транспорт, поиск, очередь | готов |
| `app/src/ymdclient.{h,cpp}` | HTTP-клиент приложения: ключ, polling, команды, поиск | готов |
| `app/src/tray.{h,cpp}` | трей: окно, play/pause, next/prev, выход | готов |
| `app/qml/Main.qml` | окно `ymd-qt`: обложка, seek, транспорт, поиск, очередь | готов |
| `noctalia/lib/ymd.luau` | HTTP-клиент демона: ключ, GET, cmd, SSE | готов |
| `noctalia/widget.luau` | бар-виджет: глиф по статусу, подпись `app`/`title` (настройка), клики и колесо | готов |
| `noctalia/panel.luau` | панель Noctalia: шапка, seek-слайдер, громкость, транспорт, поиск, очередь | готов |
| `noctalia/bridge.luau` | фоновая SSE-подписка | готов |
| `scripts/install-noctalia.sh` | симлинк плагина в Noctalia + reload | готов |
| `scripts/version.sh` | версии: `--check`, `--next`, `--bump`, `--tag` | готов |
| `scripts/release.sh` | релиз: `prepare`, `check`, `publish`, `status` | готов |
| `macos/` | самостоятельный `ymd-menubar` (SwiftUI), встроенный демон/runtime, Device Flow, «Моя волна», target macOS 13 arm64 | готов; запуск проверен на 27.2.1 |
| `packaging/` | Docker, `.deb`, `.rpm`, systemd unit | готов |
| `scripts/` | сборка, установка, проверки | готов |
| `.github/workflows/ci.yml` | версии, доки, тесты, архив плагина; ручной прогон `.rpm` | готов |
| `.github/workflows/release.yml` | вручную/тег → verify, тесты, `.deb`/`.rpm`, approve, тег + GitHub Release | готов |
| `.github/workflows/macos-release.yml` | вручную: `.dmg` + tar.gz демона arm64 к релизу | готов |

## Ограничения окружения агента

- **Shell доступен**: `cargo`, `git`, Docker можно запускать и проверять.
  `sudo` требует пароль пользователя (askpass без `/dev/tty` не работает).
- На хосте нет Rust/GStreamer dev — тесты идут через `packaging/run-tests.sh`
  (Docker, Ubuntu 26.04).
- CIFS не хранит exec-бит: скрипты запускаются через `bash`, режим `100755`
  ставится в git через `git update-index --chmod=+x`.
- Сеть есть; `websearch` может отдавать 403 — тогда использовать `duckduckgo`.

## Публикация

Репозиторий: `git@github.com:pbolkhovitin/ymd.git` (public, MIT).
Прежнее имя `ym-noctalia` — GitHub редиректит старые ссылки.
После каждого завершённого этапа — коммит + `git push`.

Перед пушем: gitleaks в Docker:

```bash
docker run --rm -v "$PWD:/repo" docker.io/zricethezav/gitleaks:latest \
  detect --source /repo --no-banner
```

Если Docker не видит каталог (CIFS, rootless) — локальный бинарь:
`gitleaks detect --no-banner --redact`.

### Релиз

Версия одна на весь проект, источник истины — `Cargo.toml`
(`[workspace.package]`); манифесты синхронизируются только скриптом.
Тег — `vMAJOR.MINOR.PATCH`. Тег не ставится вручную: его создаёт
`release.yml` после проверок, сборки и approve environment `release`.

```bash
bash scripts/release.sh prepare minor      # ветка release/vX.Y.Z + PR
# ревью и merge PR
bash scripts/release.sh publish vX.Y.Z     # dry-run: verify/test/build
bash scripts/release.sh publish vX.Y.Z --yes   # approve → тег + Release
gh workflow run macos-release.yml -f tag=vX.Y.Z
```

`prepare` сам поднимает версию в манифестах и `Cargo.lock`, переносит
`[Unreleased]` в раздел версии, запускает `docs-check` и `pr-check` и
открывает PR. Release-PR распознаётся `client-scope` и `pr-check` по
заголовку `chore(release): X.Y.Z`; для него разрешены только манифесты
версий, `Cargo.lock` и `CHANGELOG.md`. Проверка релиза требует, чтобы
релизный коммит был в истории `HEAD`; fix-коммиты после release-PR
допустимы. `publish` без `--yes` работает как dry-run. Подробности —
`docs/13-versioning.md`, история — `CHANGELOG.md`.

## Документация обновляется автоматически

Документация — часть этапа, а не отдельная задача. Этап не считается завершённым,
пока доки не приведены в соответствие с кодом; коммит и пуш — сразу после.

Чек-лист после каждой фичи:

1. `README.md` — статус и новые команды.
2. `docs/0X-*.md` — раздел по теме: что и почему, а не пересказ кода.
3. `notes/<тема>-findings.md` — что проверено живьём, цифры, грабли.
4. `AGENTS.md` — таблица состояния и «Следующий шаг».
5. `docs/07-roadmap.md` — статус этапа.
6. `bash scripts/docs-check.sh` — должен выдать `ok`. Проверяет: маркеры
   устаревания, отставание доков от **исходников** (`daemon`, `plasmoid`,
   `app`, `noctalia`; изменения в `packaging`, `scripts`, `.github` —
   подсказка, не блокер), модули без упоминания, **каждый
   маршрут `/v1/*` из `httpd.rs`**, совпадение копий `format.js`
   (`plasmoid/contents/ui/format.js` ↔ `app/qml/format.js`) и **версии
   в четырёх манифестах** (`scripts/version.sh --check`).
7. `bash scripts/pr-check.sh --body <файл>` — оформление PR (см. раздел
   «PR и issue»).
8. `CHANGELOG.md` — пункт в `[Unreleased]`; версия — только через
   `scripts/version.sh --bump`.
9. gitleaks → `git commit` → `git push`.

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

## PR и issue

Формат PR — `.github/PULL_REQUEST_TEMPLATE.md`; правила — `CONTRIBUTING.md`.
Проверка `pr-policy` (`scripts/pr-check.sh`) идёт на каждый PR и падает, если:

- заголовок не в стиле Conventional Commits (`fix(scope): …`, `feat: …`) —
  при squash-merge он становится сообщением коммита в `main`;
- нет разделов шаблона, пустой «Что меняется»/«Как проверить» или не отмечен
  ни один клиент;
- галочки «Клиент» не совпадают с каталогами в diff;
- тронут `daemon/`, `plasmoid/`, `app/`, `noctalia/` или `macos/`, а в
  `CHANGELOG.md` → `[Unreleased]` не добавлен пункт.

Исключение — release-PR с заголовком `chore(release): X.Y.Z`: ему разрешены
манифесты всех клиентов и `CHANGELOG.md`; вместо нового пункта в
`[Unreleased]` проверяется непустой раздел `## [X.Y.Z]` и пустой
`[Unreleased]`.

Агент перед PR обязан:

1. Ветка от свежего `main`: `feat/<тема>`, `fix/<тема>`, `docs/<тема>`.
2. Один PR — один клиент; `noctalia/` и `plasmoid|app/` вместе запрещены
   (`client-scope`), демон и общие доки — отдельным PR.
3. Заполнить все пять разделов шаблона, не удаляя заголовки; в «Как проверить» —
   команды и ожидаемый результат.
4. Отметить клиенты, каталоги которых реально менялись.
5. Добавить пункт в `CHANGELOG.md` → `[Unreleased]` при правках кода.
6. Локально: `bash scripts/pr-check.sh --body /tmp/pr.md` и
   `bash scripts/docs-check.sh`.

Issue — только через формы `.github/ISSUE_TEMPLATE/` (обязательные поля
проверяет GitHub); вопросы по установке и уязвимости — по ссылкам из
`config.yml`, не публичным issue.

### Codex

Codex читает `AGENTS.md` автоматически (от корня проекта до текущего
каталога); `AGENTS.override.md` рядом — локальный override, в репозиторий его
не коммитим. Отдельный `.codex/AGENTS.md` не нужен — Codex его не ищет.

Перед PR Codex выполняет:

```bash
bash scripts/docs-check.sh
bash scripts/pr-check.sh --body /tmp/pr.md
git status --short          # в diff только файлы одного клиента
git log -1 --format='%an <%ae>'
```

При ревью PR Codex проверяет те же пункты: заголовок Conventional Commits,
один клиент, пункт в `CHANGELOG.md`, отсутствие токена и прямых запросов к
API Яндекса в клиентах, зелёные `docs-check` и `pr-check`. Содержательную
оценку архитектуры и UI это не заменяет — последнее слово за владельцем
каталога из `CODEOWNERS`.

## Следующий шаг

Самостоятельная сборка macOS: `LC_ALL=C bash macos/build.sh`,
`bash macos/build-dmg.sh --no-build`; официальный GStreamer 1.28.8 в
`packaging/.cache/`, без глобальной установки framework. Все вложенные
Mach-O проверяются на arm64 и минимум не выше 13.0. Нужна живая проверка
на Ventura; результаты текущего хоста — `notes/macos-standalone-findings.md`.

1. **Бар Noctalia**: артист теряется (хост режет ~22 символа), play/pause
   неразличимы (статичный глиф). Переподключение после рестарта демона
   исправлено (`rev` не монотонен, 3 ошибки до «off»), `ymd doctor` ловит
   висячий симлинк плагина. Диагностика очереди — `ymd logs`,
   `notes/logging-findings.md`, `notes/noctalia-ui-findings.md`.
2. **Тексты песен — ✅ демон, CLI, Noctalia.** Плазмоид и `ymd-qt` кнопку ещё
   не имеют: `api::lyrics()`, `GET /v1/lyrics`, `ymd lyrics` готовы.
3. **Докачка после обрыва — ✅ `.part` + `Range` + отпечаток ключа.**
   Проверено: обрыв на 41 % → продолжение с 14 МиБ и успешное завершение.
4. **Ynison**: WebSocket-синхронизация между устройствами (опционально).

UI discovery и вход в Noctalia-панели готовы: `docs/design/noctalia.md`
(виды и источники), `notes/noctalia-ui-findings.md` (грабли Yoga и Luau).
Plasma и `ymd-qt` — зона Леонида, этапы 5 и 7 в `docs/12-discovery-account.md`.

Ограничение `ymd-qt`: меню трея на Wayland может не открываться при вызове
через DBus (`ContextMenu` без input serial); клик по иконке и средняя кнопка
работают. Подробности — `docs/11-qt-app.md`.

Связанный проект: `~/github/yandex-music-research` — реверс-инжиниринг
официального клиента (API, подписи, `encraw`) и крейты `ym-api`/`ym-auth`/`ym-media`.
