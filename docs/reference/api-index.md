# Индекс API Яндекс Музыки

Сгенерировано из `docs/reference/ym-openapi.json` (144 пути, 22 раздела).
Источник: https://ym.marshal.dev/api/

`+` — уже используется в `daemon/`; пусто — ещё нет.

## OAuth Device Flow (2)

| | Метод | Путь | Что делает |
|---|---|---|---|
| + | POST | `/device/code` | Запрос кода устройства для OAuth Device Flow. |
| + | POST | `/token` | Однократный опрос статуса подтверждения кода устройства. |

## Авторы контента (2)

| | Метод | Путь | Что делает |
|---|---|---|---|
|  | GET | `/clips/{clip_id}/credits` | Получение информации об участниках создания клипа. |
|  | GET | `/tracks/{track_id}/credits` | Получение информации об участниках создания трека. |

## Аккаунт (8)

| | Метод | Путь | Что делает |
|---|---|---|---|
|  | POST | `/account/consume-promo-code` | Активация промо-кода. |
|  | GET | `/account/experiments` | Получение значений экспериментальных функций аккаунта. |
|  | GET | `/account/experiments/details` | Получение детальной информации об экспериментальных функциях аккаунта. |
|  | GET | `/account/settings` | Получение настроек текущего пользователя. |
|  | POST | `/account/settings` | Изменение настроек текущего пользователя. |
|  | GET | `/account/status` | Получение статуса аккаунта. Нет обязательных параметров. |
|  | GET | `/permission-alerts` | Получение оповещений. Нет обязательных параметров. |
|  | GET | `/settings` | Получение предложений по покупке. Нет обязательных параметров. |

## Альбомы (4)

| | Метод | Путь | Что делает |
|---|---|---|---|
|  | POST | `/albums` | Получение альбома/альбомов. |
|  | GET | `/albums/{album_id}/similar-entities` | Получение похожих сущностей для альбома. |
|  | GET | `/albums/{album_id}/trailer` | Получение трейлера альбома. |
| + | GET | `/albums/{album_id}/with-tracks` | Получение альбома по его уникальному идентификатору вместе с треками. |

## Артисты (16)

| | Метод | Путь | Что делает |
|---|---|---|---|
|  | POST | `/artists` | Получение исполнителя/исполнителей. |
|  | GET | `/artists/{artist_id}/about-artist` | Получение информации «Об артисте». |
|  | GET | `/artists/{artist_id}/also-albums` | Получение сборников и альбомов, в которых участвовал артист. |
|  | GET | `/artists/{artist_id}/artist-links` | Получение ссылок на страницы артиста. |
|  | GET | `/artists/{artist_id}/blocks/artist-clips` | Получение клипов артиста. |
|  | GET | `/artists/{artist_id}/blocks/artist-donation` | Получение информации о донатах артиста. |
|  | GET | `/artists/{artist_id}/brief-info` | Получение информации об артисте. |
|  | GET | `/artists/{artist_id}/direct-albums` | Получение альбомов артиста. |
|  | GET | `/artists/{artist_id}/discography-albums` | Получение дискографии артиста. |
| + | GET | `/artists/{artist_id}/info` | Получение подробной информации об артисте. |
|  | GET | `/artists/{artist_id}/safe-direct-albums` | Получение безопасных альбомов артиста. |
|  | GET | `/artists/{artist_id}/similar` | Получение похожих артистов. |
|  | GET | `/artists/{artist_id}/skeletons/web-artist-default` | Получение скелетона страницы артиста. |
|  | GET | `/artists/{artist_id}/track-ids` | Получение идентификаторов треков артиста. |
|  | GET | `/artists/{artist_id}/tracks` | Получение треков артиста. |
|  | GET | `/artists/{artist_id}/trailer` | Получение трейлера артиста. |

## Видеоклипы (2)

| | Метод | Путь | Что делает |
|---|---|---|---|
|  | GET | `/clips` | Получение клипов по идентификаторам. |
|  | GET | `/clips/will/like` | Получение подборки рекомендуемых клипов. |

## Волна (3)

| | Метод | Путь | Что делает |
|---|---|---|---|
|  | GET | `/rotor/wave/last` | Получение последней запущенной волны пользователя. |
|  | POST | `/rotor/wave/last/reset` | Сброс последней запущенной волны пользователя на «Мою волну». |
|  | GET | `/rotor/wave/settings` | Получение настроек волны: контекстов (занятий) и доступных значений настроек. |

## Дисклеймеры (4)

| | Метод | Путь | Что делает |
|---|---|---|---|
|  | GET | `/albums/{album_id}/disclaimer` | Получение дисклеймера альбома. |
|  | GET | `/artists/{artist_id}/disclaimer` | Получение дисклеймера артиста. |
|  | GET | `/clips/{clip_id}/disclaimer` | Получение дисклеймера клипа. |
|  | GET | `/tracks/{track_id}/disclaimer` | Получение дисклеймера трека. |

## Закреплённые (9)

| | Метод | Путь | Что делает |
|---|---|---|---|
|  | DELETE | `/pin/album` | Открепление альбома. |
|  | PUT | `/pin/album` | Закрепление альбома. |
|  | DELETE | `/pin/artist` | Открепление артиста. |
|  | PUT | `/pin/artist` | Закрепление артиста. |
|  | DELETE | `/pin/playlist` | Открепление плейлиста. |
|  | PUT | `/pin/playlist` | Закрепление плейлиста. |
|  | DELETE | `/pin/wave` | Открепление волны. |
|  | PUT | `/pin/wave` | Закрепление волны. |
|  | GET | `/pins` | Получение списка закреплённых элементов. |

## История прослушивания (2)

| | Метод | Путь | Что делает |
|---|---|---|---|
|  | GET | `/music-history` | Получение истории прослушивания. |
|  | POST | `/music-history/items` | Получение элементов истории прослушивания по списку идентификаторов. |

## Концерты (6)

| | Метод | Путь | Что делает |
|---|---|---|---|
|  | GET | `/artists/{artist_id}/concerts` | Получение концертов артиста. |
|  | GET | `/concerts/feed` | Получение ленты концертов. |
|  | GET | `/concerts/locations` | Получение списка местоположений для фильтрации концертов. |
|  | GET | `/concerts/tab-config` | Получение конфигурации вкладок концертов. |
|  | GET | `/concerts/{concert_id}/info` | Получение информации о концерте. |
|  | GET | `/concerts/{concert_id}/skeletons/concert_page` | Получение скелетона страницы концерта. |

## Лайки и дизлайки (21)

| | Метод | Путь | Что делает |
|---|---|---|---|
|  | GET | `/users/{user_id}/dislikes/artists` | Получение исполнителей с отметкой "Не рекомендовать". |
|  | POST | `/users/{user_id}/dislikes/artists/add-multiple` | Поставить отметку "Не рекомендовать" исполнителю. |
|  | POST | `/users/{user_id}/dislikes/artists/remove` | Снять отметку "Не рекомендовать" у исполнителя. |
|  | GET | `/users/{user_id}/dislikes/tracks` | Получение треков с отметкой "Не рекомендовать". |
|  | POST | `/users/{user_id}/dislikes/tracks/add-multiple` | Поставить отметку "Не рекомендовать" треку/трекам. |
|  | POST | `/users/{user_id}/dislikes/tracks/remove` | Снять отметку "Не рекомендовать" у трека/треков. |
|  | GET | `/users/{user_id}/likes/albums` | Получение альбомов с отметкой "Мне нравится". |
|  | POST | `/users/{user_id}/likes/albums/add-multiple` | Поставить отметку "Мне нравится" альбому/альбомам. |
|  | POST | `/users/{user_id}/likes/albums/remove` | Снять отметку "Мне нравится" у альбома/альбомов. |
|  | GET | `/users/{user_id}/likes/artists` | Получение артистов с отметкой "Мне нравится". |
|  | POST | `/users/{user_id}/likes/artists/add-multiple` | Поставить отметку "Мне нравится" исполнителю/исполнителям. |
|  | POST | `/users/{user_id}/likes/artists/remove` | Снять отметку "Мне нравится" у исполнителя/исполнителей. |
|  | GET | `/users/{user_id}/likes/clips` | Получение клипов с отметкой "Мне нравится". |
|  | POST | `/users/{user_id}/likes/clips/add` | Поставить отметку "Мне нравится" клипу. |
|  | POST | `/users/{user_id}/likes/clips/{clip_id}/remove` | Снять отметку "Мне нравится" у клипа. |
|  | GET | `/users/{user_id}/likes/playlists` | Получение плейлистов с отметкой "Мне нравится". |
|  | POST | `/users/{user_id}/likes/playlists/add-multiple` | Поставить отметку "Мне нравится" плейлисту/плейлистам. |
|  | POST | `/users/{user_id}/likes/playlists/remove` | Снять отметку "Мне нравится" у плейлиста/плейлистов. |
| + | GET | `/users/{user_id}/likes/tracks` | Получение треков с отметкой "Мне нравится". |
|  | POST | `/users/{user_id}/likes/tracks/add-multiple` | Поставить отметку "Мне нравится" треку/трекам. |
|  | POST | `/users/{user_id}/likes/tracks/remove` | Снять отметку "Мне нравится" у трека/треков. |

## Лейблы (3)

| | Метод | Путь | Что делает |
|---|---|---|---|
|  | GET | `/labels/{label_id}` | Получение информации о лейбле. |
|  | GET | `/labels/{label_id}/albums` | Получение альбомов лейбла. |
|  | GET | `/labels/{label_id}/artists` | Получение артистов лейбла. |

## Лендинг и фид (9)

| | Метод | Путь | Что делает |
|---|---|---|---|
|  | GET | `/feed` | Получение потока информации (фида) подобранного под пользователя. Содержит умные плейлисты. |
|  | GET | `/feed/wizard/is-passed` | Получение информации о прохождении визарда. |
|  | GET | `/genres` | Получение жанров музыки. |
|  | GET | `/landing3` | Получение лендинг-страницы содержащий блоки с новыми релизами, чартами, плейлистами с новинками и т.д. |
|  | GET | `/landing3/chart` | Получение чарта. |
|  | GET | `/landing3/new-playlists` | Получение полного списка всех новых плейлистов. |
|  | GET | `/landing3/new-releases` | Получение полного списка всех новых релизов (альбомов). |
|  | GET | `/landing3/podcasts` | Получение подкастов с лендинга. |
|  | GET | `/tags/{tag_id}/playlist-ids` | Получение тега (подборки). |

## Метатеги (5)

| | Метод | Путь | Что делает |
|---|---|---|---|
|  | GET | `/landing3/metatags` | Получение дерева метатегов. |
|  | GET | `/metatags/{metatag_id}` | Получение информации о метатеге. |
|  | GET | `/metatags/{metatag_id}/albums` | Получение альбомов метатега. |
|  | GET | `/metatags/{metatag_id}/artists` | Получение артистов метатега. |
|  | GET | `/metatags/{metatag_id}/playlists` | Получение плейлистов метатега. |

## Очередь (4)

| | Метод | Путь | Что делает |
|---|---|---|---|
|  | GET | `/queues` | Получение всех очередей треков с разных устройств для синхронизации между ними. |
|  | POST | `/queues` | Создание новой очереди треков. |
|  | GET | `/queues/{queue_id}` | Получение информации об очереди треков и самих треков в ней. |
|  | POST | `/queues/{queue_id}/update-position` | Установка текущего индекса проигрываемого трека в очереди треков. |

## Плейлисты (18)

| | Метод | Путь | Что делает |
|---|---|---|---|
|  | GET | `/playlist/{playlist_uuid}` | Получение плейлиста по его UUID. |
|  | GET | `/playlist/{playlist_uuid}/similar-entities` | Получение похожих сущностей для плейлиста. |
|  | GET | `/playlists` | Получение списка плейлистов по идентификаторам. |
|  | POST | `/playlists/collective/join` | Присоединение к плейлисту как соавтор. |
|  | POST | `/playlists/list` | Получение плейлиста/плейлистов. |
|  | GET | `/playlists/personal/{playlist_id}` | Получение персонального плейлиста. |
|  | POST | `/users/{user_id}/playlists` | Получение плейлиста или списка плейлистов по уникальным идентификаторам. |
|  | POST | `/users/{user_id}/playlists/create` | Создание плейлиста. |
| + | GET | `/users/{user_id}/playlists/list` | Получение списка плейлистов пользователя. |
|  | GET | `/users/{user_id}/playlists/list/kinds` | Получение списка идентификаторов (kind) плейлистов пользователя. |
|  | POST | `/users/{user_id}/playlists/{kind}/change` | Изменение плейлиста. |
|  | POST | `/users/{user_id}/playlists/{kind}/delete` | Удаление плейлиста. |
|  | POST | `/users/{user_id}/playlists/{kind}/description` | Изменение описания плейлиста. |
|  | POST | `/users/{user_id}/playlists/{kind}/name` | Изменение названия плейлиста. |
|  | GET | `/users/{user_id}/playlists/{kind}/recommendations` | Получение рекомендаций для плейлиста. |
|  | GET | `/users/{user_id}/playlists/{kind}/trailer` | Получение трейлера плейлиста. |
|  | POST | `/users/{user_id}/playlists/{kind}/visibility` | Изменение видимости плейлиста. |
|  | GET | `/users/{user_id}/settings` | Получение настроек пользователя. |

## Поиск (2)

| | Метод | Путь | Что делает |
|---|---|---|---|
| + | GET | `/search` | Осуществление поиска по запросу и типу, получение результатов. |
|  | GET | `/search/suggest` | Получение подсказок по введенной части поискового запроса. |

## Предсохранения (3)

| | Метод | Путь | Что делает |
|---|---|---|---|
|  | GET | `/users/{user_id}/presaves` | Получение списка предсохранённых альбомов. |
|  | POST | `/users/{user_id}/presaves/add` | Предсохранение альбома. |
|  | POST | `/users/{user_id}/presaves/remove` | Удаление предсохранения альбома. |

## Радио (8)

| | Метод | Путь | Что делает |
|---|---|---|---|
|  | GET | `/rotor/account/status` | Получение статуса пользователя с дополнительными полями. |
|  | POST | `/rotor/station/{station}/feedback` | Отправка обратной связи на действия при прослушивании радио. |
|  | GET | `/rotor/station/{station}/info` | Получение информации о станции и пользовательских настроек на неё. |
|  | POST | `/rotor/station/{station}/settings3` | Изменение настроек определённой станции. |
|  | GET | `/rotor/station/{station}/stream` | Получение информации о генеративной станции и её потока. |
|  | GET | `/rotor/station/{station}/tracks` | Получение цепочки треков определённой станции. |
|  | GET | `/rotor/stations/dashboard` | Получение рекомендованных станций текущего пользователя. |
|  | GET | `/rotor/stations/list` | Получение всех радиостанций с настройками пользователя. |

## Сессии радио (9)

| | Метод | Путь | Что делает |
|---|---|---|---|
|  | POST | `/rotor/combined/session/landing` | Получение витрины комбинированной сессии радио (например, «Время клипов»). |
|  | POST | `/rotor/combined/session/new` | Создание комбинированной сессии радио (треки и клипы). |
|  | POST | `/rotor/combined/session/{session_id}/next` | Получение следующих элементов комбинированной сессии радио. |
|  | POST | `/rotor/session/new` | Создание новой сессии радио. |
|  | POST | `/rotor/session/{radio_session_id}/clone` | Создание новой сессии радио на основе существующей (с теми же сидами). |
|  | POST | `/rotor/session/{radio_session_id}/feedback` | Отправка обратной связи сессии радио. |
|  | POST | `/rotor/session/{radio_session_id}/feedbacks` | Отправка нескольких событий обратной связи сессии радио одним запросом. |
|  | POST | `/rotor/session/{radio_session_id}/tracks` | Получение следующей партии треков сессии радио. |
|  | POST | `/rotor/sessions/feedbacks` | Отправка обратной связи сразу по нескольким сессиям радио. |

## Треки (10)

| | Метод | Путь | Что делает |
|---|---|---|---|
|  | GET | `/after-track` | Получение рекламы или шота от Алисы после трека. |
| + | GET | `/get-file-info` | Получение информации о файле трека, в том числе в lossless качестве. |
|  | POST | `/play-audio` | Метод для отправки текущего состояния прослушиваемого трека. |
|  | POST | `/tracks` | Получение трека/треков. |
| + | GET | `/tracks/{track_id}/download-info` | Получение информации о доступных вариантах загрузки трека. |
| + | GET | `/tracks/{track_id}/full-info` | Получение полной информации о треке. |
|  | GET | `/tracks/{track_id}/lyrics` | Получение текста трека. |
|  | GET | `/tracks/{track_id}/similar` | Получение похожих треков. |
|  | GET | `/tracks/{track_id}/supplement` | Получение дополнительной информации о треке. |
|  | GET | `/tracks/{track_id}/trailer` | Получение трейлера трека. |
## Что брать по этапам

### M2 — собственный плеер

| Метод | Путь | Зачем |
|---|---|---|
| GET | `/get-file-info` | прямая CDN-ссылка (raw), все качества |
| GET | `/tracks/{track_id}/full-info` | метаданные для панели и MPRIS |
| GET | `/tracks/{track_id}/lyrics` | текст в панели (подпись `sign`/`timeStamp`) |
| POST | `/play-audio` | отчёт о прослушивании |
| GET | `/after-track` | «похожее» после трека |
| POST | `/users/{user_id}/likes/tracks/add-multiple` | лайк |
| POST | `/users/{user_id}/likes/tracks/remove` | снятие лайка |

### M3 — офлайн

| Метод | Путь | Зачем |
|---|---|---|
| GET | `/get-file-info` (`transports=encraw`) | зашифрованный файл + `key` |
| GET | `/tracks/{track_id}/download-info` | резервный путь mp3/aac |

Кэш и расшифровка — наши, API отдаёт только `key` и `urls`.

### M4 — волна, радио, очередь

| Метод | Путь | Зачем |
|---|---|---|
| POST | `/rotor/session/new` | «Моя волна», старт |
| POST | `/rotor/session/{id}/tracks` | следующие треки |
| POST | `/rotor/session/{id}/feedback` | лайк/дизлайк/скип |
| GET | `/rotor/wave/last` | продолжить последнюю волну |
| POST | `/queues`, `/queues/{id}/update-position` | серверная очередь (синхронизация) |

### Не нужно

`/account/consume-promo-code`, `/clips/*`, `/concerts/*`, `/metatags/*`,
`/disclaimers/*`, аналитика (`/play-audio` — только если хотим учитывать
прослушивания).
