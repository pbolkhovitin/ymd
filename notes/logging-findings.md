# Логирование и зацикливание одного трека

Дата: 2026-11-14. Проверено на хосте (niri, PipeWire, реальный аккаунт).

## Задача

Не было способа посмотреть, что демон делал до перезапуска: `tracing` писал
только в stderr, а `systemd --user` уводил его в journald без ротации и без
привязки к треку. Подозрение пользователя: «функция работает некорректно,
зацикливает один трек».

## Что сделано

### Файловый лог

`daemon/src/logging.rs` — один подписчик на два приёмника:

* stderr (journald) — с таргетами, без ANSI;
* файл `~/.local/state/ymd/ymd.log` — append, общий `Arc<Mutex<File>>`.

Уровень: `YMD_LOG` → `RUST_LOG` → `info`; понимается форма `ymd=debug`
(берётся часть после последнего `=`). Каталог — `YMD_LOG_DIR`, предел —
`YMD_LOG_MAX_MB` (по умолчанию 5). Ротация при старте: `ymd.log` → `ymd.log.1`
(старый `.1` удаляется).

Короткие CLI-команды (`status`, `search`, …) инициализируют только stderr,
файл пишет лишь `ymd serve`.

### Чтение

```
ymd logs [-n 100] [-f] [--path]
```

`tail` читает файл целиком (он ограничен 5 МиБ), `-f` следит за смещением и
переоткрывает файл, если тот стал короче (ротация).

`ymd doctor` теперь показывает путь и размер лога; unit получил
`Environment=YMD_LOG=info` и `StateDirectory=ymd`.

### Структурные события

| Строка | Поля | Зачем |
|---|---|---|
| `eos -> next` | `track`, `index`, `len`, `repeat`, `shuffle` | что играло в момент конца потока |
| `queue step` | `op`, `index`, `len`, `repeat`, `shuffle`, `track`, `status` | какое решение приняла очередь |
| `stream resolved` | `track`, `codec`, `bitrate` | для какого трека получен URL |
| `player: load <url>` | — | что реально отдано GStreamer |
| `queue step: конец очереди без повтора` | `len`, `repeat` | почему звук остановился |

## Найденная причина зацикливания

В `command_async` индекс следующего трека считался **второй раз** и по другой
формуле, чем в `advance`:

```rust
// было: command_async
let index = (state.queue.index as isize + delta).rem_euclid(len as isize);
// было: advance
if repeat == "one" { /* остаться на текущем */ }
if shuffle { /* случайный индекс */ }
```

Последствия:

* `repeat=one`: резолвился URL **следующего** трека, а `advance` оставлял
  индекс текущего. GStreamer играл трек B, состояние показывало трек A;
  на EOS снова резолвился тот же B — **один и тот же трек играл по кругу**.
* `shuffle`: индекс выбирался случайно только в `advance`, а URL был от
  `index+1` — состояние и звук расходились.
* `repeat=off` в конце: URL резолвился для индекса 0 (через `rem_euclid`),
  но загрузка отменялась проверкой `status != "stopped"` — работало случайно.

Симптом «зациклило один трек» воспроизводился именно при `repeat=one`.

## Исправление

Один алгоритм на двоих — `plan_step(state, delta) -> Step { Stop, Index }`:

* `repeat=one` (только вперёд) → текущий индекс;
* `shuffle` при `len > 1` → случайный индекс ≠ текущего;
* `repeat=all` → `rem_euclid`;
* `repeat=off` и конец → `Stop`.

`command_async` вызывает `plan_step` перед резолвом и передаёт выбранный
индекс в payload (`{"index": N}`). `advance(state, delta, target)` берёт
готовый индекс, если он есть, иначе повторно вызывает `plan_step`. Второго
случайного выбора больше нет.

## Проверки

`cargo test -p ymd` → **43 passed** (новые: `plan_step_matches_advance_for_every_repeat_mode`,
`next_with_explicit_index_takes_that_track`).

Живой прогон (`YMD_LOG=info YMD_LOG_DIR=/tmp/opencode/ymd-log ymd serve --port 8766`,
трек 75979 «My Medicine»):

```
12:12:14 eos -> next track=75979 index=0 len=5 repeat=one shuffle=false
12:12:15 stream resolved track=75979 codec=aac-mp4 bitrate=256
12:12:15 queue step op="next" index=0 len=5 repeat=one shuffle=false track=75979
```

→ повтор того же трека, `positionMs` 3625 после EOS, `status=playing`.

`shuffle=true`, `repeat=all`, `next`:

```
12:12:43 stream resolved track=34984653 codec=flac-mp4
12:12:43 queue step op="next" index=2 len=5 repeat=all shuffle=true track=34984653
```

→ `stream resolved` и `queue step` совпали (раньше расходились).

`repeat=off`, последний индекс, seek за 3 с до конца:

```
12:13:47 eos -> next track=6119814 index=4 len=5 repeat=off shuffle=false
12:13:47 queue step: конец очереди без повтора len=5 repeat=off
12:13:47 queue step op="next" index=4 len=5 repeat=off shuffle=false status=stopped
```

→ `status=stopped`, `pos=0`, звук погашен.

## Грабли

* `std::env::set_var` в тестах уровня логов делает тесты параллельно
  нестабильными — парсинг вынесен в чистую `parse_level(&str)`.
* `tracing_subscriber::fmt()` c `.with_max_level` принимает `LevelFilter`;
  `registry().with(level)` фильтрует оба слоя сразу.
* `StateDirectory=ymd` в user-юните создаёт `~/.local/state/ymd` и выставляет
  `$STATE_DIRECTORY`; приложение всё равно считает путь через `dirs::state_dir()`.
