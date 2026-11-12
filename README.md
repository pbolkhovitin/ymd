# ym-noctalia

Клиент **Яндекс Музыки** для **niri + Noctalia**: бар-виджет + панель, без анимаций
(или с отключаемыми), с максимальным сохранением функций официального клиента.

Текущий этап: **P0 — спайки** (проверка API Noctalia и связки с демоном).
Документация готова, скелет демона и плагина собран.

## Ключевое решение

Плагины Noctalia v5 — Luau-скрипты в изолированных VM: нет аудио, AES-CTR, keyring
и MPRIS. Поэтому система из двух частей:

| Часть | Что делает | Технология |
|---|---|---|
| `ymd` — демон | авторизация, API, GStreamer-плеер, MPRIS, офлайн-кэш, Ynison, niri-события | Rust (systemd --user) |
| `yandex-music` — плагин | бар-виджет, панель, шорткат, настройки | Luau (Noctalia v5) |

Связь: локальный HTTP + SSE (`noctalia.http` / `noctalia.httpStream`) по
`127.0.0.1:8765`, авторизация — capability-файл `$XDG_RUNTIME_DIR/ymd/session.key`.
Демон экспортирует MPRIS — встроенный виджет `media` работает «из коробки».

## Структура

~~~text
ym-noctalia/
├── Cargo.toml               # workspace
├── daemon/                  # ymd: скелет P0 (HTTP+SSE, симулированный плеер)
│   └── src/{main,httpd,state,session,doctor}.rs
├── plugin/                  # плагин Noctalia (Luau)
│   ├── plugin.toml          # widget bar + widget probe + service bridge + panel
│   ├── widget.luau          # бар: глиф + «Трек — Артист»
│   ├── probe.luau           # S2/S3/S5: дамп реального API хоста
│   ├── bridge.luau          # S4: SSE-подписка
│   ├── panel.luau           # S3: декларативное ui.* дерево
│   └── lib/ymd.luau         # мини-клиент демона
├── scripts/                 # p0-check.sh, dev-install.sh, sse-watch.sh
├── docs/                    # 01…10 (концепт, архитектура, плагин, демон, OAuth, …)
└── notes/p0-findings.md     # заполняется по итогам спайков
~~~

## Быстрый старт (P0)

~~~bash
cd ~/github/ym-noctalia
cargo build -p ymd
cargo run -p ymd -- serve          # терминал 1

curl -s http://127.0.0.1:8765/v1/health | jq
bash scripts/sse-watch.sh          # терминал 2
bash scripts/p0-check.sh           # проверки окружения
bash scripts/dev-install.sh        # плагин в Noctalia (drop-in)
~~~

Дальше — `docs/09-p0-spikes.md`: шаги S1–S9 с командами и критериями.

## Документы

| Файл | О чём |
|---|---|
| `docs/01-concept.md` | продукт, цели, принципы, режимы, сценарии |
| `docs/02-architecture.md` | компоненты, потоки, IPC-контракт |
| `docs/03-noctalia-plugin.md` | манифест, entries, API, адаптивность |
| `docs/04-daemon.md` | Rust-демон: модули, MPRIS, GStreamer, кэш, niri |
| `docs/05-feature-matrix.md` | паритет с официальным клиентом |
| `docs/06-design.md` | дизайн-язык: токены, состояния, запрет анимаций |
| `docs/07-roadmap.md` | этапы P0–M4 с критериями приёмки |
| `docs/08-risks.md` | риски, открытые вопросы, decision log |
| `docs/09-p0-spikes.md` | пошаговые проверки P0 с командами |

## Статус

Репозиторий: https://github.com/pbolkhovitin/ym-noctalia (private).

| Что | Состояние |
|---|---|
| Концепт и документация | готово |
| P0-спайки | S1–S8 ✅; S9 заменён импортом токена |
| Демон `ymd` | работает: API, поток, плеер, MPRIS, кэш, волна |
| Плагин | бар (иконка + трек), панель (поиск/очередь/режимы), bridge, probe |
| M1 — поиск и воспроизведение | ✅ (`ymd search`, `ymd stream`) |
| M2 — плеер + исходящий MPRIS | ✅ (`playerctl --player=ymd`) |
| M3 — офлайн-кэш | ✅ (`ymd download`, `download-album`, лимит + LRU) |
| M4 — «Моя волна» | ✅ (`ymd wave`, автодогрузка) |
| Тексты песен | разведка API выполнена, код не начат (`notes/lyrics-findings.md`) |
| Палитра (факт `getColor`) | `primary #C4B28A` на текущей теме |

## Окружение (проверено на хосте)

- niri (Wayland), Noctalia **v5** (`~/.local/state/noctalia`, `settings.toml`).
- Бар: `thickness = 34`, `radius = 12`, капсулы `surface_variant/0.6`, топ-бар.
- В баре уже стоит виджет `media` (встроенный MPRIS).
- Палитра: берётся из `noctalia.getColor(role)`; фактическое значение на
  2026-11-12 — `primary #C4B28A` (тема меняется, хардкод запрещён).
- GStreamer dev-пакеты установлены (`gstreamer-1.0` 1.28.9), `libsecret` есть.
- Noctalia **v5.4.1**, niri 26.04; бар — топ, `thickness = 34`.
- Виджет бара подключён как `[widget.ym] type = "pbolkhovitin/yandex-music:bar"`.

## Связанные материалы

Реверс-инжиниринг официального клиента: `~/github/yandex-music-research` —
10 документов, деобфусцированный код, готовые крейты `ym-api`/`ym-auth`/`ym-media`.
