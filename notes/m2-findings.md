# M2: собственный плеер — факты

## GStreamer (`daemon/src/player.rs`)

| Проверка | Результат |
|---|---|
| версия в системе | `gstreamer-1.0 1.28.9`, dev-пакеты стоят |
| крейт | `gstreamer 0.23.7` |
| элемент | `playbin3`, фоллбэк `playbin` |
| вывод звука | autoaudiosink → PipeWire (ничего не настраивали) |
| воспроизведение | `play_track` → позиция растёт (`2720` мс через 4 с) |
| пауза | позиция замирает (единичный дрейф ~1 с из-за латентности пайплайна) |
| seek | `seek {positionMs: 60000}` → `60776` мс |
| EOS | ловится в `bus.timed_pop(ClockTime::ZERO)` из тикера |
| перемотка после EOS | тикер зовёт `command_async("next")` |

Вывод: `playbin3` + `autoaudiosink` достаточно, отдельный `pipewiresink` не нужен.

## MPRIS (`daemon/src/mpris_server.rs`)

| Проверка | Результат |
|---|---|
| шина | `org.mpris.MediaPlayer2.ymd`, путь `/org/mpris/MediaPlayer2` |
| `playerctl --list-all` | видит `ymd` |
| metadata | `Playing | Кино | MACAN | 184440000` (мкс) |
| управление | `playerctl --player=ymd play-pause` → `Paused` |
| позиция | `playerctl --player=ymd position` → секунды с дробью |

Две ловушки:

1. **Два `#[interface]` на одном типе не компилируются** — `conflicting implementations
   of trait Interface`. Нужны отдельные структуры: `MprisRoot` и `MprisPlayer`,
   регистрируются двумя вызовами `object_server().at(ROOT_PATH, ...)`.
2. **`Connection` нельзя отпускать.** `serve()` возвращает соединение; если оно
   выходит из области видимости, zbus закрывает его и имя `org.mpris.MediaPlayer2.ymd`
   исчезает с шины (симптом: `reply: ()`, объект есть, имени нет). В `main.rs`
   соединение удерживается через `std::future::pending::<()>().await`.

3. **Самопотребление.** `mpris::detect()` теперь исключает `ymd` из списка
   `playerctl --list-all`, иначе демон читал бы собственное состояние.

## Источник состояния

Приоритет в тикере: локальный плеер (`is_local()`) → внешний MPRIS → ничего.
Локальный включается после успешного `player.load(url)`; `stop` его выключает.


## Очередь и режимы (проверено)

| Проверка | Результат |
|---|---|
| повторный `play_track` того же трека | очередь не дублируется, индекс переключается |
| `repeat=all` (по умолчанию) | `next` зацикливает очередь |
| `repeat=one` | `next` оставляет трек, позиция 0 |
| `repeat=off` в конце | `status=stopped`, очередь сохраняется, звук гаснет |
| `shuffle` | случайный индекс, отличный от текущего |
| `queue_remove` | индексы сдвигаются, `length` пересчитывается |

Ловушки, найденные при проверке:

1. **`next` в конце без повтора** сначала перезапускал трек: `command_async`
   резолвил URL, а блок загрузки URL выполнялся и после `stopped`. Исправлено
   условием `st.status != "stopped"`.
2. **Внешний MPRIS перехватывал эстафету** после остановки локального плеера
   (Firefox подставлял свой трек и чистил очередь). Добавлен флаг `owned`:
   после первого успешного `player.load` внешний MPRIS больше не опрашивается.
3. **Статус `playing/paused` мерцал** при старте потока: `current_state()`
   возвращает старое состояние во время `Async`. Добавлен `is_buffering()`
   (`state()` → `Result<StateChangeSuccess::Async>`), статус не сбрасывается.

## Обложки

`/v1/search` теперь отдаёт `cover` (`coverUri` → `https://…400x400`), трек
проносит его в состояние и очередь. Панель пока не рисует картинку: пропы
`ui.image` не проверены.


## Обложки в UI: ui.image (проверено)

| Проп | Результат |
|---|---|
| `path` | **единственный рабочий**: локальный файл, относительный путь резолвится от каталога плагина |
| `src`, `source`, `uri`, `url` | `has no prop '…', ignored` |
| `fit` | принимается; значения `contain`, `cover`, `stretch` |
| `width`, `height` | принимаются |

Вывод: сетевые URL `ui.image` не грузит. Схема: `noctalia.download(url, dest, cb)` →
файл в `pluginDataDir()/cover_<trackId>.img` → `ui.image{path=…, fit="cover"}`.
В баре то же самое через `barWidget.setImage(path)` (файл переиспользуется).

Проверено живьём: `cover_64072310.img` (33 660 байт) скачался, в логе нет
`image failed to load`; ошибок Luau нет.

### Ловушки Luau

1. **`repeat` — зарезервированное слово.** `repeat = "all"` в конструкторе таблицы
   и `s.repeat` — синтаксическая ошибка (`Expected identifier … got 'repeat'`).
   Поле состояния переименовано в `loop_mode`, а JSON-ключ читается как
   `queue["repeat"]`. Ошибка была незамеченной: панель падала на `luau_load`,
   а проверяли только демон через curl.
2. **Взаимная рекурсия**: `ensure_cover()` вызывает `render()`, а `render()` —
   `ensure_cover()`. Нужно `local render` до объявления `ensure_cover` и
   `render = function() … end`, иначе вызов уходит в `nil`
   (`attempt to call a nil value` в async-callback).
