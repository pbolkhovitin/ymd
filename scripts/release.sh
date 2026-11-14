#!/usr/bin/env bash
# Контролируемый выпуск: подготовка release-PR, проверка и публикация.
#
#   bash scripts/release.sh status
#   bash scripts/release.sh prepare minor
#   bash scripts/release.sh check v0.3.0
#   bash scripts/release.sh check --ci --require-main-head v0.3.0
#   bash scripts/release.sh publish v0.3.0          # dry-run
#   bash scripts/release.sh publish v0.3.0 --yes    # тег и релиз
#
# `prepare` создаёт ветку release/vX.Y.Z, коммит, пушит её и открывает PR.
# Тег не ставится: сначала ревью, проверки и merge.
#
# `publish` запускает .github/workflows/release.yml. Workflow проверяет
# версию и CHANGELOG, гоняет тесты, собирает пакеты и только после approve
# environment `release` создаёт тег и GitHub Release. Без --yes — dry-run.
set -euo pipefail

cd "$(dirname "$0")/.."

die() { printf 'ошибка: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

usage() {
  cat <<'EOF'
Использование:
  bash scripts/release.sh status
  bash scripts/release.sh prepare major|minor|patch
  bash scripts/release.sh check vX.Y.Z
  bash scripts/release.sh check --ci [--require-main-head] vX.Y.Z
  bash scripts/release.sh publish vX.Y.Z [--yes] [--watch]

prepare  — версия + CHANGELOG, ветка release/vX.Y.Z и PR; тег не ставится.
check    — версия = тег, раздел CHANGELOG, [Unreleased] пуст, релизный
           коммит есть в истории HEAD, docs-check. --ci не требует чистого main.
publish  — запуск release.yml; без --yes только проверки и сборка.
--watch  — дождаться завершения запуска (включая approve environment).
EOF
}

require_repo() {
  git rev-parse --git-dir >/dev/null 2>&1 || die "это не git-репозиторий"
}

require_gh() {
  command -v gh >/dev/null 2>&1 || die "нужен GitHub CLI: gh"
  gh auth status >/dev/null 2>&1 || die "gh не авторизован: gh auth login"
}

is_clean() {
  [ -z "$(git status --porcelain)" ]
}

valid_tag() {
  printf '%s' "$1" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'
}

fetch_main() {
  git fetch --quiet origin "main:refs/remotes/origin/main" --tags
}

require_main_current() {
  local branch
  branch=$(git rev-parse --abbrev-ref HEAD)
  [ "$branch" = "main" ] || die "переключитесь на main (сейчас $branch)"
  is_clean || die "рабочее дерево не чистое — закоммитьте или уберите изменения"
  fetch_main
  if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
    if git merge-base --is-ancestor HEAD origin/main; then
      git merge --ff-only --quiet origin/main
    else
      die "main разошёлся с origin/main — разберитесь вручную"
    fi
  fi
}

check_release() {
  local ci=0 require_main_head=0 tag=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --ci) ci=1; shift ;;
      --require-main-head) require_main_head=1; shift ;;
      -h|--help) usage; exit 0 ;;
      -*) die "неизвестный флаг: $1" ;;
      *)
        [ -z "$tag" ] || die "лишний аргумент: $1"
        tag="$1"
        shift
        ;;
    esac
  done

  [ -n "$tag" ] || die "укажите тег: check vX.Y.Z"
  valid_tag "$tag" || die "тег должен быть vMAJOR.MINOR.PATCH: $tag"
  local version="${tag#v}"

  require_repo
  local head_sha
  head_sha=$(git rev-parse HEAD)

  say "release-check: $tag, HEAD $head_sha"
  bash scripts/version.sh --check
  bash scripts/version.sh --check-tag "$tag"

  fetch_main
  if [ "$require_main_head" -eq 1 ]; then
    [ "$head_sha" = "$(git rev-parse origin/main)" ] \
      || die "HEAD не совпадает с origin/main — релиз должен идти с вершины main"
  else
    git merge-base --is-ancestor "$head_sha" origin/main \
      || die "HEAD не входит в main — тег нельзя ставить на боковую ветку"
  fi

  if [ "$ci" -eq 0 ]; then
    [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] \
      || die "локальная проверка запускается из main"
    is_clean || die "рабочее дерево не чистое"
    [ "$head_sha" = "$(git rev-parse origin/main)" ] \
      || die "main не совпадает с origin/main — выполните: git pull --ff-only"
  fi

  # Фиксы после release-PR допустимы: версия и CHANGELOG уже в main,
  # тег ставится на проверенный HEAD. Важно, чтобы release-коммит был
  # в истории, а не чтобы HEAD совпадал с ним.
  local re="^chore\\(release\\): ${version}( \\(#[0-9]+\\))?$"
  # grep без -q: иначе он закрывает pipe на первом совпадении, git log
  # получает SIGPIPE, а pipefail превращает успешную проверку в ошибку.
  if ! git log --format='%s' | grep -E "$re" >/dev/null; then
    die "в истории HEAD нет релизного коммита «chore(release): $version»"
  fi
  say "релизный коммит найден в истории HEAD"

  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    local tag_sha
    tag_sha=$(git rev-parse "$tag^{commit}")
    [ "$tag_sha" = "$head_sha" ] \
      || die "тег $tag указывает на $tag_sha, а не на $head_sha"
    say "тег $tag уже указывает на HEAD (повторная публикация обновит релиз)"
  else
    say "тег $tag ещё не создан — его создаст workflow после approve"
  fi

  local section_count unreleased_count
  section_count=$(awk -v v="$version" '
    index($0, "## [" v "]") == 1 { inside = 1; next }
    inside && /^## \[/ { exit }
    inside && /^- / { n++ }
    END { print n + 0 }
  ' CHANGELOG.md)
  [ "$section_count" -gt 0 ] \
    || die "в CHANGELOG.md нет непустого раздела «## [$version]»"

  unreleased_count=$(awk '
    /^## \[Unreleased\]/ { inside = 1; next }
    inside && /^## \[/ { exit }
    inside && /^- / { n++ }
    END { print n + 0 }
  ' CHANGELOG.md)
  [ "$unreleased_count" -eq 0 ] \
    || die "в [Unreleased] остались пункты ($unreleased_count) — перенесите их в [$version]"

  bash scripts/docs-check.sh
  say "release-check: ok"
}

prepare_release() {
  local part="${1:-}"
  case "$part" in
    major|minor|patch) ;;
    *) die "использование: $0 prepare major|minor|patch" ;;
  esac

  require_repo
  require_gh
  require_main_current

  local new tag branch body_file
  new=$(bash scripts/version.sh --next "$part")
  tag="v$new"
  branch="release/$tag"

  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    die "тег $tag уже существует"
  fi
  [ -z "$(git ls-remote --tags origin "refs/tags/$tag")" ] \
    || die "тег $tag уже есть на origin"
  if git rev-parse -q --verify "refs/heads/$branch" >/dev/null; then
    die "ветка $branch уже существует"
  fi
  [ -z "$(git ls-remote --heads origin "$branch")" ] \
    || die "ветка $branch уже есть на origin"

  say "готовлю $new ($part)"
  bash scripts/version.sh --bump "$part"
  bash scripts/docs-check.sh

  git switch -c "$branch"
  git add Cargo.toml Cargo.lock noctalia/plugin.toml plasmoid/metadata.json \
    app/CMakeLists.txt CHANGELOG.md
  if git diff --cached --quiet; then
    die "version.sh не изменил ни одного файла"
  fi
  git commit -s -m "chore(release): $new"

  body_file=$(mktemp "${TMPDIR:-/tmp}/ymd-release-body.XXXXXX")
  cat >"$body_file" <<EOF
## Что меняется

Релиз $new: версия во всех манифестах, \`Cargo.lock\` и раздел \`CHANGELOG.md\`.

## Клиент

- [ ] демон \`daemon/\`
- [ ] Noctalia \`noctalia/\`
- [ ] Plasma \`plasmoid/\`
- [ ] ymd-qt \`app/\`
- [ ] macOS \`macos/\`
- [x] документация / пакеты / скрипты

## Проверки

- [x] \`bash scripts/version.sh --check\`
- [x] \`bash scripts/docs-check.sh\`
- [x] \`bash scripts/pr-check.sh --body <этот PR>\`
- [ ] тесты (Docker) — запустит CI
- [ ] \`release\` — после merge и approve environment

## Как проверить

\`bash scripts/version.sh --check\` → \`версии согласованы: $new\`;
\`bash scripts/docs-check.sh\` → \`ok\`.

## Связанные issue

Нет.
EOF

  if ! PR_TITLE="chore(release): $new" bash scripts/pr-check.sh \
      --title "chore(release): $new" --body "$body_file" --base origin/main; then
    rm -f "$body_file"
    die "release-PR не прошёл pr-check — исправьте и повторите"
  fi

  git push -u origin "$branch"
  gh pr create --base main --head "$branch" \
    --title "chore(release): $new" --body-file "$body_file"
  rm -f "$body_file"

  say ""
  say "дальше: ревью и merge PR, затем"
  say "  bash scripts/release.sh publish $tag          # dry-run"
  say "  bash scripts/release.sh publish $tag --yes    # после approve"
}

publish_release() {
  local tag="" yes=0 watch=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes) yes=1; shift ;;
      --watch) watch=1; shift ;;
      -h|--help) usage; exit 0 ;;
      -*) die "неизвестный флаг: $1" ;;
      *)
        [ -z "$tag" ] || die "лишний аргумент: $1"
        tag="$1"
        shift
        ;;
    esac
  done

  [ -n "$tag" ] || die "укажите тег: publish vX.Y.Z"
  valid_tag "$tag" || die "тег должен быть vMAJOR.MINOR.PATCH: $tag"
  require_repo
  require_gh
  require_main_current
  check_release --require-main-head "$tag"

  local dry_run=true run_id url
  [ "$yes" -eq 1 ] && dry_run=false

  say "запускаю release.yml: tag=$tag dry_run=$dry_run"
  gh workflow run release.yml -f tag="$tag" -f dry_run="$dry_run"
  sleep 3
  run_id=$(gh run list --workflow=release.yml --limit 1 \
    --json databaseId --jq '.[0].databaseId')
  [ -n "$run_id" ] || die "не нашёл запуск release.yml"
  url=$(gh run view "$run_id" --json url --jq .url)
  say "запуск: $url"

  if [ "$dry_run" = true ]; then
    say "dry-run: тег и GitHub Release не создаются"
  else
    say "для публикации нужно approve environment «release» в GitHub Actions"
  fi

  if [ "$watch" -eq 1 ]; then
    gh run watch "$run_id" --exit-status
  fi
}

show_status() {
  require_repo
  local version tag unreleased
  version=$(bash scripts/version.sh)
  tag=$(git describe --tags --abbrev=0 2>/dev/null || true)
  say "версия в манифестах: $version"
  say "последний тег: ${tag:-нет}"
  if [ -n "$tag" ]; then
    say "коммитов после тега: $(git rev-list --count "$tag..HEAD")"
  fi
  unreleased=$(awk '
    /^## \[Unreleased\]/ { inside = 1; next }
    inside && /^## \[/ { exit }
    inside && /^- / { n++ }
    END { print n + 0 }
  ' CHANGELOG.md)
  say "пунктов в [Unreleased]: $unreleased"
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh release view --json tagName,publishedAt \
      --jq '"последний релиз: \(.tagName) (\(.publishedAt))"' 2>/dev/null \
      || say "релизов на GitHub пока нет"
  fi
}

case "${1:-}" in
  ""|status)
    show_status
    ;;
  prepare)
    shift
    prepare_release "$@"
    ;;
  check)
    shift
    check_release "$@"
    ;;
  publish)
    shift
    publish_release "$@"
    ;;
  -h|--help)
    usage
    ;;
  *)
    die "неизвестная команда: $1 (см. --help)"
    ;;
esac
