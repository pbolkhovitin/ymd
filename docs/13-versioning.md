# Версии и релизы

Одна версия на весь проект: демон, плазмоид, `ymd-qt`, плагин Noctalia и
приложение `ymd-menubar` для macOS выпускаются вместе и всегда имеют
одинаковый номер. Схема — **SemVer**
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
bash scripts/version.sh --next minor   # напечатать 0.3.0, ничего не менять
bash scripts/version.sh --bump patch   # 0.2.1 -> 0.2.2
bash scripts/version.sh --tag          # аннотированный тег v0.2.2
```

`--check` входит в `scripts/docs-check.sh` и в CI: PR с расходящимися
версиями не проходит проверки.

## Когда какая цифра

Версия меняется по правилам, которые проверяет `scripts/version-impact.sh`:
он смотрит коммиты с последнего тега и diff по контракту демона.

| Изменение | Версия | Что ловит скрипт |
|---|---|---|
| ломается совместимость: удалён маршрут `/v1/*`, удалено поле состояния, понижен `plugin_api`, `type!:` или `BREAKING CHANGE` | **major** | удалённые маршруты и поля, `plugin_api` вниз, `!` в заголовке |
| новая функция: `feat:`; добавлен маршрут или поле состояния; повышен `plugin_api` | **minor** | `feat:`, добавленные маршруты и поля, `plugin_api` вверх |
| исправление: `fix:`, `perf:`, `revert:`; правки кода без feat/fix | **patch** | типы коммитов, diff в `daemon/src`, `noctalia`, `plasmoid`, `app`, `macos`, `packaging` |
| только документация, CI и скрипты | версия не меняется | всё остальное |

До 1.0.0 допускается ломать совместимость в minor-релизе, но это
оговаривается в `CHANGELOG.md`. Плагин Noctalia дополнительно требует
`plugin_api` не ниже значения из `noctalia/plugin.toml`; при повышении
`plugin_api` это отдельная строка в changelog.

### Отслеживание

```bash
bash scripts/version-impact.sh                 # с последнего тега
bash scripts/version-impact.sh v0.3.0 --json   # машинный формат
bash scripts/release.sh prepare auto           # bump из отчёта
```

Отчёт попадает в Summary job «документация» в CI: на каждом PR видно,
какая версия следует из изменений и почему. Рекомендация накопительная —
от последнего тега, поэтому промежуточные PR её не сбрасывают.

Справочники контракта генерируются: `bash scripts/docs-sync.sh`
обновляет таблицы между маркерами `<!-- generated:routes -->` и
`<!-- generated:state -->` в `docs/reference/routes.md` и
`docs/reference/state.md`. В CI запускается `--check`, поэтому
забытая правка ловится до мёржа.

## Порядок выпуска

Релиз идёт двумя шагами: **release-PR** с версией и CHANGELOG, затем
**публикация** workflow с ручным approve. Тег вручную не ставится — его
создаёт `release.yml` после проверок и сборки.

### 1. Подготовить release-PR

```bash
bash scripts/release.sh prepare minor
```

Скрипт проверяет чистый `main`, поднимает версию (`--bump`) во всех
манифестах и `Cargo.lock`, переносит `[Unreleased]` в раздел новой версии,
прогоняет `docs-check` и `pr-check`, создаёт ветку `release/vX.Y.Z`,
коммит `chore(release): X.Y.Z` и PR. `client-scope` и `pr-check`
распознают такой PR по заголовку: разрешены только манифесты версий,
`Cargo.lock` и `CHANGELOG.md`, а вместо нового пункта в `[Unreleased]`
требуется непустой раздел `## [X.Y.Z]` и пустой `[Unreleased]`.

### 2. Ревью и merge

Release-PR проходит обычные проверки (`scope`, `author`, `policy`,
`версии`, `документация`, тесты) и ревью. Версия попадает в `main` только
через PR; squash-merge даёт коммит `chore(release): X.Y.Z (#N)`.

### 3. Dry-run

```bash
bash scripts/release.sh publish vX.Y.Z
```

Запускает `release.yml` с `dry_run=true`: verify, тесты Docker и сборка
пакетов. Тег и GitHub Release **не** создаются.

### 4. Публикация

```bash
bash scripts/release.sh publish vX.Y.Z --yes
```

Workflow останавливается на environment **`release`** (required reviewer).
После approve он:

1. создаёт аннотированный тег `vX.Y.Z` на проверенном SHA;
2. создаёт GitHub Release с заметками из `CHANGELOG.md`;
3. прикладывает `.deb`, `.rpm` и архив плагина Noctalia.

Тег создаётся **только после** успешных verify/test/build и approve.
Повторный запуск с тем же тегом и SHA обновляет релиз (`--clobber`).

### 5. macOS

```bash
gh workflow run macos-release.yml -f tag=vX.Y.Z
```

macOS-раннер дорогой, поэтому `.dmg` и tar.gz демона arm64 добавляются
отдельным ручным workflow.

### Аварийный путь

Если Actions недоступны, релиз можно выпустить вручную с правами
администратора:

```bash
bash scripts/version.sh --bump patch
git commit -am "chore(release): X.Y.Z" && git push origin main
bash scripts/version.sh --tag && git push origin vX.Y.Z
```

В обычном процессе так делать не нужно: тег не пройдёт проверку
`release.yml`, если в истории `HEAD` нет релизного коммита.

### Настройка репозитория (один раз)

- **Environment `release`** — required reviewer (мейнтейнер), self-review
  разрешён; job `publish` не начнётся без approve.
- **Ruleset на `refs/tags/v*`** — запрещает удаление и перезапись тегов;
  создание нового тега workflow разрешено. Администратор может обойти
  ruleset в аварийной ситуации.
- **Branch protection `main`** — обязательные проверки `scope`, `author`,
  `policy`; одно одобрение ревью; squash-only.

Без environment с ревьюером GitHub создаст его автоматически без защиты,
поэтому настройку нужно проверить до первого релиза.

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
| `release.yml` | вручную `workflow_dispatch` или тег `v*` | verify, тесты, `.deb`/`.rpm` + архив, approve `release`, тег и GitHub Release |
| `macos-release.yml` | вручную | macOS: демон arm64 + `.dmg`, прикладывает к релизу (`.dmg` в Linux не собрать) |
| `client-scope.yml` | PR | один PR — один клиент; release-PR — только манифесты и CHANGELOG |
| `commit-identity.yml` | PR | автор коммитов — участник проекта |
| `pr-policy.yml` | PR | заголовок, шаблон, клиенты, пункт в `CHANGELOG.md` |

Проверить релиз без публикации:

```bash
bash scripts/release.sh publish vX.Y.Z          # workflow dry_run=true
```

`release.yml` при ручном запуске требует, чтобы `HEAD` совпадал с
`origin/main` и в истории `HEAD` был релизный коммит. Поэтому релиз
нельзя собрать с боковой ветки или с версией, не прошедшей release-PR.
Fix-коммиты после release-PR допустимы: тег ставится на проверенный
`HEAD`, а не на сам релизный коммит.

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
