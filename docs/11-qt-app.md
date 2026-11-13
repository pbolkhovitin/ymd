# 11. Приложение `ymd-qt`

Отдельное окно на Qt 6 / Kirigami для тех, кому не нужен плазмоид в панели.
Это **тонкий клиент**: токен, API Яндекса, GStreamer, MPRIS и кэш остаются
в демоне `ymd`; приложение общается с ним по локальному HTTP.

## Зачем

- Полноценное окно с обложкой, поиском и очередью — удобнее попапа.
- Работает одновременно с плазмоидом: оба читают один `/v1/state`.
- Не дублирует авторизацию и не хранит токен.
- Закрытие окна прячет приложение в трей, воспроизведение продолжается.

## Установка

```bash
sudo apt install ./ymd_0.2.0_arm64.deb ./ymd-qt_0.2.0_arm64.deb
systemctl --user enable --now ymd
```

На amd64 — те же пакеты с `_amd64`. Приложение зависит от `ymd` и QML-модулей
Kirigami/Quick Controls; `apt` подтянет их из репозитория.

Запуск:

```bash
ymd-qt
```

Или через меню приложений: **Yandex Music**.

## Сборка

```bash
bash packaging/build-qt-deb.sh --arch amd64   # или arm64
```

Сборка идёт в Docker (`packaging/Dockerfile.qt`, Ubuntu 26.04, Qt 6.10,
Kirigami 6.24). Результат — `dist/ymd-qt_0.2.0_<arch>.deb`.

Тесты бэкенда:

```bash
bash packaging/build-qt-deb.sh --arch amd64   # внутри запускается ctest
```

## Архитектура

| Файл | Что делает |
|---|---|
| `app/src/ymdclient.{h,cpp}` | ключ, HTTP/JSON, polling 1 с/3 с, команды, поиск, 401-retry |
| `app/src/tray.{h,cpp}` | `KStatusNotifierItem`: показать окно, play/pause, next/prev, выход |
| `app/src/main.cpp` | `QApplication`, связка QML ↔ клиент ↔ трей |
| `app/qml/Main.qml` | окно: обложка, seek, громкость, транспорт, режимы, поиск, очередь, ошибки |
| `app/qml/TrackRow.qml` | строка трека для результатов и очереди |
| `app/qml/format.js` | общая копия `plasmoid/contents/ui/format.js` |

`YmdClient` читает ключ из `$XDG_RUNTIME_DIR/ymd/session.key`; если файла нет —
вызывает `ymd session-key`. Каждый запрос идёт с `X-YMD-Session`. При 401 ключ
перечитывается один раз; повторный 401 показывает ошибку и останавливает polling.
Таймаут запроса — 5 секунд.

## Поведение

- ЛКМ по иконке в трее — показать/скрыть окно.
- Средняя кнопка — play/pause.
- Меню трея — показать окно, play/pause, next/prev, выход.
- Закрытие окна (`X`) прячет его в трей; `Ctrl+Q` завершает приложение.
- Горячие клавиши: `Space` — play/pause, `←`/`→` — seek ±5 с,
  `Ctrl+F` — поиск, `Esc` — скрыть окно.
- Никаких анимаций и `#rrggbb`: только `Kirigami.Theme` и палитра Controls.

## Ограничения

- Меню трея на Wayland может не открываться при вызове через DBus
  (`ContextMenu` без input serial); клик по иконке и средняя кнопка работают.
  Это ограничение окружения, а не логики приложения.
- Приложение не работает без запущенного `ymd`: показывает «Ключ не найден»
  и кнопку «Повторить».
- Обложка грузится по URL; при отсутствии сети остаётся заглушка.
- Пока нет текстов песен, докачки и Ynison — как и у плазмоида.

## Проверки

- `ctest` — 6 тестов `YmdClient` (state, command, search, 401, missing key).
- `cmp app/qml/format.js plasmoid/contents/ui/format.js`.
- `bash scripts/docs-check.sh` → `ok`.
- Ручной smoke: окно, поиск, очередь, seek, трей, закрытие в трей.
