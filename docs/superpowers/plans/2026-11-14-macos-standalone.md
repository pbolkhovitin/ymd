# План самостоятельного приложения macOS

> Исполнение в текущей ветке, с subagent-driven-development. Пользователь
> разрешил коммит и публикацию в своём форке с версией приложения 0.2.1.

Цель: .app в DMG включает демон и runtime, запускает их и предоставляет
вход и «Мою волну» без терминала. Стек: Rust, SwiftUI/Foundation, Python 3
для упаковки Mach-O, официальный GStreamer SDK как источник runtime, pkgconf только при сборке.

## 1. Упаковка runtime

- [x] Добавить `macos/Tests/test_bundle_runtime.py`: временные Mach-O
  библиотеки проверяют транзитивную упаковку, перенос .app, отсутствие
  зависимости от исходных файлов и ошибку при конфликте имён.
- [x] Запустить `python3 -m unittest discover -s macos/Tests -v`, увидеть
  отсутствие упаковщика; затем реализовать `macos/bundle-runtime.py`.
- [x] Включить аудиоплагины (FLAC, AAC/libav, MP3/mpg123, контейнеры),
  libsoup (динамическая загрузка), GIO OpenSSL TLS и CA bundle. Перенаправлять
  dylib на @loader_path; проверить граф через otool после упаковки.
- [x] Обновить `macos/build.sh`: собрать release-демон и SwiftUI,
  упаковать runtime и подписать все вложенные Mach-O перед .app.
- [x] Обновить подпись и памятку `macos/build-dmg.sh` для самостоятельной
  сборки; подписывать вложенные Mach-O выбранным Developer ID.

## 2. Управление демоном и первый запуск

- [x] В `macos/Package.swift` добавить test target; начать с тестов реального
  процесса: старт/готовность, внешний демон, выход и ошибка старта.
- [x] В `macos/Sources/ymd-menubar/DaemonSupervisor.swift` реализовать
  запуск через Process, ограниченное ожидание HTTP, контроль владения и
  завершение собственного ребёнка. Конфликт порта — ошибка в UI.
- [x] Расширить `APIClient.swift` моделями account/device flow и методами
  health/account/auth; тестировать ошибки HTTP и декодирование.
- [x] В `AppModel.swift` связать запуск, polling, вход/отмену и wave_start;
  остановить ребёнка также при завершении через системный Quit.
- [x] В `Views.swift` показать запуск/ошибки/повтор, кнопку входа, код и
  браузер, состояние аккаунта и «Мою волну». Сохранить текущий плеер.
- [x] Попытка XCTest выявила отсутствие XCTest/Testing в CLT; выполнены
  `bash macos/Tests/run-standalone-checks.sh` и release-сборка клиента.

## 3. Интеграция и документация

- [x] Остановить запущенные ymd-menubar и ymd по точным именам процессов.
- [x] Собрать .app, запустить без внешнего демона и проверить /v1/health,
  путь бинарника ребёнка, UI и повторное открытие.
- [x] Проверить остановку собственного демона при выходе и подключение к
  внешнему без его остановки; проверить аудиоплагины/HTTPS из bundle.
- [x] Собрать DMG, проверить hdiutil verify и codesign --verify --deep --strict.
- [x] Обновить README.md, docs/14-macos.md, docs/15-macos-brief.md,
  docs/07-roadmap.md, AGENTS.md, CHANGELOG.md и notes с проверенными фактами.
- [x] `cargo test -p ymd`, `bash scripts/docs-check.sh`, gitleaks,
  `git diff --check`; показать пользователю результат и состав diff.
