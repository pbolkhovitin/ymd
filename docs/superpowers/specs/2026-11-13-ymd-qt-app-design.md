# Дизайн: отдельное приложение Yandex Music на Qt 6 / Kirigami

- Дата: 2026-11-13
- Статус: на ревью
- Автор: агент (по согласованию с владельцем проекта)

## 1. Контекст и цель

В репозитории уже есть рабочий клиент Яндекс Музыки для KDE Plasma 6:

- `ymd` — Rust-демон: токен, API Яндекса, GStreamer-плеер, MPRIS, кэш, «Моя волна»,
  локальный HTTP API на `127.0.0.1:8765`;
- `plasmoid/` — плазмоид Plasma 6: компактный виджет в панели и попап.

Нужно добавить **отдельное настольное приложение** — полноценное окно, которое
работает с тем же демоном и не дублирует его логику. Приложение и плазмоид могут
быть запущены одновременно.

Цель первой версии:

1. окно с текущим треком, обложкой, прогрессом и управлением;
2. поиск, очередь, «Моя волна», лайк, repeat/shuffle, качество;
3. работа из системного трея: закрытие прячет окно, трей управляет плеером;
4. `.deb` для amd64 и arm64;
5. приложение не хранит OAuth-токен и не обращается к API Яндекса.

## 2. Не входит в scope

- Собственный плеер, GStreamer, кэш, OAuth и API Яндекса — остаются в `ymd`.
- Замена или удаление плазмоида.
- Мобильная/планшетная адаптация, Windows/macOS.
- AppImage, Flatpak, Snap, PPA.
- Тексты песен, докачка после обрыва, Ynison — отдельные этапы.
- Глобальные горячие клавиши на уровне системы: медиа-клавиши уже обрабатывает
  MPRIS демона.
- Кастомные анимации и собственные цветовые схемы.

## 3. Целевая платформа

| Параметр | Значение |
|---|---|
| ОС | Ubuntu 26.04 LTS |
| Архитектуры | amd64, arm64 |
| Рабочий стол | KDE Plasma 6.6 Wayland (проверка), X11 не блокируется |
| UI | Qt 6.10, Qt Quick, Kirigami 6.24 |
| Трей | KStatusNotifierItem (KF6) |
| Сборка | CMake + Docker `--platform linux/amd64|arm64` |
| Пакет | `.deb`, версия 0.2.0 |

Зависимости сборки (проверены в apt Ubuntu 26.04): `qt6-base-dev`,
`qt6-declarative-dev`, `qt6-tools-dev`, `libkirigami-dev`,
`libkf6statusnotifieritem-dev`, `extra-cmake-modules`, `cmake`, `dpkg-dev`.
Qt Widgets нужен только для `QApplication`/трея.

## 4. Архитектура

### 4.1 Компоненты

```
┌────────────────────── ymd-qt (Qt 6 / Kirigami) ──────────────────────┐
│  main.cpp        QApplication, QQmlApplicationEngine, wiring         │
│  YmdClient       ключ, HTTP, JSON, polling, команды, поиск           │
│  Tray            KStatusNotifierItem + QMenu                         │
│  Main.qml        окно: трек, seek, транспорт, поиск, очередь         │
└──────────────────────────────┬───────────────────────────────────────┘
                               │ HTTP 127.0.0.1:8765
                               │ X-YMD-Session
                               ▼
┌────────────────────────── ymd (Rust) ────────────────────────────────┐
│  state / player / queue / wave / cache / MPRIS                        │
└──────────────────────────────────────────────────────────────────────┘
```

Приложение — **тонкий клиент**. Единственный секрет — capability-ключ
локального API; OAuth-токен и ключи Яндекса приложению недоступны.

### 4.2 Структура файлов

```
app/
  CMakeLists.txt
  src/main.cpp
  src/ymdclient.h
  src/ymdclient.cpp
  src/tray.h
  src/tray.cpp
  qml/Main.qml
  qml/TrackRow.qml
  qml/format.js          # копия plasmoid/contents/ui/format.js
  tests/test_ymdclient.cpp
  ymd-qt.desktop
```

`format.js` — побайтовая копия файла плазмоида; синхронность проверяется
отдельным тестом (`cmp`), чтобы форматирование времени и строк не разъезжалось.

### 4.3 C++-бэкенд `YmdClient`

`QObject`, владеет `QNetworkAccessManager` и `QTimer`.

Свойства для QML:

| Свойство | Тип | Смысл |
|---|---|---|
| `state` | `QVariantMap` | последний ответ `/v1/state` |
| `keyReady` | `bool` | ключ прочитан |
| `authFailed` | `bool` | 401 после повторного чтения ключа |
| `lastError` | `QString` | последняя ошибка для баннера |
| `searchResults` | `QVariantList` | результаты поиска |
| `searching` | `bool` | запрос поиска в полёте |

Методы:

- `refresh()` — GET `/v1/state`; обновляет `state`, переключает интервал polling
  (1000 мс при `status == "playing"`, иначе 3000 мс);
- `cmd(op)` / `cmd(op, payload)` — POST `/v1/cmd`;
- `search(text)` — GET `/v1/search?q=...&page=0`;
- `seek(positionMs)` — `cmd("seek", {"positionMs": ...})`;
- `retryKey()` — повторное чтение ключа.

Сигналы: `stateChanged`, `searchResultsChanged`, `searchingChanged`,
`keyChanged`, `authChanged`, `errorChanged`.

Поведение:

- ключ читается из `$XDG_RUNTIME_DIR/ymd/session.key`; если файла нет или он
  короче 16 символов — fallback `QProcess` `ymd session-key` (таймаут 3 с);
- при 401 ключ перечитывается **один раз** и запрос повторяется; повторный 401
  даёт `authFailed = true` и видимую ошибку без бесконечного цикла;
- при отсутствии ключа — retry каждые 5 с, пока окно открыто;
- таймаут HTTP — 5 с; ошибки парсинга JSON не роняют приложение;
- ключ не логируется, не пишется в конфиг и не попадает в URL.

### 4.4 Трей

`Tray` создаёт `KStatusNotifierItem`:

- иконка `audio-x-generic`, статус `Active`, категория `ApplicationStatus`;
- tooltip: «Трек — Артист» или «Yandex Music»;
- ЛКМ — показать/скрыть окно;
- меню: «Показать окно», «Играть/Пауза», «Следующий», «Предыдущий», «Выход»;
- закрытие окна прячет его в трей; выход — только через меню трея.

`KStatusNotifierItem` требует `QApplication` (Qt Widgets), поэтому `main.cpp`
использует `QApplication`, а не `QGuiApplication`.

## 5. Контракт с демоном

Используются только существующие эндпоинты; изменений в `ymd` нет.

| Запрос | Назначение |
|---|---|
| `GET /v1/health` | проверка демона без ключа |
| `GET /v1/state` | состояние, очередь, качество |
| `GET /v1/search?q=&page=` | поиск |
| `POST /v1/cmd` | команды `{op, payload}` |

Заголовок `X-YMD-Session` — на всех запросах, кроме `/v1/health`.

Команды: `toggle`, `play`, `pause`, `next`, `prev`, `like`, `seek`,
`repeat`, `shuffle`, `quality`, `play_track`, `queue_play`, `queue_clear`,
`queue_remove`, `wave_start`, `wave_more`, `wave_stop`, `wave_feedback`,
`volume`.

## 6. Окно и поведение

`Kirigami.ApplicationWindow`, стартовый размер 420×640, заголовок
«Yandex Music», иконка `audio-x-generic`.

Содержимое сверху вниз:

1. **Сейчас играет**: обложка 128×128 (URL напрямую; placeholder —
   `Kirigami.Icon`), название, артисты, альбом, статус и качество.
2. **Прогресс**: слайдер 0…`durationMs`, время `mm:ss / mm:ss`; seek
   отправляется при отпускании, а не на каждом движении.
3. **Транспорт**: prev, play/pause, next, like, «Волна».
4. **Режимы**: repeat (off→all→one), shuffle, quality
   (lossless→hq→nq→lq).
5. **Поиск**: `TextField`, Enter, до 6 результатов; клик — `play_track`.
6. **Очередь**: до 8 строк, подсветка текущего; клик — `queue_play`.
7. **Ошибка**: баннер с текстом и кнопкой «Повторить».

Состояния:

- ключ не найден — «Демон не найден. Запущен ли ymd?» + «Повторить»;
- демон не отвечает — «Демон не отвечает» + «Повторить»;
- пустая очередь — «Очередь пуста»;
- поиск без результатов — «Ничего не найдено»;
- 401 после перечитки — «Ключ устарел. Перезапустите ymd.»;
- всё нормально — ошибка скрыта.

Горячие клавиши:

- `Space` — play/pause (кроме фокуса в поле поиска);
- `Left` / `Right` — seek −5 с / +5 с;
- `Ctrl+F` — фокус в поиск;
- `Esc` — закрыть окно в трей.

Стиль:

- цвета только `Kirigami.Theme` / `PlasmaComponents3`; никаких `#rrggbb`;
- иконки freedesktop: `media-skip-backward`, `media-playback-start`,
  `media-playback-pause`, `media-skip-forward`, `emblem-favorite`,
  `media-playlist-shuffle`, `view-refresh`;
- ноль анимаций (`Behavior`, `NumberAnimation`, marquee);
- доступные имена и tooltips у кнопок.

## 7. Сборка и пакеты

### 7.1 CMake

- `qt_add_executable(ymd-qt ...)`, `qt_add_qml_module` с URI `YmdQt`,
  QML-файлы компилируются в ресурсы;
- `find_package(Qt6 COMPONENTS Quick QuickControls2 Network Widgets Test)`,
  `find_package(KF6Kirigami)`, `find_package(KF6StatusNotifierItem)`;
- `install(TARGETS ymd-qt RUNTIME DESTINATION bin)`;
- `install(FILES ymd-qt.desktop DESTINATION share/applications)`;
- `enable_testing()`, `add_test` для `test_ymdclient`.

### 7.2 Docker и `.deb`

```
packaging/
  Dockerfile.qt
  build-qt-deb.sh
  qt-in-docker.sh
  deb/ymd-qt/control.in
```

- `Dockerfile.qt`: Ubuntu 26.04 + Qt/Kirigami/KF6 dev-пакеты + CMake.
- `build-qt-deb.sh --arch amd64|arm64`: собирает `ymd-qt-builder:$arch`,
  запускает `qt-in-docker.sh`.
- `qt-in-docker.sh`: `cmake -B build -DCMAKE_BUILD_TYPE=Release`,
  `cmake --build`, `ctest`, staging в `/tmp`, `dpkg-shlibdeps`, `dpkg-deb`.
- Артефакт: `dist/ymd-qt_0.2.0_<arch>.deb`.

Состав пакета:

- `/usr/bin/ymd-qt`
- `/usr/share/applications/io.github.pbolkhovitin.ymdqt.desktop`
- `/usr/share/doc/ymd-qt/README.md`, `copyright`
- Depends: `ymd`, QML-модули `qml6-module-org-kde-kirigami`,
  `qml6-module-qtquick-controls`, `qml6-module-qtquick-layouts`,
  `qml6-module-qtquick-templates`, `qml6-module-qtquick-window`,
  `qml6-module-qtqml-workerscript` + точные библиотеки из `dpkg-shlibdeps`.
- Arch: `amd64`/`arm64`.

`ymd-qt.desktop`: `Name=Yandex Music`, `Exec=ymd-qt`, `Icon=audio-x-generic`,
`Categories=AudioVideo;Audio;Player;`, `StartupWMClass=ymd-qt`.

## 8. Тестирование и критерии приёмки

Автоматически:

- `ctest` в контейнере: парсинг состояния, поиска, команды, 401-retry,
  отсутствие ключа, таймаут;
- `node --test plasmoid/tests/format.test.js` — без регрессий;
- `cmp app/qml/format.js plasmoid/contents/ui/format.js`;
- `bash scripts/docs-check.sh` → `ok`;
- gitleaks → чисто;
- `dpkg-deb -I/-c` — архитектура, зависимости, состав.

Вручную на Plasma 6.6:

1. Запустить `ymd`, затем `ymd-qt`; окно показывает состояние.
2. Play/pause, next/prev, like, seek, repeat/shuffle/quality.
3. Поиск → воспроизведение; очередь; «Волна».
4. Закрыть окно — остаётся в трее; ЛКМ по трею возвращает окно.
5. Меню трея: play/pause, next, prev, выход.
6. Перезапуск `ymd` — приложение восстанавливается без перезапуска.
7. Нет ключа — понятная ошибка и «Повторить».

## 9. Риски

| Риск | Вероятность | Митигация |
|---|---|---|
| KStatusNotifierItem + QApplication конфликтует с Kirigami | средняя | smoke-тест трея на первом этапе |
| QML-модули не попадают в `.deb` | средняя | явные Depends + `qml6-module-*` |
| Расхождение `format.js` с плазмоидом | низкая | `cmp`-тест |
| Wayland-трей не показывается | низкая | KStatusNotifierItem штатен для Plasma 6 |
| 401-цикл при неверном ключе | низкая | одна перечитка, затем видимая ошибка |
| QEMU-сборка arm64 долгая | высокая | кэш и `--arch amd64` для итераций |

## 10. Порядок работ (верхний уровень)

1. Каркас `app/`, CMake, `YmdClient`, тесты, пустое окно.
2. Окно: состояние, обложка, seek, транспорт, режимы.
3. Поиск, очередь, «Волна», ошибки.
4. Трей и поведение закрытия.
5. `.deb`, Docker, зависимости.
6. Документация, проверки, remote smoke-тест.
