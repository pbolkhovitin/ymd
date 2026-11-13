# 03. Плазмоид KDE Plasma 6

## Что это

Плазмоид `io.github.pbolkhovitin.ymd` — тонкий клиент демона `ymd`. Он не
обращается к API Яндекса и не хранит токен: только локальный HTTP API
`127.0.0.1:8765` и capability-ключ из `$XDG_RUNTIME_DIR/ymd/session.key`.

Текущий объём: компактный виджет в баре и попап с обложкой, транспортом,
поиском, результатами и очередью.

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
│       ├── TrackRow.qml          # строка результата/очереди
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

- полупрозрачная подложка (`Kirigami.Theme.backgroundColor`, alpha 0.45)
  со скруглением и тонкой рамкой;
- иконка `audio-x-generic`;
- текст «Трек — Артист», обрезка до 34 символов через `format.js`;
- tooltip: полное название и артист;
- ЛКМ — открыть/закрыть попап;
- СКМ — `toggle`;
- колесо — `prev`/`next`;
- ПКМ не перехватывается, поэтому работает контекстное меню Plasma.

Цвета — только `Kirigami.Theme`; анимаций нет. `format.js` не содержит
`#rrggbb`.

## Попап

`FullRepresentation.qml` — один экран без вкладок и анимаций:

1. обложка 96×96 (`Image` по URL; пока не загрузилась — `audio-x-generic`);
2. название, артист, статус и качество (`playing · FLAC`), время
   `позиция / длительность`;
3. слайдер seek: значение следует за `positionMs`, пока пользователь не
   нажал; на отпускании уходит команда `seek {positionMs}`;
4. транспорт: prev, play/pause, next, like, «Волна», закрыть;
5. режимы: повтор (`off → all → one`), shuffle, качество
   (`lossless → hq → nq → lq`);
6. поиск: поле ввода, до четырёх результатов, клик запускает трек;
7. очередь: до четырёх строк, текущий трек подсвечен, клик переключает;
8. ошибка и кнопка «Повторить» (перечитывает ключ через `ymd session-key`).

Ширина попапа — `gridUnit * 24`, чтобы русские подписи кнопок не обрезались.
Цвета — `Kirigami.Theme`, иконки — системные (`media-*`, `emblem-favorite`).

### Поиск и очередь

Поиск отправляется по Enter в `GET /v1/search?q=…` с заголовком
`X-YMD-Session`; ответ — `{query, tracks: [...]}`. Показываются первые четыре
трека. Клик по результату отправляет `play_track` с объектом трека, поэтому
демон сразу получает метаданные и обложку.

Очередь приходит в `/v1/state` как `queue.items` и `queue.index`. Показываются
первые четыре строки; текущая подсвечивается. Клик отправляет
`queue_play {index}`. Полная очередь доступна через `ymd status --json`.

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

## Пакет .deb

`packaging/build-deb.sh` собирает `plasma-widget-ymd_0.2.0_all.deb`:
плазмоид ставится в `/usr/share/plasma/plasmoids/io.github.pbolkhovitin.ymd`,
файлы получают режимы `0755`/`0644` (исходники на CIFS отдают `770`/`660`).
Зависимости: `plasma-workspace`, `qml6-module-org-kde-kirigami`,
`qml6-module-org-kde-plasma-plasma5support`; рекомендуется `ymd`.

```bash
bash packaging/build-deb.sh --arch arm64
sudo apt install ./dist/plasma-widget-ymd_0.2.0_all.deb
```

## Ограничения

- `plasmoidviewer` и `qmllint6` в apt для Ubuntu 26.04 отсутствуют; QML
  проверяется установкой пакета и запуском в plasmashell.
- Плазмоид не скачивает обложки в файл: в Plasma `Image.source` принимает URL
  напрямую (в отличие от Noctalia).
- Сетевые запросы асинхронны через `XMLHttpRequest`; результат приходит в
  callback, а не в `Component.onCompleted`.
- Репозиторий на CIFS не хранит бит выполнения; скрипты запускаются через
  `bash`, а режим `100755` ставится в git через `git update-index --chmod=+x`.
