# KDE Plasma 6 port — findings

Проверено на хосте 2026-11-13.

## Окружение

- Ubuntu 26.04.1 LTS, x86_64, KDE Plasma 6.6.6 (Wayland).
- Docker 29.9.3, binfmt `qemu-aarch64` зарегистрирован.
- `kpackagetool6` и `--packageroot` есть; `plasmoidviewer` и `qmllint6` в apt
  отсутствуют.
- QML-модули `org.kde.plasma.components`, `org.kde.kirigami`,
  `org.kde.plasma.plasma5support` установлены.
- Rust/cargo и GStreamer dev-пакеты на хосте отсутствуют — сборка и тесты идут
  в контейнере `packaging/Dockerfile`.
- `gitleaks` на хосте отсутствует; проверка — Docker-образ
  `zricethezav/gitleaks:latest`.
- Репозиторий лежит на CIFS (`file_mode=0660`, `nounix`): бит выполнения не
  выставляется, а cargo не может запускать build-скрипты из target-каталога на
  этом mount. Поэтому `CARGO_TARGET_DIR` — на локальной ФС
  (`/var/tmp/opencode/ymd-cache`); в git режим `100755` ставится через
  `git update-index --chmod=+x`.

## Решения

- Плазмоид `io.github.pbolkhovitin.ymd`, Plasma 6 / `plugin_api` не нужен:
  metadata.json KPackage.
- Ключ API читается командой `ymd session-key`, а не `sh -c` и не прямым
  чтением файла: Plasma5Support executable engine не запускает shell.
- Состояние — HTTP polling раз в 1 с при `playing`, раз в 3 с иначе; SSE не
  используется.
- Обложка — прямой URL в `Image.source` (в отличие от Noctalia, где нужен
  локальный файл).
- Пакеты: `ymd` (arm64/amd64) и `plasma-widget-ymd` (`all`, `Recommends: ymd`).

## Проверки

- `docker build --platform linux/amd64` и `cargo test` в контейнере —
  см. `packaging/run-tests.sh`.
- `ymd session-key` печатает тот же ключ, что лежит в
  `$XDG_RUNTIME_DIR/ymd/session.key`.
- Целевая машина `root@10.42.66.66`: Ubuntu 26.04, aarch64, Plasma 6,
  сессия root на Wayland. Плазмоид установлен через `kpackagetool6`, в панель
  добавлен скриптом `org.kde.PlasmaShell.evaluateScript`:
  `panels()[0].addWidget("io.github.pbolkhovitin.ymd")`.
- В отдельном QML-файле (`CompactRepresentation.qml`) нужно явно импортировать
  `org.kde.plasma.plasmoid`, иначе `Plasmoid` не определён. Ошибка видна в
  `journalctl --user -u plasma-plasmashell`.

## Сборка .deb

- `packaging/build-deb.sh --arch amd64` — 27 тестов, release, `dpkg-shlibdeps`,
  оба пакета. Первый запуск упал на `dpkg-deb: control directory has bad
  permissions 770`: CIFS отдаёт каталоги с `770`. Лечение — staging внутри
  контейнера в `/tmp/ymd-stage`, затем `cp` готовых `.deb` в `dist/`, плюс
  `chmod 0755` на каталоги пакета и `find ... -exec chmod` на файлы плазмоида.
- `dpkg-shlibdeps` предупреждает про diversions libc6 — это нормально для
  контейнера; зависимости всё равно вычисляются.
- `dist/` и `packaging/.shlibdeps/` — в `.gitignore`.
- arm64-сборка идёт через QEMU и заметно медленнее; кэш cargo/target —
  `/var/tmp/opencode/ymd-cache` (CIFS не годится для target).

## Отдельное приложение Qt

Пользователь попросил после KDE-порта сделать standalone-приложение на Qt.
Предварительно: Kirigami/Qt Quick, тот же демон `ymd` по HTTP, ключ через
`ymd session-key`. Нужна отдельная спека и план; в текущий порт не входит.
