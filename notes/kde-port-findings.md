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

Сделано после KDE-порта: `ymd-qt` — тонкий клиент к тому же демону по HTTP.
Спека `docs/superpowers/specs/2026-11-13-ymd-qt-app-design.md`, план
`docs/superpowers/plans/2026-11-13-ymd-qt-app.md`, документация
`docs/11-qt-app.md`.

- C++ `YmdClient` (ключ, HTTP, polling, поиск, 401-retry), QML/Kirigami окно,
  `KStatusNotifierItem` с меню.
- Пакеты `dist/ymd-qt_0.2.0_amd64.deb` и `..._arm64.deb`; на remote
  установлены, окно и трей проверены.
- Иконки транспорта/закрытия сделаны текстовыми глифами: на remote
  Breeze-иконки не находились и `ToolButton` схлопывались.
- Меню трея на Wayland — best-effort: DBus `ContextMenu` без input serial
  не открывает popup; клик по иконке (toggle) и средняя кнопка (play/pause)
  работают. Это ограничение зафиксировано в `docs/11-qt-app.md`.

## Обложки и громкость (2026-11-13)

- Очередь/«Моя волна» не показывали обложки: API отдаёт `coverUri`, а
  `track_from_payload` читал только `cover`. Поиск уже нормализовал `coverUri`,
  поэтому там обложки были. Исправлено: `state::cover_url()` (`%%` →
  `400x400`, добавление `https://`, fallback на `/albums/0/coverUri`),
  используется и в `httpd::simplify_tracks`. 30 тестов, 3 новых.
- Громкость в демоне была готова; добавлены слайдеры в `app/qml/Main.qml` и
  `FullRepresentation.qml` (команда `volume` на отпускании, Binding обратно).
- Обложку в **компакте** панели сделать не удалось: applet 28×28,
  `formfactor=2`; QML Image получал `status=Ready`, но текстура не
  создавалась (`No QSGTexture provided from updateSampledImage()`), в панели
  оставалась нота. Попытка временно сломала `CompactRepresentation.qml`
  синтаксической ошибкой — верхняя панель исчезла до reboot. Компакт
  возвращён к статичной иконке; обложка остаётся в попапе и окне `ymd-qt`.
- Проверено на планшете: окно `ymd-qt` — обложка и слайдер 80 %; попап —
  обложка и слайдер; `volume 0.35` → state 0.35; после wave — cover URL
  `https://avatars.yandex.net/.../400x400`.

## Плейлисты, скачивание и кэш (2026-11-13)

- Список плейлистов: `GET /users/{uid}/playlists/list` отдаёт массив, но без
  треков. Треки доступны только через `GET /users/{uid}/playlists/{kind}`;
  элементы — обёртки `{track: {...}}`. В демоне добавлены
  `api::playlist(uid, kind)`, `GET /v1/playlists`, `GET /v1/playlist`,
  `GET /v1/cache`.
- `cover` плейлиста — мозаика `itemsUri` (или `uri`), нормализуется тем же
  `cover_url` (`%%` → `400x400`). ID плейлиста — `uid:kind`.
- В `Track`/`QueueItem` добавлен `cached`, в состояние — `downloads`
  (`downloading|done|error`, bytes/total). Скачивание асинхронное:
  `download_track` сразу отвечает, прогресс идёт в `state.downloads`.
  Добавлены `queue_set`, `cache_remove`, `cache_clear`, `cache_limit`.
- В Qt-окне — диалоги «Мои плейлисты» (27 шт., detail, «Играть») и
  «Офлайн-кэш» (занято/лимит, список, удаление, очистка), кнопки `⤓` в
  строках и у текущего трека, `Ctrl+P`/`Ctrl+K`. В попапе — ComboBox
  плейлистов, «Играть» и скачивание текущего трека. Компакт не трогали:
  обложка там по-прежнему не работает.
- Причина светлого окна вне сессии Plasma — отсутствие
  `XDG_CURRENT_DESKTOP=KDE`; `main.cpp` теперь выставляет его, если пусто.
- Проверено на планшете: 27 плейлистов, `rock 80-90` — 207 треков;
  `queue_set` играет; скачивание Queen «We Will Rock You» — 3 993 120 байт,
  `cached=true`, `cache_remove` очищает, `cache_limit` меняет лимит.
  Трек Bad Religion без прав вернул `403 no-rights` — ошибка видна в
  `downloads`, HTTP не блокируется. Тесты демона: 32 passed.
- Замечание: в индексе кэша `quality` берётся из настроек, а фактический
  контейнер виден в `codec` (например, `quality=lossless`, `codec=aac-mp4`),
  это не влияет на воспроизведение.

## Очередь скачивания (2026-11-14)

- Скачивание плейлиста целиком нельзя запускать параллельно: 200+ запросов
  к API и файловых дескрипторов. В демоне появился один воркер и
  `VecDeque<Track>`: `download_track` и `download_tracks` только добавляют
  треки (с дедупликацией и пропуском уже закэшированных), воркер качает по
  одному. В состоянии — `downloadPending` (сколько ждёт), `downloads` —
  текущая и последние 20 записей.
- В окне `ymd-qt` у плейлиста появилась кнопка «Скачать» (`download_tracks`),
  рядом с «Играть»; в главном окне и диалоге виден счётчик очереди.
  Плазмоид не менялся.

## Финальная проверка (2026-11-13)

- `dist/ymd_0.2.0_amd64.deb`, `dist/ymd_0.2.0_arm64.deb`,
  `dist/plasma-widget-ymd_0.2.0_all.deb` собраны; `dpkg-deb -I/-c` — архитектуры
  и права корректны, ELF-бинарники на месте.
- На `root@10.42.66.66` (aarch64) оба пакета установлены через `dpkg -i`.
  `apt-get install` не смог скачать зависимости: на машине не разрешается
  `ports.ubuntu.com`; `libsecret-tools` и `playerctl` остались не установлены,
  пакет `ymd` в состоянии «не настроен». Это не мешает запуску: все разделяемые
  библиотеки найдены (`ldd`), демон стартует, `/v1/state` и MPRIS работают.
- `systemctl --user enable --now ymd` — active; `ymd status --json` отдаёт
  состояние; `busctl --user` видит `org.mpris.MediaPlayer2.ymd`.
- Плазмоид из `.deb` (`/usr/share/plasma/plasmoids/...`) подхватился после
  перезапуска plasmashell; виджет в панели, попап показывает «Ничего не играет»,
  `paused · FLAC`, поиск и пустую очередь — без ошибки ключа.
- Перезапуск `ymd` при открытом попапе: виджет восстанавливается, состояние
  `rev: 0` приходит снова, Plasma перезапускать не нужно.
- Для полноценной проверки поиска/воспроизведения на целевой машине нужен
  токен: `ymd auth login` или `ymd auth import`.

## Управление плейлистами, очередь и метаданные (2026-11-14)

- Управление плейлистами: `playlist_create` (`title`, `visibility`),
  `playlist_delete` (`kind`), `playlist_add_tracks` (`kind`, `tracks`),
  `playlist_remove_track` (`kind`, `index`). Перед изменением демон сам
  запрашивает `/users/{uid}/playlists/{kind}` и берёт актуальный `revision`;
  diff: `insert{at,tracks:[{id,albumId}]}`, `delete{from,to}`. `like_track`
  ходит в `/likes/tracks/add-multiple|remove` (`track-ids`) и обновляет лайк
  в очереди и текущем треке.
- Очередь: `queue_move {from,to}` переставляет элемент и корректирует
  `queue.index`, поэтому играющий трек остаётся выбранным. В UI — drag&drop
  за ручку `⠿`; `queue_set`/`play_track`/`queue_*`/громкость/режимы сохраняют
  `~/.local/share/ymd/state.json` (tmp+rename), при старте `restore_state`
  восстанавливает очередь, трек, позицию, громкость и качество со статусом
  `paused`. `play`/`toggle` после рестарта резолвят поток заново.
- Метаданные: `Track.albumId`, `QueueItem.albumId/liked`, `State.bitrateKbps`;
  `resolve_url` возвращает битрейт из API или кэша, `cache::Entry.bitrate_kbps`
  сохраняется при скачивании. Статус в окне: `FLAC · 1411 кбит/с`
  (`format.js::streamLabel`).
- UI: поиск по detail плейлиста (название/артист/альбом, счётчик `N / total`),
  создание/удаление плейлиста, добавление трека из контекстного меню `⋮` или
  правого клика, удаление трека из плейлиста, «Копировать ссылку»
  (`https://music.yandex.ru/track/<id>`), «Убрать из очереди». Списки
  плейлистов и треков — `ListView` (виртуализированы), очередь — `Repeater`
  до 8.
- Сборка amd64: демон **34 passed**, Qt ctest 1/1 (7 кейсов). Плазмоид не
  менялся; новые команды ему не нужны.

## Переход к артисту/альбому и станции (2026-11-14)

- Контекстное меню в `TrackRow` теперь открывается рядом со строкой:
  `menu.popup(row, x, y)` от кнопки `⋮` (справа, под строкой) и от точки
  правого клика (`TapHandler` → `point.position`).
- В `Track`/`QueueItem` добавлен `artistId` (из `artists[0].id` API или
  `artistId` payload); `simplify_track` также отдаёт `artistId`.
- Демон: `GET /v1/artist?id=` (`/artists/{id}/info` + `/artists/{id}/tracks`)
  и `GET /v1/album?id=` (`/albums/{id}/with-tracks`, треки из `volumes`);
  ответы `{artist|album, tracks}`. `station_start {station}` ходит в
  `/rotor/station/{station}/tracks` (`track:<id>` / `artist:<id>`), берёт
  `radioSessionId`, заменяет очередь и включает первый трек; дальше работает
  существующий `wave_more`.
- UI: диалоги «Исполнитель» и «Альбом» с обложкой, списком треков и кнопками
  «Станция»/«Играть»; меню трека — «Перейти к исполнителю», «Перейти к
  альбому», «Станция по треку», «Станция по исполнителю».
- В меню добавлен пункт «Информация о треке»: диалог с обложкой, названием,
  исполнителями, альбомом, длительностью, ID трека/исполнителя/альбома,
  состоянием кэша и лайка; для играющего трека — текущий поток
  (`Format.streamLabel`).

## Иконка приложения (2026-11-14)

- `app/icons/ymd-qt.svg` — тёмный круг, белая стилизованная «Я» и play внутри
  чаши; ставится в `hicolor/scalable/apps`, `ymd-qt.desktop` использует
  `Icon=ymd-qt`.
- `main.cpp` и `tray.cpp` берут `QIcon::fromTheme("ymd-qt")`; на планшете
  иконка видна в заголовке окна и в панели задач (скриншот
  `/tmp/ymd-icon-ui.png`). Плазмоид не менялся.

## Компакт в панели (2026-11-15)

- `CompactRepresentation.qml` — только иконка `audio-x-generic` 28×28.
  В панели не показываются обложка, текст и кнопки: всё это в попапе,
  который открывается по ЛКМ. СКМ — toggle, колесо — prev/next.
- Чтобы Plasma выделила ровно 28×28, корню заданы
  `Layout.preferredWidth`/`Layout.preferredHeight`.
- На планшете applet `io.github.pbolkhovitin.ymd` добавлен в верхнюю панель
  перед системным треем; `org.kde.plasma.mediacontroller` убран из
  `extraItems` трея, чтобы не было второй иконки плеера.
- Проверено: в панели одна иконка, по клику открывается попап с обложкой,
  треком, громкостью, транспортом, поиском, плейлистами и очередью.

## Обзор и текст в попапе (2026-11-16)

- `main.qml` получил загрузчики `/v1/home`, `/v1/discovery/metatags`,
  `/v1/discovery/genres`, `/v1/favorites`, `/v1/discovery/tag`, `/v1/album`
  и `/v1/lyrics`; общий `getJson(path, onSuccess, onError)` отдаёт ошибку
  конкретному экрану, а не только в общий `lastError`.
- При смене трека `lyricsText`/`lyricsLines`/`lyricsError` сбрасываются,
  чтобы не показывать текст предыдущей песни.
- `FullRepresentation.qml` — три вида: «Сейчас», «Обзор» (вкладки
  «Главная / Каталог / Избранное», детали плейлиста/альбома/тега) и
  «Текст» (LRC, текущая и следующая строки, полный текст).
- В попапе списки ограничены 50 треками: `Repeater` на 207 треках создаёт
  слишком много делегатов; полный список — в `ymd-qt`.
- Проверка: `qmlcachegen` для обоих файлов — rc=0; главная отрисовала
  карточки блоков, текст для `Another Day in Paradise` (id 29244651)
  загрузился и подсветился; для трека без текста показывается
  «Запрос не выполнен (HTTP 404)».
- Программно открыть попап через `expanded = true` в Plasma не удалось
  (нужен реальный клик/визуальный родитель); для визуальной проверки
  временно поднимался отдельный `Window` с `FullRepresentation`, затем
  установленный `main.qml` восстановлен из чистой копии.
