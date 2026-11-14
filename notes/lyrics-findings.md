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

## Реализация (2026-11-14)

| Что | Где |
|---|---|
| `LyricsFormat::{Text, Lrc}`, `Lyrics`, `Client::lyrics()` | `daemon/src/api.rs` |
| `sign_lyrics()` — **без** обрезки base64 (была ошибка: использовался `strip_padding`) | `daemon/src/media.rs` |
| `GET /v1/lyrics?id=&format=lrc\|text` | `daemon/src/httpd.rs` |
| `ymd lyrics <id> [--text] [--json]` | `daemon/src/main.rs` |
| Кнопка «Текст», окно ±2 строки, подсветка текущей | `noctalia/panel.luau` |

Проверено живьём (`ymd 0.2.0`, сервис `ymd.service`):

```
ymd lyrics 657960            → LRC с [00:19.67] My girlfriend, my dumb donut
ymd lyrics 657960 --text     → строки без таймкодов
GET /v1/lyrics?id=657960     → {"format":"LRC","lyricId":8195311,"major":"Musixmatch",…}
GET /v1/lyrics без ключа     → 401
```

Грабли:

- `sign_lyrics` был скопирован с `file-info` вместе с `strip_padding()` — для
  lyrics это даёт `403 Invalid Sign`. Паддинг обязателен; тест
  `lyrics_signature_keeps_padding` фиксирует длину 44 и наличие `=`.
- `RICH_JSON` не используем: у проверенных треков `result` пустой.
- Текст приходит не в JSON, а по presigned-ссылке; без авторизации, обычный GET.
