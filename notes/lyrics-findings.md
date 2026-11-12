# Тексты песен: разведка API

Дата: 2026-11-13. Проверено на живом аккаунте, трек `657960` (The Offspring — Spare Me The Details).

## Эндпоинт

```
GET /tracks/{trackId}/lyrics
    ?format=TEXT|LRC|RICH_JSON
    &timeStamp=<unix seconds>
    &sign=<base64(HMAC-SHA256(key, trackId + timeStamp))>
```

Заголовки: `authorization: OAuth …`, `x-yandex-music-client: YandexMusicDesktopAppWindows/5.95.0`.

## Подпись — ДРУГАЯ, чем у `file-info`

| Параметр | `file-info` | `lyrics` |
|---|---|---|
| ключ | linux `uVNvVMAvdrvjtwN0VlhEt2` (с парным заголовком) | **windows** `kzqU4XhfCaY6B6JTHODeq5` |
| заголовок клиента | `…Windows/5.95.0` (пара к ключу) | `…Windows/5.95.0` |
| данные | `ts + ids + quality + codecs + transport` | **`trackId + ts`** |
| обрезка base64 | последний символ убирается | **не убирается** (полный base64 с `=`) |

Матрица проверок (все — `403 {"error":{"name":"Invalid Sign"}}`, кроме последней):

| ключ | данные | обрезка | итог |
|---|---|---|---|
| linux | trackId+ts | да | 403 |
| linux | trackId+ts | нет | 403 |
| windows | ts+trackId | да/нет | 403 |
| windows | trackId+ts | да | 403 |
| **windows** | **trackId+ts** | **нет** | **200** |

## Ответ: текста в JSON нет

```json
{"result": {
  "downloadUrl": "https://music-lyric.s3-private.mds.yandex.net/…&X-Amz-Signature=…",
  "lyricId": 8195311,
  "externalLyricId": "87153",
  "writers": ["Bryan Holland"],
  "major": {"id": 560, "name": "MUSIXMATCH", "prettyName": "Musixmatch"}
}}
```

Текст нужно забрать вторым запросом по `downloadUrl` (presigned S3, без авторизации):

```
200, content-type: application/octet-stream

[00:19.67] My girlfriend, my dumb donut
[00:22.71] Went up to a party just the other night
…
```

`TEXT` — тот же presigned URL, но без таймкодов. `RICH_JSON` для этого трека вернул
пустой `result` — формат не проверен.

## Что учесть в реализации

- Ссылка S3 временная — кэшировать сам текст, а не URL.
- LRC-строки `[mm:ss.xx]` парсятся тривиально → можно подсвечивать текущую строку
  по `positionMs`.
- `stream()`-клиент уже умеет `fetch_range`, но для S3 авторизация не нужна:
  обычный GET без заголовков.
- Ошибки: нет текста у трека → `404`/пустой `result`; истёкший `timeStamp` → `403`.
