# Разбор `MarshalX/yandex-music-api` — что взяли

Неофициальная Python-библиотека (LGPL-3), самая полная реализация внутреннего API
Яндекс Музыки. Разобрана 2026-11-12, версия из `main`.

- Репозиторий: https://github.com/MarshalX/yandex-music-api
- Документация: https://ym.marshal.dev/
- OpenAPI-спецификация (144 пути): https://ym.marshal.dev/api/openapi.json

Копия спецификации лежит в `docs/reference/ym-openapi.json` — используем как
справочник по параметрам, схемам и кодам ответов.

## 1. Почему у нас был `403` на `/get-file-info`

Ключ подписи жёстко связан с заголовком `X-Yandex-Music-Client`:

| Заголовок | Ключ |
|---|---|
| `YandexMusicDesktopAppWindows/5.95.0` | `kzqU4XhfCaY6B6JTHODeq5` |
| Android-приложение | `p93jhgh689SBReK6ghtw62` |

Мы отправляли `YandexMusicDesktopApp` (без версии и платформы) с ключом Linux-сборки —
сервер отвечал `403 not-allowed`. Пара должна совпадать.

Правильный запрос:

```
GET https://api.music.yandex.ru/get-file-info
  ?ts=<unix>
  &trackId=<id>
  &quality=lossless|hq|nq
  &codecs=flac,flac-mp4,aac-mp4,he-aac-mp4,aac,he-aac,mp3
  &transports=raw
  &sign=<base64(HMAC-SHA256(key, ts + trackId + quality + codecs.concat + transport))[:-1]>
X-Yandex-Music-Client: YandexMusicDesktopAppWindows/5.95.0
Authorization: OAuth <token>
```

Тонкость: **в подписи кодеки конкатенируются без разделителя**, а в query идут
через запятую.

Ответ: `{"result":{"downloadInfo":{...}}}` — **единственное число**, не
`downloadInfos`. Поля: `trackId`, `quality`, `codec`, `bitrate`, `transport`,
`gain`, `urls[]`, `url`, ключ `key` для `encraw`.

Проверено на аккаунте с Plus:

| quality | codec | bitrate |
|---|---|---|
| `lossless` | `flac-mp4` | — |
| `hq` | `aac-mp4` | 256 |
| `nq` | `aac-mp4` | 192 |

Ссылка `url` — прямой CDN (`strm.yandex.net`), отдаёт `206` на `Range`,
MP4 с `ftypisom`.

## 2. Резервный путь: `/tracks/{id}/download-info`

Отдаёт варианты `mp3/aac` с `downloadInfoUrl`. XML содержит `host`, `path`, `ts`, `s`,
а ссылка строится не как `https://{host}{path}`, а так:

```
sign = md5("XGRlBW9FXlekgbPrRHuSiA" + path[1:] + s)
url  = https://{host}/get-mp3/{sign}/{ts}{path}
```

Соль `XGRlBW9FXlekgbPrRHuSiA`, `md5` — hex. Ссылка живёт ~1 минуту (иначе `410`).
Именно из-за пропущенного `/get-mp3/{md5}` мы раньше получали `401`.

## 3. OAuth Device Flow (вход без копирования токена)

Публичные креды Android-приложения:

```
client_id     23cabbbdc6cd418abb4b39c32c41195d
client_secret 53bc75238f0c4d08a118e51fe9203300
```

Поток:

1. `POST https://oauth.yandex.ru/device/code` — `client_id`, `device_id` (10 символов),
   `device_name`. Ответ: `device_code`, `user_code`, `verification_url`
   (у нас пришёл `https://ya.ru/device`), `interval`, `expires_in`.
2. Пользователь открывает URL и вводит `user_code`.
3. `POST https://oauth.yandex.ru/token` — `grant_type=device_code`, `code`,
   `client_id`, `client_secret`. Пока не подтверждено — `400 authorization_pending`;
   при частых запросах — `slow_down` (увеличить интервал).

Ответ: `access_token`, `refresh_token`, `expires_in` (~год), `token_type`.

Это снимает необходимость регистрировать собственное OAuth-приложение:
у новых клиентов Яндекса нет доступа к scope `music:*`.

## 4. Прочее, что пригодится

- `quality`: `lossless`, `hq`, `nq` (в библиотеке; `lq` мы используем как синоним `nq`).
- `transport`: `raw` (поток) и `encraw` (офлайн; расшифровка AES-CTR, пакет `cryptography`).
- Библиотека поддерживает Ynison (WebSocket) и радио-сессии — совпадает с нашими
  планами M3/M4.
- Толерантность к схеме: неизвестные/отсутствующие поля → `None`, а не падение.
  Это подтверждает наш подход с `serde_json::Value` и ручным разбором.
- `FileInfo`/`DownloadInfo` модели — хороший ориентир для типизации в M2.
