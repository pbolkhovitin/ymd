# Локальная проверка macOS — 2026-11-14

Это первоначальная проверка до самостоятельного bundle. Последующая
реализация с target macOS 13 и встроенным runtime описана в
`notes/macos-standalone-findings.md`.

Проверка по `docs/15-macos-brief.md`, версия проекта `0.2.1`.
Ветка `chore/macos-local-validation` создана от
`fix/macos-local-build-audio`; затем в неё влита актуальная `main`
(`2f22d25`). Дерево после слияния совпадало с `main`.

## Окружение

```text
$ sw_vers
ProductName:            macOS
ProductVersion:         27.2.1
BuildVersion:           26B131

$ uname -m
arm64

$ brew --prefix
/opt/homebrew
```

Homebrew GStreamer и Rust уже установлены; повторная установка не требовалась.

## Тесты и сборка

```text
$ PKG_CONFIG_PATH=/opt/homebrew/lib/pkgconfig cargo test -p ymd
test result: ok. 43 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s

$ PKG_CONFIG_PATH=/opt/homebrew/lib/pkgconfig cargo build --release -p ymd
Finished `release` profile [optimized] target(s) in 0.10s

$ LC_ALL=C bash macos/build.sh --install
Build complete! (26,51 с)
готово: /Users/4epenaxa/ymd/dist/ymd-menubar.app
установлено: /Users/4epenaxa/Applications/ymd-menubar.app
```

Rust выводит предупреждение: `SECRET_ATTR` в `daemon/src/auth.rs:20`
не используется на macOS. Линкер Swift сообщает об отсутствующих каталогах
`CommandLineTools/Developer/usr/lib` и `Developer/Library/Frameworks`;
сборка при этом завершилась с кодом 0.

SwiftPM внутри песочницы агента завершился с
`sandbox-exec: sandbox_apply: Operation not permitted`.
Повтор той же команды с разрешённым доступом вне песочницы прошёл успешно.

## Демон и звук

`bash macos/run-daemon.sh` запущен на стандартном порту; восстановлена
сохранённая очередь из 15 треков. Повторный вход в аккаунт не выполнялся.

```text
$ ./target/release/ymd doctor
ymd doctor
------------------------------------------------------------
session key        ok    /Users/4epenaxa/Library/Application Support/ymd/run/session.key
macOS              ok    aarch64
security           ok    связка ключей (есть в системе)
gst-launch-1.0     ok    brew install gstreamer gst-plugins-base gst-plugins-good
mpv                warn  опционально
curl               ok    проверки HTTP API
log                ok    /Users/4epenaxa/.local/state/ymd/ymd.log (6 КиБ)
daemon :8765       ok    отвечает
------------------------------------------------------------
warn — не ошибка: без части пакетов доступны не все возможности.

$ curl --fail --silent --show-error http://127.0.0.1:8765/v1/health
{"ok":true,"state_rev":1,"uptime_s":87,"version":"0.2.1"}

$ gst-launch-1.0 audiotestsrc num-buffers=100 ! osxaudiosink
Setting pipeline to PAUSED ...
Pipeline is PREROLLING ...
Redistribute latency...
Pipeline is PREROLLED ...
Setting pipeline to PLAYING ...
Redistribute latency...
New clock: GstAudioSinkClock
Got EOS from element "pipeline0".
Execution ended after 0:00:02.241427750
Setting pipeline to NULL ...
Freeing pipeline ...
```

Аудиопайплайн завершился с кодом 0; слышимость звука человеком и
воспроизведение трека Яндекса в этой проверке не подтверждены.

## Приложение и DMG

`open ~/Applications/ymd-menubar.app` завершился с кодом 0;
`pgrep -x ymd-menubar` подтвердил работающий процесс после запуска.
`codesign --verify --deep --strict dist/ymd-menubar.app` завершился с кодом 0
(ad-hoc подпись; Developer ID и notarization не проверялись).

```text
$ bash macos/build-dmg.sh --no-build
готово: /Users/4epenaxa/ymd/dist/ymd-menubar-0.2.1.dmg (116K)

$ hdiutil verify dist/ymd-menubar-0.2.1.dmg
hdiutil: verify: checksum of "dist/ymd-menubar-0.2.1.dmg" is VALID
```

Первая попытка получить скриншот строки меню и попапа была заблокирована:

- Открытие попапа через System Events: `Функции Упрощенного доступа
  для «osascript» не разрешены. (-1719)`.
- `screencapture -x /private/tmp/ymd-macos-validation.png`:
  `could not create image from display`.

При повторной проверке захват экрана и отправка кликов стали доступны.
Команда `click` через System Events не открывала попап; отправка событий
`leftMouseDown`/`leftMouseUp` через CoreGraphics открыла его, после чего
`screencapture` сохранил снимок области строки меню и попапа в
`/private/tmp/ymd-popup.png` (временный файл вне репозитория).

На снимке визуально подтверждены: обложка, трек «I Met U», артист Omauha,
метка FLAC, прогресс 0:02 из 7:37, кнопки транспорта, повтора, shuffle,
лайка, обновления и выхода. Подтверждено открытие попапа; действие кнопок
управления и воспроизведение звука при этом не проверялись.

## Проверки репозитория

`bash scripts/docs-check.sh` завершился с
`ok: документация, клиенты и версии согласованы`.
Версия проекта не менялась; исходники клиента и демона не изменялись.
