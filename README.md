# ym-noctalia

Клиент **Яндекс Музыки** для **KDE Plasma 6**: плазмоид в панели и Rust-демон
`ymd`. Без Electron, без анимаций по умолчанию, с нативным PipeWire и MPRIS.

## Из чего состоит

| Часть | Что делает | Технология |
|---|---|---|
| `ymd` | токен, API Яндекса, GStreamer-плеер, MPRIS, офлайн-кэш, «Моя волна» | Rust, systemd --user |
| `plasma-widget-ymd` | компактный виджет в панели и попап: поиск, очередь, транспорт, режимы | QML / Plasma 6 |

Плазмоид не знает токен и не обращается к API Яндекса. Он общается только с
локальным HTTP API `127.0.0.1:8765`; ключ доступа — `$XDG_RUNTIME_DIR/ymd/session.key`
(0600), плазмоид получает его командой `ymd session-key`.

Демон экспортирует MPRIS `org.mpris.MediaPlayer2.ymd`, поэтому медиа-клавиши и
встроенный виджет `media` Plasma работают без нашего плазмоида.

## Установка из .deb

Пакеты собираются в `dist/`:

```bash
bash packaging/build-deb.sh --arch arm64   # или --arch amd64
sudo apt install ./ymd_0.2.0_arm64.deb ./plasma-widget-ymd_0.2.0_all.deb
systemctl --user daemon-reload
systemctl --user enable --now ymd
```

После установки добавьте «Yandex Music» на панель: правый клик по панели →
«Добавить виджеты» → «Yandex Music».

## Быстрый старт для разработки

```bash
# тесты демона в контейнере (на хосте Rust может отсутствовать)
bash packaging/run-tests.sh

# запуск демона
cargo run -p ymd -- serve

# проверка
ymd doctor
ymd status --json
curl -s http://127.0.0.1:8765/v1/health

# плазмоид: установка/обновление в текущую сессию
bash scripts/dev-install.sh
```

Для входа: `ymd auth login` (OAuth Device Flow) или
`ymd auth import --from-official`.

## CLI

| Команда | Смысл |
|---|---|
| `ymd serve [--port]` | запустить демон |
| `ymd session-key` | напечатать capability-ключ для плазмоида |
| `ymd status [--json]` | состояние плеера |
| `ymd ctl toggle\|play\|pause\|next\|prev\|like\|mode` | управление |
| `ymd search "…" [--json]` | поиск |
| `ymd wave [--json]` | включить «Мою волну» |
| `ymd quality [lossless\|hq\|nq\|lq]` | качество звука |
| `ymd download <id>` / `download-album <id>` | офлайн-кэш |
| `ymd cache list\|path\|remove\|info` | управление кэшем |
| `ymd track <id>` / `stream <id>` | метаданные и URL потока |
| `ymd auth login\|import\|status\|logout` | авторизация |
| `ymd doctor` | проверка окружения |

## Статус

| Что | Состояние |
|---|---|
| Демон: API, поток, GStreamer, MPRIS | ✅ |
| Офлайн-кэш: download, LRU, локальное воспроизведение | ✅ |
| «Моя волна»: запуск, автодогрузка, feedback | ✅ |
| Плазмоид: компакт, попап, поиск, очередь, режимы | ✅ |
| Пакеты `.deb` (amd64/arm64) | ✅ |
| Тексты песен | разведка API, код не начат |
| Докачка после обрыва | не сделана |
| Ynison | не сделана |
| Отдельное приложение Qt/Kirigami | запланировано |

## Документация

| Файл | О чём |
|---|---|
| `docs/01-concept.md` | продукт, принципы, сценарии |
| `docs/02-architecture.md` | компоненты и IPC-контракт |
| `docs/03-kde-plasmoid.md` | пакет Plasma, ключ, polling, виджет и попап |
| `docs/04-daemon.md` | модули демона, CLI, MPRIS, кэш, волна, качество |
| `docs/05-feature-matrix.md` | паритет с официальным клиентом |
| `docs/06-design.md` | дизайн плазмоида: Kirigami, цвета, запрет анимаций |
| `docs/07-roadmap.md` | этапы и следующий шаг |
| `docs/08-risks.md` | риски и открытые вопросы |
| `docs/09-p0-spikes.md` | проверки окружения и история спайков |
| `notes/kde-port-findings.md` | факты порта: хост, QML, упаковка |

## Требования

- KDE Plasma 6 (проверено на 6.6.6, Wayland).
- PipeWire + WirePlumber; GStreamer 1.24+ с плагинами good/bad/libav.
- `playerctl`, `libsecret-tools`, `dbus-user-session`.
- Для сборки: Docker с binfmt для arm64 или Rust + GStreamer dev-пакеты.

## Связанные материалы

Реверс-инжиниринг официального клиента: `~/github/yandex-music-research` —
API, подписи, `encraw`, крейты `ym-api`/`ym-auth`/`ym-media`.
