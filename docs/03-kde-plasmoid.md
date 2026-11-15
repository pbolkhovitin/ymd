# 03. Плазмоид KDE Plasma 6

## Что это

Плазмоид `io.github.pbolkhovitin.ymd` — тонкий клиент демона `ymd`. Он не
обращается к API Яндекса и не хранит токен: только локальный HTTP API
`127.0.0.1:8765` и capability-ключ из `$XDG_RUNTIME_DIR/ymd/session.key`.

Текущий объём: компактный виджет в баре и попап с обложкой, громкостью,
транспортом, поиском, очередью, обзором каталога и текстом песни.

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

- в панели только иконка `audio-x-generic` 28×28;
- tooltip: полное название трека и артист;
- ЛКМ — открыть/закрыть попап со всем управлением: обложка, трек,
  громкость, транспорт, поиск, плейлисты и очередь;
- СКМ — `toggle`;
- колесо — `prev`/`next`;
- ПКМ не перехватывается, поэтому работает контекстное меню Plasma.

Виджет занимает в панели место медиаплеера: системный
`org.kde.plasma.mediacontroller` можно убрать из `extraItems` трея, чтобы
не дублировать управление. Размер компакта — 28×28 px.

Цвета — только `Kirigami.Theme`; анимаций нет. `format.js` не содержит
`#rrggbb`.

## Попап

`FullRepresentation.qml` — три вида без анимаций: «Сейчас», «Обзор» и «Текст».
Переключение — кнопками в шапке; высота попапа ограничена `gridUnit * 38`,
ширина — `gridUnit * 24`.

### «Сейчас»

1. обложка 96×96 (`Image` по URL; пока не загрузилась — `audio-x-generic`);
2. название, артист, статус и качество (`playing · FLAC`), время
   `позиция / длительность`;
3. слайдер seek: значение следует за `positionMs`, пока пользователь не
   нажал; на отпускании уходит команда `seek {positionMs}`;
4. слайдер громкости: значение следует за `volume`, пока пользователь не
   нажал; на отпускании уходит команда `volume {value}`;
5. транспорт: prev, play/pause, next, like, «Волна», закрыть;
6. режимы: повтор (`off → all → one`), shuffle, качество
   (`lossless → hq → nq → lq`);
7. поиск: поле ввода, все результаты (заголовок «Найдено · N»), клик
   запускает трек;
8. очередь: все треки (заголовок «Очередь · N»), текущий подсвечен, клик
   переключает; длинные списки прокручиваются внутри попапа;
9. кнопки «Обзор» и «Текст»; «Текст» disabled, если трек не выбран;
10. ошибка и кнопка «Повторить» (перечитывает ключ через `ymd session-key`).

### «Обзор»

- вкладки «Главная / Каталог / Избранное»;
- «Главная»: блоки `/v1/home`, горизонтальные ряды карточек; клик по
  плейлисту или альбому открывает детали, по треку — `play_track`;
- «Каталог»: жанры `/v1/discovery/genres` (клик — `station_start`), теги
  `/v1/discovery/metatags` (клик — `/v1/discovery/tag`); в теге кнопка
  «Играть волну» и список плейлистов;
- «Избранное»: `/v1/favorites`, кнопка «Играть все»;
- детали плейлиста/альбома: название, «Играть» и треки; в попапе
  показываются первые 50, полный список — в `ymd-qt`;
- кнопка «Сейчас» возвращает к плееру.

### «Текст»

- `GET /v1/lyrics?id=<trackId>&format=lrc`;
- LRC парсится в строки `{time, text}`, текущая строка подсвечивается по
  `positionMs`, следующая показывается отдельно;
- ниже — полный текст с подсветкой текущей строки; кнопка «Обновить»
  перезапрашивает текст;
- если текста нет или API вернул ошибку, показывается сообщение, а не
  бесконечная загрузка.

Цвета — `Kirigami.Theme`, иконки — системные (`media-*`, `emblem-favorite`).

### Поиск и очередь

Поиск отправляется по Enter в `GET /v1/search?q=…` с заголовком
`X-YMD-Session`; ответ — `{query, tracks: [...]}`. Показываются все
результаты, над списком — «Найдено · N». Клик по результату отправляет
`play_track` с объектом трека, поэтому демон сразу получает метаданные
и обложку.

Очередь приходит в `/v1/state` как `queue.items` и `queue.index`.
Показывается вся очередь, заголовок — «Очередь · N»; текущая подсвечивается.
Клик отправляет `queue_play {index}`. Высота попапа ограничена
`gridUnit * 38`, поэтому длинные списки прокручиваются внутри (`ScrollView`),
а не обрезаются.

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

## Пакеты .deb и .rpm

`packaging/build-deb.sh` собирает `.deb`, `packaging/build-rpm.sh` — RPM
плазмоида:
плазмоид ставится в `/usr/share/plasma/plasmoids/io.github.pbolkhovitin.ymd`,
файлы получают режимы `0755`/`0644` (исходники на CIFS отдают `770`/`660`).
Зависимости: `plasma-workspace`, `qml6-module-org-kde-kirigami`,
`qml6-module-org-kde-plasma-plasma5support`; рекомендуется `ymd`.

```bash
ver=$(bash scripts/version.sh)
bash packaging/build-deb.sh --arch arm64
sudo apt install ./dist/plasma-widget-ymd_${ver}_all.deb

bash packaging/build-rpm.sh --arch amd64
sudo dnf install ./dist/plasma-widget-ymd-${ver}-1.fc44.noarch.rpm
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
