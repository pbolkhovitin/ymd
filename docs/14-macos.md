# macOS (Apple Silicon): сборка и запуск

Демон `ymd` — обычный Rust-бинарник, поэтому на macOS arm64 он собирается и
работает. Клиенты делятся на две группы: `ymd-qt` (Qt/Kirigami) требует
отдельной работы, плазмоид Plasma и плагин Noctalia — Linux-only и на macOS
не имеют смысла.

## Что работает

| Возможность | macOS | Комментарий |
|---|---|---|
| Вход (Device Flow), токен | ✅ | токен в связке ключей через `security` |
| API: поиск, треки, альбомы, волна, тексты | ✅ | чистый HTTP, без платформенных зависимостей |
| Воспроизведение (GStreamer) | ✅ | `playbin3` → `osxaudiosink` |
| Локальный HTTP API и CLI | ✅ | `ymd serve`, `ymd ctl`, `ymd status` |
| Офлайн-кэш, докачка, LRU | ✅ | `~/Library/Application Support/ymd/media` |
| Логи с ротацией | ✅ | `~/.local/state/ymd/ymd.log` |
| MPRIS (исходящий и `playerctl`) | — | D-Bus есть только на Linux; модуль отключён `cfg` |
| Медиа-клавиши, Now Playing в системе | — | нужен `MPNowPlayingInfoCenter`, пока не сделано |
| Плазмоид Plasma, плагин Noctalia | — | Linux-only |
| `ymd-qt` | ⚠️ | Qt6/Kirigami собираются, но трей на `KStatusNotifierItem` (D-Bus) не работает |

Итог: на Mac получается headless-демон с полноценным API, управляемый из
терминала или любым HTTP-клиентом.

## Требования

- macOS 13+ на Apple Silicon (`arm64`).
- Xcode Command Line Tools: `xcode-select --install`.
- [Homebrew](https://brew.sh).
- Rust: `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`.

## Сборка

```bash
git clone https://github.com/pbolkhovitin/ymd && cd ymd
bash packaging/macos/build.sh
```

Скрипт ставит `pkgconf`, `gstreamer`, `gst-plugins-base`, `gst-plugins-good`,
выставляет `PKG_CONFIG_PATH` и собирает `target/release/ymd`.

Вручную то же самое:

```bash
brew install pkgconf gstreamer gst-plugins-base gst-plugins-good
export PKG_CONFIG_PATH="$(brew --prefix)/lib/pkgconfig"
cargo build --release -p ymd
./target/release/ymd --version
```

Альтернатива Homebrew — официальный GStreamer.framework с
<https://gstreamer.freedesktop.org/download/>: после установки

```bash
export PKG_CONFIG_PATH=/Library/Frameworks/GStreamer.framework/Versions/1.0/lib/pkgconfig
```

Плюс официального варианта — полный набор плагинов и подпись Apple; минус —
обновлять нужно вручную.

## Первый запуск

```bash
./target/release/ymd auth login      # код и ссылка oauth.yandex.ru/device
./target/release/ymd doctor          # что нашлось в системе
./target/release/ymd search "кино"   # проверка API
./target/release/ymd serve           # демон на 127.0.0.1:8765
```

Если Homebrew GStreamer при запуске сообщает `can't find gi.repository.Gst`,
не находит `libglib`/`libgobject` или загружает одновременно GTK 3 и GTK 4,
запускайте демон через `bash macos/run-daemon.sh`. Скрипт использует отдельные
каталог аудиоплагинов и реестр в `dist/`, исключая GTK/Python-плагины.
Окружение других приложений не меняется. Для проверки можно передать аргументы:
`bash macos/run-daemon.sh serve --port 18765`.

На Apple Silicon проверены запуск API на временном порту и беззвучный поток
`audiotestsrc → audioconvert → audioresample → osxaudiosink`.

Во втором терминале:

```bash
key="$(./target/release/ymd session-key)"
curl -s -H "X-YMD-Session: $key" http://127.0.0.1:8765/v1/state | head -c 400
./target/release/ymd status
./target/release/ymd ctl toggle
```

Ключ доступа лежит в `~/Library/Application Support/ymd/run/session.key`
(права `0600`): `$XDG_RUNTIME_DIR` на macOS не задаётся.

## Где что хранится

| Что | Путь |
|---|---|
| Конфиг | `~/Library/Application Support/ymd/config.toml` |
| Токен | связка ключей (`security find-generic-password -s ymd -a <login> -w`) |
| Метаданные аккаунта | `~/Library/Application Support/ymd/auth.json` |
| Кэш треков | `~/Library/Application Support/ymd/media` |
| Ключ API | `~/Library/Application Support/ymd/run/session.key` |
| Лог | `~/.local/state/ymd/ymd.log` |

Файловый фоллбэк токена (`~/Library/Application Support/ymd/token`, `0600`)
используется, только если `security` недоступен.

## Автозапуск (LaunchAgent)

`~/Library/LaunchAgents/com.github.pbolkhovitin.ymd.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.github.pbolkhovitin.ymd</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/ВАШ_ЛОГИН/.local/bin/ymd</string>
    <string>serve</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/tmp/ymd.err.log</string>
</dict>
</plist>
```

```bash
cp target/release/ymd ~/.local/bin/ymd
launchctl load -w ~/Library/LaunchAgents/com.github.pbolkhovitin.ymd.plist
launchctl list | grep ymd
```

Остановить: `launchctl unload ~/Library/LaunchAgents/com.github.pbolkhovitin.ymd.plist`.
`KeepAlive` перезапускает демон после падения — аналог `Restart=on-failure`
в systemd-юните.

## Меню-бар клиент (`ymd-menubar`)

Маленькое SwiftUI-приложение: иконка в строке меню, по клику — попап с
обложкой, треком, прогрессом, транспортом, повтором и shuffle. Работает через
тот же локальный API, что плазмоид и `ymd-qt`, поэтому демон должен быть
запущен (`ymd serve`).

```bash
bash macos/build.sh              # dist/ymd-menubar.app
bash macos/build.sh --install    # + ~/Applications
open ~/Applications/ymd-menubar.app
```

Если системный Bash прерывает сборку с `version…: unbound variable`,
используйте `LC_ALL=C bash macos/build.sh`: в проверенном окружении ошибка
возникала при разборе `$version` перед многоточием в UTF-8-локали.

Приложение появляется только в строке меню. Пока нет активного трека,
панель показывает «Ничего не играет»; после входа через `ymd auth login`
волну можно включить командой `ymd wave` в другом терминале.
Логи демона находятся в `~/.local/state/ymd/ymd.log` (`ymd logs`);
SwiftUI-клиент отдельный файл логов не пишет. Сообщения внешнего сканера
GStreamer в stderr могут отсутствовать в файле лога демона.

Автозапуск: System Settings → General → Login Items → «+» →
`ymd-menubar.app`. `LSUIElement=true` в `Info.plist` — иконки в Dock нет.

### DMG для раздачи

```bash
bash macos/build-dmg.sh                        # .app + dist/ymd-menubar-<версия>.dmg
bash macos/build-dmg.sh --no-build             # только DMG из готового .app
bash macos/build-dmg.sh --sign "Developer ID Application: …"
```

Внутри DMG — `ymd-menubar.app`, симлинк на `/Applications` и короткая памятка.
Без `--sign` приложение не нотаризовано: macOS предупредит при первом запуске
(правый клик → «Открыть» либо `xattr -dr com.apple.quarantine /Applications/ymd-menubar.app`).
DMG собирается только на macOS — `hdiutil` в Linux нет.

Приложить к уже выпущенному релизу:

```bash
gh release upload v0.3.0 dist/ymd-menubar-0.3.0.dmg
gh workflow run macos-release.yml -f tag=v0.3.0   # то же в CI, если есть минуты
```

Устройство:

| Файл | Что |
|---|---|
| `macos/Sources/ymd-menubar/YmdMenuBarApp.swift` | `MenuBarExtra` + попап |
| `APIClient.swift` | `/v1/state`, `/v1/cmd`, чтение ключа |
| `AppModel.swift` | опрос (1 с при игре, 3 с в паузе), команды |
| `Views.swift` | обложка, прогресс, транспорт, режимы |

Ограничения текущей версии:

- нет SSE — состояние обновляется опросом (задержка до секунды);
- нет системного «Now Playing» и медиа-клавиш: для них демону нужен
  `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter` (отдельный этап);
- перемотка кликом по прогрессу пока не сделана — только `ymd ctl seek`.

## Ограничения

- **Нет системной интеграции.** macOS не использует MPRIS; чтобы медиа-клавиши
  и «Now Playing» заработали, нужен отдельный модуль на `objc2` /
  `MPNowPlayingInfoCenter`. Это следующий шаг, а не текущая возможность.
- **Нет GUI.** `ymd-qt` зависит от `KStatusNotifierItem` (D-Bus). Окно без трея
  собрать можно, но это отдельная работа по `app/`.
- **Официальный клиент Яндекса** на macOS не управляется: демон играет сам,
  внешний плеер ему не нужен.
- `security add-generic-password -w <token>` передаёт токен аргументом — он
  виден в `ps` доли секунды. Для демона это приемлемо, но не идеально; при
  желании заменим на `keyring` crate с `apple-native`.

## Проверка в CI

Сборка под macOS идёт на настоящем arm64-раннере GitHub (`macos-14`),
вручную, чтобы не тратить минуты на каждый push:

```bash
gh workflow run ci.yml --ref main -f macos=true
```

Job ставит GStreamer из Homebrew, собирает `ymd --release`, проверяет
`--version`, `session-key` и `doctor`.

## Распространение

Для локального использования подпись не нужна. Если раздавать бинарник:

```bash
codesign --force --deep --sign - target/release/ymd      # ad-hoc
# или Developer ID + notarization:
codesign --force --options runtime --sign "Developer ID Application: …" target/release/ymd
xcrun notarytool submit ymd.zip --keychain-profile ymd --wait
```

Пока релизы собираются только для Linux; отдельный macOS-ассет появится,
когда появится GUI или запросы от пользователей.
