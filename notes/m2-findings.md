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
