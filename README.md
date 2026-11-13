# ym-noctalia

Клиент **Яндекс Музыки** для **KDE Plasma 6** и **Noctalia** (niri): плазмоид
в панели, отдельное приложение на Qt/Kirigami, плагин для бара Noctalia и
Rust-демон `ymd`. Без Electron, без анимаций по умолчанию, с нативным PipeWire
и MPRIS.

## Из чего состоит

| Часть | Что делает | Технология |
|---|---|---|
| `ymd` | токен, API Яндекса, GStreamer-плеер, MPRIS, офлайн-кэш, «Моя волна» | Rust, systemd --user |
| `plasma-widget-ymd` | компактный виджет в панели и попап: поиск, очередь, транспорт, режимы | QML / Plasma 6 |
| `ymd-qt` | отдельное окно + трей: те же поиск, очередь, транспорт, режимы | Qt 6 / Kirigami |
| `yandex-music` (Noctalia) | бар-виджет «трек — артист» и панель: поиск, очередь, транспорт | Luau, plugin_api 35 |

Плазмоид, `ymd-qt` и плагин Noctalia не знают токен и не обращаются к API
Яндекса. Они общаются только с локальным HTTP API `127.0.0.1:8765`; ключ
доступа — `$XDG_RUNTIME_DIR/ymd/session.key` (0600), клиенты получают его
командой `ymd session-key` или чтением файла.

Демон экспортирует MPRIS `org.mpris.MediaPlayer2.ymd`, поэтому медиа-клавиши и
встроенный виджет `media` Plasma работают без нашего плазмоида.

## Установка из .deb

Пакеты собираются в `dist/`:

```bash
bash packaging/build-deb.sh --arch arm64      # демон и плазмоид
bash packaging/build-qt-deb.sh --arch arm64   # отдельное приложение
sudo apt install ./ymd_0.2.0_arm64.deb ./plasma-widget-ymd_0.2.0_all.deb \
                 ./ymd-qt_0.2.0_arm64.deb
systemctl --user daemon-reload
systemctl --user enable --now ymd
```

После установки добавьте «Yandex Music» на панель: правый клик по панели →
«Добавить виджеты» → «Yandex Music». Отдельное приложение запускается из меню
или командой `ymd-qt`.

## Установка плагина Noctalia

Плагин живёт в `noctalia/` и подключается симлинком (Noctalia перезаписывает
собственные копии при обновлении, поэтому источник — репозиторий):

```bash
bash scripts/install-noctalia.sh          # симлинк + reload, если Noctalia запущена
noctalia msg plugins list                 # должен появиться pbolkhovitin/yandex-music
```

Виджет добавляется в бар через настройки Noctalia (`Bar` → `widgets`), панель
открывается правым кликом по виджету. Нужен Noctalia 5.x и `plugin_api >= 35`.

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

# отдельное приложение: сборка .deb и запуск из build-кэша
bash packaging/build-qt-deb.sh --arch amd64
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
| Отдельное приложение Qt/Kirigami: окно + трей | ✅ |
| Пакеты `.deb` (amd64/arm64) | ✅ |
| Тексты песен | разведка API, код не начат |
| Докачка после обрыва | не сделана |
| Ynison | не сделана |

## Документация

| Файл | О чём |
|---|---|
| `docs/01-concept.md` | продукт, принципы, сценарии |
| `docs/02-architecture.md` | компоненты и IPC-контракт |
| `docs/03-kde-plasmoid.md` | пакет Plasma, ключ, polling, виджет и попап |
| `docs/04-daemon.md` | модули демона, CLI, MPRIS, кэш, волна, качество |
| `docs/05-feature-matrix.md` | паритет с официальным клиентом |
| `docs/design/ui-rules.md` | общие правила UI: состояния, обрезка, акценты, анимации |
| `docs/design/plasma.md` | дизайн плазмоида: Kirigami, цвета, запрет анимаций |
| `docs/design/noctalia.md` | плагин Noctalia: бар, панель, `ui.*`, ограничения хоста |
| `docs/design/noctalia-design.md` | дизайн-язык панели Noctalia и замеры |
| `docs/07-roadmap.md` | этапы и следующий шаг |
| `docs/08-risks.md` | риски и открытые вопросы |
| `docs/09-p0-spikes.md` | проверки окружения и история спайков |
| `docs/11-qt-app.md` | приложение `ymd-qt`: архитектура, сборка, трей, ограничения |
| `notes/kde-port-findings.md` | факты порта: хост, QML, упаковка |

## Требования

- KDE Plasma 6 (проверено на 6.6.6, Wayland).
- PipeWire + WirePlumber; GStreamer 1.24+ с плагинами good/bad/libav.
- `playerctl`, `libsecret-tools`, `dbus-user-session`.
- Для сборки: Docker с binfmt для arm64 (демон — Rust + GStreamer dev,
  приложение — Qt 6 + Kirigami dev; всё уже в `packaging/Dockerfile*`).

## Связанные материалы

Реверс-инжиниринг официального клиента: `~/github/yandex-music-research` —
API, подписи, `encraw`, крейты `ym-api`/`ym-auth`/`ym-media`.
