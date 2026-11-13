# AGENTS.md — контекст проекта

Клиент Яндекс Музыки для **niri + Noctalia v5**: бар-виджет + панель + Rust-демон.
Этап: **P0-спайки**. Документация готова, скелет собран.

## Читать в этом порядке

1. `README.md` — обзор, структура, быстрый старт.
2. `docs/01-concept.md` — зачем и как выглядит.
3. `docs/02-architecture.md` — компоненты и IPC-контракт.
4. `docs/09-p0-spikes.md` — что проверяем прямо сейчас (S1–S9).
5. `docs/03-noctalia-plugin.md` / `docs/04-daemon.md` — детали слоёв.
6. `notes/p0-findings.md` — факты, добытые на хосте.

## Состояние кода

| Путь | Что | Статус |
|---|---|---|
| `daemon/src/main.rs` | CLI: `serve`, `session-key`, `doctor`, `status`, `ctl` | готов |
| `daemon/src/httpd.rs` | `/v1/health`, `/v1/state`, `/v1/cmd`, `/v1/events` (SSE) | готов (P0) |
| `daemon/src/state.rs` | состояние плеера, очередь, команды | готов |
| `daemon/src/session.rs` | capability-ключ `0600`, `ymd session-key` | готов |
| `plugin/widget.luau` | бар: статичная иконка + «Трек — Артист», tooltip | M2 |
| `plugin/probe.luau` | дамп `barWidget.*`/`ui.*`/`noctalia.*` | P0 ✅ (S2/S3/S5) |
| `plugin/bridge.luau` | SSE-подписка | P0 ✅ (S4) |
| `plugin/panel.luau` | `ui.*`-дерево | P0 ✅ (S3) |
| `daemon/src/api.rs` | HTTP-клиент API + `stream` | M1 ✅ (кроме потока) |
| `daemon/src/mpris.rs` | внешний MPRIS через `playerctl` | M1 ✅ (фоллбэк) |
| `daemon/src/player.rs` | GStreamer `playbin3` | M2 ✅ |
| `daemon/src/mpris_server.rs` | исходящий MPRIS (zbus) | M2 ✅ |
| `daemon/src/httpd.rs` | + `/v1/search`, `payload` в `/v1/cmd` | M1 ✅ |
| `plugin/panel.luau` | поиск, результаты, очередь, транспорт | M1 ✅ |
| `daemon/src/cache.rs` | офлайн-кэш `encraw` + AES-CTR | M3 ✅ (базово) |
| `daemon/src/config.rs` | настройки: качество звука, лимит кэша | M2 ✅ |
| `daemon/src/doctor.rs` | проверка окружения (`ymd doctor`), KDE/apt | готов |

## Ограничения окружения агента

- **Shell доступен**: `cargo`, `git` можно запускать и проверять сборку/тесты.
  `sudo` по-прежнему требует пароль пользователя (askpass без `/dev/tty` не работает).
- Установка системных пакетов (`dnf`) и правки в `/etc` — только через пользователя.
- Сеть есть; `websearch` может отдавать 403 — тогда использовать `duckduckgo`.

## Публикация

Репозиторий: `git@github.com:pbolkhovitin/ym-noctalia.git` (private).
После каждого завершённого этапа — коммит + `git push` (просил пользователь).
Перед пушем: `gitleaks detect --no-banner` (сейчас чисто; токены живут только в keyring).

## Документация обновляется автоматически

Документация — часть этапа, а не отдельная задача. Этап не считается завершённым,
пока доки не приведены в соответствие с кодом; коммит и пуш — сразу после.

Чек-лист после каждой фичи:

1. `README.md` — блок «Статус» и новые команды.
2. `docs/0X-*.md` — раздел по теме: что и почему, а не пересказ кода.
3. `notes/<тема>-findings.md` — что проверено живьём, цифры, грабли.
4. `AGENTS.md` — таблица состояния и «Следующий шаг».
5. `docs/07-roadmap.md` — статус этапа.
6. `bash scripts/docs-check.sh` — маркеры устаревания, отставание доков от кода,
   модули без упоминания. Скрипт должен выдать `ok`.
7. `gitleaks detect --no-banner` → `git commit` → `git push`.

Правило факта: в `docs/` попадает только проверенное на хосте; догадки живут
в `notes/` с пометкой «гипотеза». Устаревшие обещания («не начат», «план»)
удаляются, а не остаются рядом с реализацией.

## Правила

- Плагин **не** обращается к API Яндекса и **не** хранит токен — только демон.
- В плагине нет `#rrggbb`: цвета — `noctalia.getColor(role)`.
- Ноль анимаций по умолчанию: никаких `setNeedsFrameTick`, marquee, интерполяций.
- `runAsync` — только argv-форма (`plugin_api >= 24`), никаких `sh -c` с вводом.
- `runAsync`/`http` — асинхронные: результат только в callback, не в `update()`.
- Не писать в `pluginDir()` (перезаписывается) — только `pluginDataDir()`.
- Факт попадает в `docs/` только после проверки; иначе — в `notes/p0-findings.md`.

## Следующий шаг

Пройти остаток P0 (`docs/09-p0-spikes.md`), факты — в `notes/p0-findings.md`:

- **S1** — уточнить максимум `plugin_api` (35 принимается).
- **S6** — MPRIS-сервер в демоне (`zbus`, чисто Rust, без dev-пакетов).
- **S7** — заблокирован: нет `gstreamer1-devel`; обходной путь — `mpv --no-video`.
- **S8** — нет поля `is_fullscreen` в `niri msg --json windows` (niri 26.04).
- **S9** — заблокирован: нужен свой OAuth `client_id` с loopback `redirect_uri`.

Проверено на хосте: `barWidget` — 12 методов (`setText/setGlyph/setImage/setTooltip/
setColor/setGlyphColor/setFont/setVisible/clearTooltip/isVertical/outputName/render`),
`ui` — 21 метод, панель открывается, SSE и чтение ключа из `$XDG_RUNTIME_DIR` работают.

M1 в работе: API-клиент, `ymd search/track/album/artist`, MPRIS-мост работают.
Поток разблокирован: `/get-file-info` работает при совпадении пары
«заголовок клиента + ключ» (см. `notes/reference-yandex-music-api.md`).
Вход — `ymd auth login` (Device Flow). Панель с поиском и очередью готова.

M2 готов: собственный плеер (GStreamer `playbin3` → PipeWire) и исходящий MPRIS.
`playerctl --player=ymd` управляет демоном, медиа-клавиши работают.
Очередь: автопереход, `repeat/shuffle/queue_remove`, обложки в состоянии.
Обложки: `ui.image` принимает только локальный `path`, файл качается в
`pluginDataDir()`; в баре — `barWidget.setImage`.

M3 готов: `ymd download`, `ymd download-album`, `ymd cache list/path/remove/info`,
лимит + LRU (`[cache] limit_mb`), `cached` в `/v1/search` и `✓` в панели.
Локальный файл играет через `file://` без сети.
M4: «Моя волна» готова — `ymd wave`, кнопка в панели, автодогрузка,
`wave_feedback`. Тексты песен: разведка API выполнена (`notes/lyrics-findings.md`) — подпись отличается
от `file-info`, текст отдаётся ссылкой на S3. Код не начат.
Качество: `ymd quality`, команда `quality` в `/v1/cmd`, поля `quality`/`codec`
в состоянии, индикатор и переключатель в панели.
Дальше: тексты (демон + CLI + панель), докачка после обрыва, Ynison.

Связанный проект: `~/github/yandex-music-research` — реверс-инжиниринг официального
клиента (API, подписи, `encraw`) и крейты `ym-api`/`ym-auth`/`ym-media`.
