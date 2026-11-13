# 03. Плазмоид KDE Plasma 6

## Что это

Плазмоид `io.github.pbolkhovitin.ymd` — тонкий клиент демона `ymd`. Он не
обращается к API Яндекса и не хранит токен: только локальный HTTP API
`127.0.0.1:8765` и capability-ключ из `$XDG_RUNTIME_DIR/ymd/session.key`.

Текущий объём: компактный виджет в баре. Попап с обложкой, поиском и очередью
появится в следующих задачах порта.

## Структура пакета

~~~text
plasmoid/
├── metadata.json                 # KPackage Plasma/Applet
├── contents/
│   ├── config/
│   │   ├── main.xml              # daemonPort (Int, 8765)
│   │   ├── config.qml            # ConfigModel
│   │   └── configGeneral.qml     # страница настроек
│   └── ui/
│       ├── main.qml              # PlasmoidItem: ключ, polling, команды
│       ├── CompactRepresentation.qml
│       ├── FullRepresentation.qml
│       └── format.js             # чистые функции + Node-тесты
└── tests/format.test.js
~~~

`metadata.json` объявляет `KPackageStructure: Plasma/Applet`,
`X-Plasma-API: declarativeappletscript`, `X-Plasma-MainScript: ui/main.qml` и
версию `0.2.0`. Идентификатор пакета — `io.github.pbolkhovitin.ymd`.

## Ключ доступа

`main.qml` вызывает `ymd session-key` через `Plasma5Support.DataSource`
(`engine: "executable"`). Это argv-вызов без `sh -c`: плазмоид не собирает
командную строку из пользовательского ввода.

- ключ читается при старте и повторно раз в 5 с, пока не получен;
- при `401` ключ перечитывается один раз; если не помогло — видимая ошибка
  «Ключ не подходит», без бесконечного цикла;
- ключ живёт только в памяти QML, в настройки и файлы не пишется.

## Опрос состояния

SSE не используется. `Timer` опрашивает `GET /v1/state`:

| Состояние | Интервал |
|---|---|
| `playing` | 1 с |
| всё остальное | 3 с |

Ответ применяется только при смене `rev`, чтобы не дёргать привязки без
необходимости. При ошибке сети виджет показывает «Демон недоступен», при
таймауте — «Демон не отвечает».

Команды идут в `POST /v1/cmd` с заголовком `X-YMD-Session`; после успешной
команды состояние перечитывается сразу.

## Компактный виджет

- иконка `audio-x-generic`;
- текст «Трек — Артист», обрезка до 34 символов через `format.js`;
- tooltip: полное название и артист;
- ЛКМ — открыть/закрыть попап;
- СКМ — `toggle`;
- колесо — `prev`/`next`;
- ПКМ не перехватывается, поэтому работает контекстное меню Plasma.

Цвета — только `Kirigami.Theme`; анимаций нет. `format.js` не содержит
`#rrggbb`.

## Настройки

| Ключ | Тип | По умолчанию | Смысл |
|---|---|---|---|
| `daemonPort` | int | `8765` | порт локального API `ymd` |

Порт читается в `baseUrl()`; после изменения настроек плазмоид перезапрашивает
состояние.

## Разработка

~~~bash
# тесты чистых функций
node --test plasmoid/tests/format.test.js

# проверка структуры пакета без установки в сессию
python3 -m json.tool plasmoid/metadata.json >/dev/null
xmllint --noout plasmoid/contents/config/main.xml
rm -rf /tmp/opencode/ymd-kpackage && mkdir -p /tmp/opencode/ymd-kpackage
kpackagetool6 --type Plasma/Applet --install plasmoid \
  --packageroot /tmp/opencode/ymd-kpackage
kpackagetool6 --type Plasma/Applet --list \
  --packageroot /tmp/opencode/ymd-kpackage

# установка для текущего пользователя
kpackagetool6 --type Plasma/Applet --install plasmoid
# обновление после правок
kpackagetool6 --type Plasma/Applet --upgrade plasmoid
# удаление
kpackagetool6 --type Plasma/Applet --remove io.github.pbolkhovitin.ymd
~~~

После установки добавьте «Yandex Music» на панель. Для работы нужен запущенный
`ymd serve`; без него виджет показывает `ymd` и ошибку ключа.

## Ограничения

- `plasmoidviewer` и `qmllint6` в apt для Ubuntu 26.04 отсутствуют; QML
  проверяется установкой пакета и запуском в plasmashell.
- Плазмоид не скачивает обложки в файл: в Plasma `Image.source` принимает URL
  напрямую (в отличие от Noctalia).
- Сетевые запросы асинхронны через `XMLHttpRequest`; результат приходит в
  callback, а не в `Component.onCompleted`.
- Репозиторий на CIFS не хранит бит выполнения; скрипты запускаются через
  `bash`, а режим `100755` ставится в git через `git update-index --chmod=+x`.
