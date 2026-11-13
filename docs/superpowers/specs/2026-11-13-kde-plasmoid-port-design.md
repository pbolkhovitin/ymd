# Дизайн: порт ym-noctalia на KDE Plasma 6 / Ubuntu 26.04 aarch64

- Дата: 2026-11-13
- Статус: на ревью
- Автор: агент (по согласованию с владельцем проекта)

## 1. Контекст и цель

Проект `ym-noctalia` — клиент Яндекс Музыки из двух частей:

- `ymd` — Rust-демон: OAuth/токен, API Яндекса, GStreamer-плеер, исходящий MPRIS,
  офлайн-кэш, «Моя волна», локальный HTTP+SSE API.
- `plugin/` — плагин Noctalia v5 на Luau: бар-виджет и панель.

Проект создавался под niri + Noctalia. Целевая платформа меняется на
**Ubuntu 26.04 LTS aarch64 + KDE Plasma 6.6**. Плагин Noctalia не может работать
в Plasma, поэтому UI-слой переписывается как нативный плазмоид Plasma 6 (QML),
а демон сохраняется.

Цель: получить устанавливаемые `.deb`-пакеты для aarch64, в которых:

1. `ymd` работает как systemd --user сервис и экспортирует MPRIS;
2. виджет в панели Plasma показывает текущий трек и управляет плеером;
3. попап даёт поиск, очередь, «Мою волну», режимы и качество;
4. документация и скрипты описывают только Ubuntu/KDE, без niri/Noctalia.

## 2. Не входит в scope

- Переименование GitHub-репозитория (`ym-noctalia` остаётся; переименование —
  отдельное решение владельца).
- Тексты песен, докачка после обрыва, Ynison — остаются следующими этапами.
- Поддержка Noctalia/niri в новом коде. Старые `notes/` сохраняются как
  исторические, но не поддерживаются.
- Публикация в PPA/COPR/Flathub. Пакеты собираются локально в `dist/`.
- Глобальные горячие клавиши Plasma: управление идёт через MPRIS и медиа-клавиши.

## 3. Целевая платформа

| Параметр | Значение |
|---|---|
| ОС | Ubuntu 26.04 LTS |
| Архитектура | aarch64 (arm64) |
| Рабочий стол | KDE Plasma 6.6 (Plasma 6 API) |
| Звук | PipeWire + WirePlumber |
| Сборка | Docker `--platform linux/arm64`, Ubuntu 26.04, QEMU-эмуляция |
| Проверка QML | локальный хост: Ubuntu 26.04 x86_64, Plasma 6.6.6 |

Docker, `qemu-aarch64` (binfmt) и `aarch64-linux-gnu-gcc` на сборочном хосте уже
есть. Rust и GStreamer dev-пакеты — внутри контейнера.

## 4. Архитектура

### 4.1 Компоненты

```
┌──────────────────────────── KDE Plasma 6.6 ────────────────────────────┐
│  плазмоид io.github.pbolkhovitin.ymd (QML)                             │
│   compact: иконка + «Трек — Артист»                                    │
│   popup:   обложка, прогресс, транспорт, поиск, очередь, волна         │
│                         │ HTTP 127.0.0.1:8765 + X-YMD-Session          │
└─────────────────────────┼──────────────────────────────────────────────┘
                          ▼
┌──────────────────────── ymd (Rust, systemd --user) ────────────────────┐
│  httpd ── state ── player (GStreamer → PipeWire)                       │
│    │         │        │                                                │
│    │         │        └── MPRIS (zbus) ──► Plasma Media Player         │
│    │         └── queue / wave / cache                                  │
│    └── SSE /v1/events (сохраняется для CLI и отладки)                  │
└────────────────────────────────────────────────────────────────────────┘
```

Плазмоид не обращается к API Яндекса и не хранит OAuth-токен. Единственный
секрет, который он читает, — capability-ключ локального API.

### 4.2 Поток данных

- Плазмоид опрашивает `GET /v1/state` каждые 1000 мс при `status == "playing"`
  и 3000 мс в остальных состояниях.
- Обновление UI применяется только при изменении `rev` (как в текущем виджете).
- Действия — `POST /v1/cmd` с `{op, payload}`:
  `toggle`, `prev`, `next`, `like`, `seek`, `repeat`, `shuffle`, `quality`,
  `play_track`, `queue_play`, `wave_start`.
- Поиск — `GET /v1/search?q=...` по Enter.
- SSE в плазмоиде не используется: опрос проще и повторяет текущее поведение.
  Endpoint `/v1/events` остаётся в демоне.

### 4.3 Аутентификация

- Ключ лежит в `$XDG_RUNTIME_DIR/ymd/session.key` (создаёт демон).
- Плазмоид читает его один раз при старте через
  `Plasma5Support.DataSource { engine: "executable" }`, запуская новый
  подкомандный интерфейс `ymd session-key` (печатает ключ в stdout).
  Это избегает проблем с shell-квотированием: executable-engine не вызывает `sh -c`.
- Ключ хранится только в памяти QML; не пишется в конфиг, логи и tooltip.
- При ответе 401 плазмоид один раз перечитывает ключ и повторяет запрос.
- Если ключа нет — попап показывает «демон недоступен / ключ не найден»
  и кнопку повторной попытки.

## 5. Плазмоид

### 5.1 Компактный виджет (панель)

- Статичная иконка `audio-x-generic` (не меняется на play/pause).
- Текст «Трек — Артист», обрезка через `elide`, максимум ~34 символа.
- Tooltip: полное «Трек — Все артисты».
- Управление:
  - ЛКМ — открыть/закрыть попап;
  - СКМ — play/pause;
  - колесо — prev/next;
  - ПКМ — штатное меню Plasma (настройки, удалить).
- В вертикальной панели — только иконка.
- Ноль кастомных анимаций.

### 5.2 Попап (FullRepresentation)

Ширина ~380 px, содержимое сверху вниз:

1. Статус, заголовок, «playing/paused · FLAC».
2. Обложка 96×96 (remote URL напрямую, без скачивания в pluginDataDir).
3. Артист.
4. Слайдер позиции + `mm:ss / mm:ss`; отпускание — `seek {positionMs}`.
5. Транспорт: prev, play/pause, next, like, «Волна», закрыть.
6. Режимы: repeat (off→all→one), shuffle, качество (lossless→hq→nq→lq).
7. Поиск: `TextField`, Enter, 4 результата, клик — играть.
8. Очередь: 4 строки, клик — играть.
9. Строка подсказки/ошибки.

Данные для строки трека: `✓` для `cached`, «Название · Артист», обрезка.

### 5.3 QML-структура

```
plasmoid/
  metadata.json
  contents/
    config/main.xml            # daemonPort, default 8765
    config/config.qml
    config/configGeneral.qml
    ui/main.qml                # PlasmoidItem, клиент, таймер
    ui/CompactRepresentation.qml
    ui/FullRepresentation.qml
    ui/TrackRow.qml
```

`metadata.json`: `KPackageStructure: "Plasma/Applet"`,
`X-Plasma-API-Minimum-Version: "6.0"`, Id `io.github.pbolkhovitin.ymd`,
Category `Multimedia`, Icon `audio-x-generic`, License MIT.

### 5.4 Клиент API

В `main.qml` — объект-клиент с методами:

- `refresh()` — GET `/v1/state`, обновление модели при смене `rev`;
- `cmd(op, payload, cb)` — POST `/v1/cmd`;
- `search(text, cb)` — GET `/v1/search`;
- `ensureKey()` / `retryKey()` — чтение ключа через `Plasma5Support`
  (команда `ymd session-key`).

`XMLHttpRequest` (Qt QML) без CORS-ограничений; заголовок
`X-YMD-Session` ставится на каждый запрос. Таймаут — 5 с.
Ошибки парсинга JSON не роняют виджет: показывается подсказка.

### 5.5 Темы и стиль

- Цвета — `Kirigami.Theme.textColor`, `disabledTextColor`, `highlightColor`,
  `backgroundColor`; никаких `#rrggbb`.
- Иконки — стандартные freedesktop: `media-skip-backward`,
  `media-playback-start`, `media-playback-pause`, `media-skip-forward`,
  `emblem-favorite`, `view-refresh`/`media-playlist-shuffle`.
- Без `Behavior`, `NumberAnimation`, marquee.

## 6. Демон

Функциональных изменений в HTTP-API, плеере, кэше и MPRIS нет. Правки:

- версия workspace `0.2.0`;
- новый подкомандный интерфейс `ymd session-key` — печатает capability-ключ
  из `$XDG_RUNTIME_DIR/ymd/session.key` (нужен плазмоиду, чтобы не парсить
  файл из QML);
- комментарии «для плагина Noctalia» → «для UI»;
- `ymd doctor`: подсказки Ubuntu вместо Fedora (dnf → apt);
- README/доки.

HTTP-контракт, capability-ключ, MPRIS, кэш, волна — без изменений.

## 7. Сборка и пакеты

### 7.1 Скрипты

```
packaging/
  build-deb.sh          # вход: --arch amd64|arm64
  in-docker.sh          # сборка внутри контейнера
  ymd.service           # systemd --user unit
  deb/ymd/control       # шаблон control
  deb/plasma-widget-ymd/control
  .cache/               # cargo registry/target (gitignore)
```

`build-deb.sh --arch arm64`:

1. `docker run --platform linux/arm64 -v "$PWD:/work" ubuntu:26.04`;
2. apt: `build-essential pkg-config curl ca-certificates
   libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev`;
3. rustup (stable, minimal);
4. `cargo test --release`, `cargo build --release`;
5. staging + `dpkg-deb --build`;
6. артефакты в `dist/`.

`--arch amd64` использует тот же образ без эмуляции — для быстрых итераций
и локального smoke-теста.

### 7.2 Состав пакетов

**`ymd_0.2.0_arm64.deb`**

- `/usr/bin/ymd`
- `/usr/lib/systemd/user/ymd.service`
- `/usr/share/doc/ymd/README.md`
- Depends: `libc6 (>= 2.39)`, `libgstreamer1.0-0 (>= 1.24)`,
  `libgstreamer-plugins-base1.0-0 (>= 1.24)`, `libglib2.0-0t64`,
  `libsecret-tools`, `playerctl`, `dbus-user-session`
- Recommends: `gstreamer1.0-plugins-good`, `gstreamer1.0-plugins-bad`,
  `gstreamer1.0-libav`, `gstreamer1.0-pipewire`, `pipewire`, `wireplumber`
- Автозапуск не включается: пользователь сам делает
  `systemctl --user enable --now ymd`.
- Точные версии библиотек генерируются `dpkg-shlibdeps` при сборке;
  в спеке — ориентировочный список.

**`plasma-widget-ymd_0.2.0_all.deb`**

- `/usr/share/plasma/plasmoids/io.github.pbolkhovitin.ymd/`
- Depends: `plasma-workspace (>= 4:6.0)`,
  `qml6-module-org-kde-plasma-plasma5support`,
  `qml6-module-org-kde-kirigami`
- Recommends: `ymd`
- Arch: `all`.

### 7.3 systemd unit

```ini
[Unit]
Description=Yandex Music daemon (ymd)
After=pipewire.service wireplumber.service

[Service]
ExecStart=/usr/bin/ymd serve
Restart=on-failure
RestartSec=2
Environment=RUST_LOG=info

[Install]
WantedBy=default.target
```

## 8. Документация и репозиторий

- `plugin/` удаляется; `plugin.toml`, Luau-модули и Noctalia-специфика уходят.
- `README.md` переписывается: возможности, Ubuntu 26.04 aarch64, установка из
  `.deb`, сборка, управление, MPRIS.
- `docs/03-noctalia-plugin.md` → `docs/03-kde-plasmoid.md`.
- `docs/01,02,05,06,07,08,09` — замена niri/Noctalia на KDE, актуализация
  статусов (M1–M4 готовы, порт K5).
- `notes/` — старые заметки остаются, добавляется
  `notes/kde-port-findings.md` (что проверено на Plasma 6.6.6).
- `AGENTS.md` — новая таблица состояния, правила QML, чек-лист документации.
- `scripts/dev-install.sh` — установка плазмоида через `kpackagetool6`;
  `p0-check.sh` → `check-env.sh` с apt-подсказками; `sse-watch.sh` без изменений.
- `scripts/docs-check.sh` — обновить маркеры и пути.

## 9. Тестирование и критерии приёмки

Автоматически:

- `cargo test` — 26 тестов проходят в amd64-контейнере;
- `cargo build --release` для aarch64;
- `file dist/.../usr/bin/ymd` → `ELF 64-bit LSB ... ARM aarch64`;
- `dpkg-deb -I` и `-c` — корректные зависимости и состав;
- `kpackagetool6 --type Plasma/Applet --install plasmoid` на локальном
  Plasma 6.6.6 — без ошибок;
- `bash scripts/docs-check.sh` → `ok`;
- `gitleaks detect --no-banner` → чисто.

Вручную на целевом хосте:

1. `systemctl --user enable --now ymd`, `curl /v1/health` → `ok: true`.
2. Виджет появляется в панели, показывает трек.
3. Попап: play/pause, next/prev, like, seek.
4. Поиск → воспроизведение; очередь; «Волна»; смена качества.
5. Штатный Media Player Plasma видит `ymd` через MPRIS.
6. Перезапуск `ymd` — виджет восстанавливается сам.

## 10. Риски

| Риск | Вероятность | Митигация |
|---|---|---|
| QEMU-сборка 30–60 мин | высокая | кэш cargo, `--arch amd64` для итераций |
| `plasma5support` признан legacy | средняя | в 6.6 работает; fallback — CLI-мост через `ymd status/ctl` |
| Нет кодеков AAC/FLAC | средняя | Recommends + раздел в README |
| Отличия Plasma 6.6 QML API | низкая | smoke-тест на локальном 6.6.6 |
| Ключ читается с задержкой при старте | низкая | retry + кнопка «повторить» |

## 11. Порядок работ (верхний уровень)

1. Каркас плазмоида + клиент API + компактный виджет.
2. Попап: состояние, транспорт, seek.
3. Поиск, очередь, волна, режимы, качество.
4. Пакетирование: unit, control-файлы, `build-deb.sh`, Docker.
5. Переписывание документации и скриптов, удаление `plugin/`.
6. Проверки, коммит, пуш.

Детальный план — в отдельном документе после утверждения этой спеки.
