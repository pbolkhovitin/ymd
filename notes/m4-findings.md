# M4: «Моя волна» (rotor)

Дата: 2026-11-13. Проверено на живом аккаунте.

## Эндпоинты

| Метод | Путь | Тело | Ответ |
|---|---|---|---|
| POST | `/rotor/session/new` | `{}` | `result.radioSessionId`, `result.batchId`, `result.sequence[]` |
| POST | `/rotor/session/{id}/tracks` | `{}` | `result.batchId`, `result.sequence[]`, `total` |
| POST | `/rotor/session/{id}/feedbacks` | `{"feedback":[{"type":"like","trackId":"…","batchId":"…"}]}` | `{"result":{}}` |

Обязательные условия: заголовки `authorization: OAuth …`,
`x-yandex-music-client: YandexMusicDesktopAppWindows/5.95.0`, `content-type: application/json`.

### Грабля: одиночный `/feedback` не работает

`POST /rotor/session/{id}/feedback` (единственное число) **не отдаёт HTTP-ответ** —
соединение закрывается (curl: код `000`, иногда `HTTP/2 stream …`). Работает только
множественный `/feedbacks` с массивом в поле `feedback`.

Форм-данные (`application/x-www-form-urlencoded`) отклоняются с `415`.

### Формат `sequence`

Элементы — не треки, а обёртки:

```json
{"type": "track", "liked": false, "track": {"id": "104620810", "title": "…", "artists": [...], "albums": [...]}, "trackParameters": {...}}
```

Поле `type` бывает не только `track` (в комбинированных сессиях — клипы), поэтому
треки фильтруются по наличию вложенного `track`.

## Что сделано в демоне

- `api::wave_start()`, `api::wave_more(session_id)`, `api::wave_feedback(session, track, batch, kind)`
  → `WaveBatch { session_id, batch_id, tracks }`.
- `api::post_json()` — первый POST-хелпер клиента.
- `state::WaveInfo { sessionId, batchId, active }` в состоянии (`state.wave`).
- Команды: `wave_start` (новая сессия, очередь заменяется), `wave_more` (догрузка),
  `wave_feedback {value: like|dislike|skip|trackStarted}`, `wave_stop`.
- Автодогрузка в тикере: при `wave.active` и `queue_remaining() <= 1` запускается
  `wave_more`; повторные вызовы гасятся флагом `wave_pending`.
- CLI: `ymd wave [--json]` — включает волну на запущенном демоне и печатает очередь.
- Панель: кнопка «Волна» → `ymd.cmd_payload("wave_start")`.

## Проверки

```
ymd wave
Моя волна: 5 треков в очереди
▶  1. Vintage Nature — Delayni
   2. Кисточка II — Norma Tale, Ramon Tale
   ...
status playing, position растёт (14168 мс через ~6 с)

wave_feedback like → {"ok":true,"rev":3}
wave_more          → queue 5 → 10, batchId обновился
9 × next           → queue 15 (автодогрузка сработала), index 9
```

`cargo test -p ymd` → 24 passed.

## Не сделано

- `trackStarted` автоматически при смене трека (сейчас только вручную через `wave_feedback`).
- Сиды станции (жанр/настроение) — `POST /rotor/session/new` принимает `seeds`,
  формат не проверялся.
- Настройки волны (`/rotor/wave/settings`) и «последняя волна» (`/rotor/wave/last`).


## Качество: lossless

| quality | codec в URL | битрейт |
|---|---|---|
| `lossless` | `flac-mp4` | 0 (поле не заполняется) |
| `hq` | `aac256-mp4` | 256 |
| `nq` | `aac-mp4` | 192 |

Проверено на трёх треках (64072310, 657960, 147866185) — `flac-mp4` отдаётся
стабильно, GStreamer играет без ошибок, позиция растёт. Конфиг применяется на
лету: смена `quality` в `config.toml` влияет на следующий резолв.

Фоллбэк `hq` при недоступном lossless реализован, но живьём не воспроизведён:
не нашлось трека без flac на plus-аккаунте.
