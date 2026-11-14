# Версии и релизы

Одна версия на весь проект: демон, плазмоид, `ymd-qt` и плагин Noctalia
выпускаются вместе и всегда имеют одинаковый номер. Схема — **SemVer**
(`MAJOR.MINOR.PATCH`), тег — `vMAJOR.MINOR.PATCH`.

## Источник истины

Версия хранится в одном месте — `Cargo.toml`, секция `[workspace.package]`:

```toml
[workspace.package]
version = "0.2.1"
```

Остальные манифесты обязаны совпадать с ним:

| Файл | Поле | Кто использует |
|---|---|---|
| `Cargo.toml` | `[workspace.package] version` | демон `ymd`, `ymd --version` |
| `noctalia/plugin.toml` | `version` | Noctalia, архив плагина |
| `plasmoid/metadata.json` | `Version` | Plasma 6 |
| `app/CMakeLists.txt` | `project(ymd-qt VERSION …)` | `ymd-qt`, `.deb` |

Синхронизация — только скриптом, руками версии не правятся:

```bash
bash scripts/version.sh            # напечатать текущую
bash scripts/version.sh --check    # сверить все четыре манифеста
bash scripts/version.sh --set 0.3.0
bash scripts/version.sh --bump patch   # 0.2.1 -> 0.2.2
bash scripts/version.sh --tag          # аннотированный тег v0.2.2
```

`--check` входит в `scripts/docs-check.sh` и в CI: PR с расходящимися
версиями не проходит проверки.

## Когда какая цифра

| Изменение | Версия | Пример |
|---|---|---|
| несовместимый конфиг, ломается IPC `/v1`, меняется схема состояния | **major** | 0.x → 1.0.0 |
| новая функция, новый маршрут, новый клиент | **minor** | 0.2.1 → 0.3.0 |
| исправление, документация, упаковка, CI | **patch** | 0.2.0 → 0.2.1 |

До 1.0.0 допускается ломать совместимость в minor-релизе, но это
оговаривается в `CHANGELOG.md`. Плагин Noctalia дополнительно требует
`plugin_api` не ниже значения из `noctalia/plugin.toml`; при повышении
`plugin_api` это отдельная строка в changelog.

## Порядок выпуска

1. Обновить `CHANGELOG.md`: перенести пункты из `[Unreleased]` в будущий
   раздел (это делает `--set`/`--bump` автоматически, остаётся дописать
   содержимое).
2. Поднять версию:

   ```bash
   bash scripts/version.sh --bump minor   # создаст раздел в CHANGELOG
   ```

3. Проверить локально:

   ```bash
   bash scripts/docs-check.sh
   bash packaging/run-tests.sh -p ymd
   cargo build --release -p ymd && ./target/release/ymd --version
   ```

4. Закоммитить и запушить `main`:

   ```bash
   git add -A
   git commit -m "chore(release): 0.3.0"
   git push origin main
   ```

5. Поставить тег и запушить его:

   ```bash
   bash scripts/version.sh --tag
   git push origin v0.3.0
   ```

6. Дождаться workflow **release**: он проверит `тег = версия`, прогонит
   тесты, соберёт `ymd_*.deb`/`*.rpm`, `plasma-widget-ymd_*.deb`/`*.rpm`,
   `ymd-qt_*.deb`/`*.rpm` и `yandex-music-plugin-*.tar.gz`, создаст
   GitHub Release с заметками из `CHANGELOG.md` и приложит файлы.
   macOS-артефакты (`.dmg`, tar.gz демона) добавляются отдельно:
   `gh workflow run macos-release.yml -f tag=vX.Y.Z`.

Если workflow упал, тег можно удалить и повторить:

```bash
git tag -d v0.3.0 && git push origin :refs/tags/v0.3.0
```

## Что видит пользователь

- Страница **Releases** — заметки и готовые `.deb`, `.rpm` и архив плагина;
  macOS-сборки (`.dmg` и tar.gz демона) добавляются туда же вручную или
  workflow `macos-release`.
- Бейдж версии в `README.md` — последний релиз.
- `ymd --version` и `/v1/health` (`version`) — версия запущенного демона.
- `ymd doctor` — версия и путь лога; `ymd logs` — что происходило.

## Правила changelog

`CHANGELOG.md` ведётся по [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/):

- раздел `[Unreleased]` пополняется в том же PR, что и изменение;
- при выпуске он превращается в `## [X.Y.Z] - ГГГГ-ММ-ДД`;
- записи — про поведение для пользователя, а не перечень файлов;
- ломающие изменения — с пометкой **Изменено** и объяснением, что делать.

## Проверки в CI

| Workflow | Когда | Что делает |
|---|---|---|
| `ci.yml` | push в `main`, PR; вручную | версии, `docs-check`, `cargo test` в Docker, архив плагина; при ручном запуске — ещё `.rpm` |
| `release.yml` | тег `v*` | версия = тег, тесты, `.deb`/`.rpm` + архив, GitHub Release |
| `macos-release.yml` | вручную | macOS: демон arm64 + `.dmg`, прикладывает к релизу (`.dmg` в Linux не собрать) |
| `client-scope.yml` | PR | один PR — один клиент |
| `commit-identity.yml` | PR | автор коммитов — участник проекта |

Проверить упаковку, не выпуская тег:

```bash
gh workflow run ci.yml --ref main -f packages=true
```

Job `rpm (Fedora, вручную)` соберёт три пакета и выложит их артефактом.

Ручная сборка arm64 (в CI только amd64):

```bash
bash packaging/build-deb.sh --arch arm64
bash packaging/build-qt-deb.sh --arch arm64
bash packaging/build-rpm.sh --arch arm64
```
