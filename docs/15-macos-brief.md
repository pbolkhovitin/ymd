# Бриф для работы над macOS-частью `ymd`

Документ для внешнего контрибьютора и его агента. Всё остальное — в
`README.md`, `docs/14-macos.md`, `docs/02-architecture.md`.

## Что за проект

`ymd` — неофициальный клиент Яндекс Музыки: Rust-демон `ymd` (OAuth, API,
GStreamer, кэш, «Моя волна», тексты) и тонкие клиенты, которые говорят с ним
по локальному HTTP. Демон — единственный, кто знает токен и ходит в API.

```
клиент (SwiftUI / QML / Luau)  ──HTTP 127.0.0.1:8765──▶  ymd serve
                                                          ├─ Яндекс API
                                                          ├─ GStreamer → звук
                                                          └─ кэш, логи
```

Контракт: заголовок `X-YMD-Session: <ключ>`, ключ лежит в файле `0600`:

- Linux: `$XDG_RUNTIME_DIR/ymd/session.key`
- macOS: `~/Library/Application Support/ymd/run/session.key`

Эндпоинты: `/v1/health`, `/v1/state`, `/v1/cmd`, `/v1/events` (SSE), `/v1/search`,
`/v1/lyrics`, `/v1/discovery/*`, `/v1/radio` и другие — полный список в
`docs/02-architecture.md`. Команды `POST /v1/cmd` — `{"op": "...", "payload": {...}}`.

## Зона ответственности: `/macos/`

`CODEOWNERS` закрепляет за `@4epenaxa` каталог `/macos/`. Смежное, что можно
трогать в том же PR (с ревью владельца демона):

- `daemon/src/*` — только `cfg(target_os = "macos")`-ветки и платформенные
  мелочи (`mpris_stub.rs`, `session.rs`, `auth.rs`, `doctor.rs`);
- `packaging/macos/` — сборка демона;
- `docs/14-macos.md`, `CHANGELOG.md`, `README.md` (раздел macOS).

## Сборка и проверка

Требуется macOS 13+, Apple Silicon, Xcode Command Line Tools, Homebrew, Rust.

Самостоятельный `.app` и DMG целятся в macOS 13 Ventura+ arm64. Их сборка
использует официальный GStreamer 1.28.8 в приватном кэше, с проверкой SHA-256,
без установки `.pkg` в систему. На целевом Mac Homebrew и терминал не нужны:
демон запускается приложением, вход и «Моя волна» доступны в попапе.
Сборка/запуск проверены на macOS 27.2.1; запуск на Ventura ещё предстоит.

```bash
xcode-select --install              # один раз
brew install pkgconf gstreamer
export PKG_CONFIG_PATH="$(brew --prefix)/lib/pkgconfig"

cargo test -p ymd                   # 44 теста на macOS, включая платформенные ветки
cargo build --release -p ymd
bash packaging/macos/build.sh       # то же, но сам ставит зависимости

LC_ALL=C bash macos/build.sh --install   # меню-бар клиент → ~/Applications
bash macos/build-dmg.sh                  # dist/ymd-menubar-<версия>.dmg
```

Для самостоятельной сборки достаточно CLT, Rust, Python 3.9+ и `pkg-config`
(`brew install pkgconf`); установленные библиотеки Homebrew не используются
внутри `.app`. `macos/build.sh` собирает встроенный демон в `target/macos13/`,
проверяет arm64 и минимум macOS всех вложенных Mach-O (не выше 13.0).
Команды `cargo` и `run-daemon.sh` выше/ниже — отдельный режим разработки CLI.

Дополнительные локальные проверки:

```bash
python3 -m unittest discover -s macos/Tests -p 'test_*.py' -v
bash macos/Tests/run-standalone-checks.sh
python3 macos/Tests/check-runtime.py dist/ymd-menubar.app --https https://example.com/
```

Проверка runtime воспроизводит отсутствие Homebrew, включает короткий звук
и HTTPS, проверяет отклонение недоверенного сертификата. Перед проверкой
холодного запуска остановите ранее запущенные экземпляры клиента/демона.

`LC_ALL=C` — обход локали: в UTF-8 системный Bash спотыкается на разборе
`$version` перед многоточием.

## Запуск демона на macOS

```bash
./target/release/ymd auth login     # Device Flow: открыть ссылку, ввести код
./target/release/ymd doctor         # окружение, Keychain, GStreamer, лог
bash macos/run-daemon.sh            # serve с изолированными плагинами Homebrew
./target/release/ymd logs -f        # что происходит
```

`run-daemon.sh` (из PR #4) поднимает отдельный `GST_PLUGIN_SYSTEM_PATH_1_0` и
`GST_REGISTRY`, чтобы плагины Homebrew не конфликтовали с системными.
Проверка звука:

```bash
gst-launch-1.0 audiotestsrc num-buffers=100 ! osxaudiosink
```

Если тишина — смотреть `~/.local/state/ymd/ymd.log`, искать `stream resolved`
и `player: load`; проверить, что трек не `stopped`.

## Правила репозитория

- Ветка от `main`, PR в `main`. Слияние — **только squash** (merge и rebase
  в настройках запрещены).
- Обязательные проверки: `scope` (один PR — один клиент), `author`
  (автор коммита в allowlist `.github/workflows/commit-identity.yml`),
  `документация`, `версии`, `тесты (Docker)`. Новый email — попросить
  владельца добавить в allowlist.
- Коммиты: Conventional Commits, английский, `git commit -s` (DCO).
- Версию **не менять вручную** — только `bash scripts/version.sh --bump`
  (и это делает мейнтейнер при выпуске).
- `CHANGELOG.md` — запись в `[Unreleased]` в том же PR.
- Перед PR: `bash scripts/docs-check.sh` (должен быть `ok`) и
  `gitleaks detect --no-banner --redact`.
- Факты — в `docs/`; гипотезы и «почему не сработало» — в `notes/*-findings.md`.
- Никаких токенов, ключей и cookie в репозитории и логах. Ключ сессии — `0600`,
  токен — Keychain (`security add-generic-password`).

## Ограничения, о которых надо знать

- **CI на macOS не работает**: job отменяется до старта (лимит минут
  аккаунта). Значит сборка и запуск проверяются локально, в PR — вывод команд.
- **DMG без Developer ID** не нотаризован: первый запуск — правый клик →
  «Открыть» либо `xattr -dr com.apple.quarantine`.
- **Нет системного «Now Playing» и медиа-клавиш** — нужен
  `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter`. Это отдельный этап:
  сначала обсудить в issue.
- **Нет SSE в меню-бар клиенте** — опрос `/v1/state` (1 с при игре, 3 с в паузе).
- `ymd-qt` на macOS не собирается: трей завязан на D-Bus.

## Что прислать после проверки

1. `sw_vers` и `uname -m`.
2. Вывод `cargo test -p ymd` (хвост) и `bash macos/build.sh`.
3. `./target/release/ymd doctor`.
4. Скриншот строки меню и попапа (или описание, если скриншот не снимается).
5. Ошибки целиком, а не «не работает»: команда → вывод → ожидание.
6. Для самостоятельного `.app`: холодный запуск собственного Helpers/ymd,
   выход с его остановкой и подключение к внешнему без его остановки.

## Короткий промпт для агента

> Репозиторий `pbolkhovitin/ymd` — клиент Яндекс Музыки: Rust-демон + клиенты.
> Твоя зона — `/macos/` (SwiftUI `ymd-menubar`), плюс macOS-ветки в
> `daemon/src`. Прочитай `docs/15-macos-brief.md`, `docs/14-macos.md`,
> `docs/02-architecture.md`. Сборка: `brew install pkgconf gstreamer`,
> `PKG_CONFIG_PATH=$(brew --prefix)/lib/pkgconfig`, `cargo test -p ymd`,
> `LC_ALL=C bash macos/build.sh`. Демон запускается через `macos/run-daemon.sh`,
> общается по `127.0.0.1:8765` с заголовком `X-YMD-Session` (ключ в
> `~/Library/Application Support/ymd/run/session.key`). Правила: ветка от `main`,
> squash-мёрж, `CHANGELOG.md` в `[Unreleased]`, `bash scripts/docs-check.sh` = `ok`,
> версия только через `scripts/version.sh`. Токенов в репозитории быть не должно.
> CI на macOS не запускается — проверяй локально и присылай вывод команд.
