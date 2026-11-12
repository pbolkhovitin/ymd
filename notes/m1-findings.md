# M1 — факты по API и воспроизведению

Дата: 2026-11-12. Всё ниже проверено вручную на реальном токене.

## Что работает

| Запрос | Результат |
|---|---|
| `GET /search?text=…&type=all&page=0` | 200, с токеном — `{"result":{…}}`, без токена — плоский объект |
| `GET /tracks/{id}/full-info` | 200 |
| `GET /albums/{id}/with-tracks` | 200 |
| `GET /artists/{id}/info` | 200 |
| `GET /account/about` | 200, `login=pbolkhovitin uid=12967407 plus=true` |

Реализовано в `daemon/src/api.rs`, CLI: `ymd search`, `ymd track`, `ymd album`,
`ymd artist`, `ymd stream`.

## Что не работает (блокер)

### 1. `file-info` → 403 `not-allowed`

```
GET /resources/v2/file-info?ts=…&trackId=…&quality=…&codecs=…&transports=raw&sign=…
→ 403 {"result":{"name":"track-download-info-error","message":"not-allowed"}}
```

Проверено:

- `/resources/v2/file-info` и `/get-file-info` — оба 403;
- все четыре `secretKey` (linux/web/win/mac) — 403;
- качества `nq/mp3`, `hq/aac`, `lossless/flac` — 403;
- с `x-yandex-music-device` и с `x-yandex-music-without-invocation-info: 1` — 403;
- подпись собрана точно как в рендерере официального клиента:
  `btoa(HMAC-SHA256(secretKey, ts+trackId+quality+codecs+transports)).slice(0,-1)`
  (найдено в `_next/static/chunks/9616-*.js` и `app/(product)/layout-*.js`).

Вывод: сервер отказывает не из-за подписи, а из-за клиента/аккаунта
(вероятно, нужна аттестация клиента — `x-ya-service-ticket`/`x-ya-user-ticket`).

### 2. `download-info` → XML → 401

```
GET /tracks/{id}/download-info → 200, downloadInfoUrl
GET <downloadInfoUrl> → 200, XML: <host> <path> <ts> <region> <s>
GET https://<host><path> → 401
```

Варианты `?ts=`, `?ts=&s=`, `?ts=&region=`, `?s=`, с `Authorization`,
с `x-yandex-music-client`, с `Range` — все 401 (host `mds.storage.yandex.net`).

## Решение для M1

Пока прямой поток недоступен, бар управляет **любым MPRIS-плеером**
(включая официальный Яндекс Музыка) через `playerctl`:

- демон читает `status`, `metadata` (`title`, `artist`, `artUrl`, `mpris:length`),
  `position` раз в секунду;
- команды `toggle/next/prev/seek` транслируются в `playerctl`;
- когда поток появится, MPRIS станет исходящим (демон сам станет плеером),
  контракт `/v1/state` и плагин не меняются.

Это даёт работающий бар уже сейчас и не блокирует M2.


## Панель: ui.input и песочница (проверено 2026-11-12)

| Проверка | Результат |
|---|---|
| `_G["fn"] = function() end` | **ошибка**: `attempt to modify a readonly table` — `_G` только для чтения |
| объявление `function name()` на верхнем уровне | работает, `ui.button{onClick="name"}` находит |
| `ui.input{ text = ... }` | `[ui-tree] 'input' has no prop 'text', ignored` |
| `ui.input{ value = ..., placeholder = ..., onSubmit = "fn", submitOnEnter = true, multiline = false }` | без предупреждений — пропсы приняты |
| hot reload панели | работает: file-watcher перезагружает `panel.luau` |

Правило: обработчики для `onClick`/`onSubmit` — только явные глобальные функции,
никаких динамических имён через `_G`.

## Контракт состояния: camelCase

Rust сериализовал `position_ms`, а плагин читал `positionMs` — прогресс в баре и
панели не работал. Исправлено `#[serde(rename_all = "camelCase")]` на `State`,
`Track`, `Queue`, `QueueItem`, `EnvState`, `UiState`. Тест
`state_serializes_camel_case` фиксирует контракт.


## РЕШЕНО: поток починен (2026-11-12)

Причина `403` — несовпадение пары «заголовок клиента + ключ подписи».
Подробный разбор и точные параметры — `notes/reference-yandex-music-api.md`.

Коротко:

- `/get-file-info` с `X-Yandex-Music-Client: YandexMusicDesktopAppWindows/5.95.0`
  и ключом `kzqU4XhfCaY6B6JTHODeq5` → `200`, `result.downloadInfo.url` — CDN-ссылка
  (`206` на Range, `ftypisom`).
- качества: `lossless` → `flac-mp4`, `hq` → `aac-mp4 256`, `nq` → `aac-mp4 192`.
- резервный путь `/download-info` требует ссылку вида
  `/get-mp3/{md5(salt+path[1:]+s)}/{ts}{path}` — без неё был `401`.

Реализовано в `daemon/src/api.rs` (`stream` → `file_info` с фоллбэком на
`download_info_stream`), `daemon/src/media.rs` (`DESKTOP_CLIENT`,
`DESKTOP_SIGN_KEY`, `SIGN_SALT`, `direct_link`, `FILE_INFO_CODECS`).

Вход без токена из чужого Local Storage: `ymd auth login` (Device Flow,
`daemon/src/oauth.rs`), проверено выдачи кода (`https://ya.ru/device`, код 8 символов).
