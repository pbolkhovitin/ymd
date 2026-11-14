#!/usr/bin/env bash
# Проверка оформления pull request.
#
#   bash scripts/pr-check.sh --body /tmp/pr.md [--base origin/main]
#   PR_BODY=... PR_TITLE=... BASE_SHA=<sha> bash scripts/pr-check.sh   # CI
#
# Что проверяется:
#   · заголовок в стиле Conventional Commits (squash-merge берёт его как
#     сообщение коммита в main);
#   · все разделы .github/PULL_REQUEST_TEMPLATE.md;
#   · галочки «Клиент» совпадают с каталогами, которые PR меняет;
#   · при правках кода (daemon, plasmoid, app, noctalia, macos) в
#     CHANGELOG.md появляется новый пункт в [Unreleased].
#
# Код возврата: 0 — замечаний нет, 1 — есть, 2 — ошибка запуска.
# Это помощь автору и агенту, а не защита от злого умысла: скрипт лежит
# в PR и может быть изменён. Содержательное ревью остаётся за CODEOWNERS.

set -u

cd "$(dirname "$0")/.." || exit 2

body_file=""
base="${BASE_SHA:-}"
title="${PR_TITLE:-}"
status=0
problems=0

usage() {
  cat <<'EOF'
Использование: bash scripts/pr-check.sh [--body FILE] [--base REF] [--title TEXT]

  --body FILE   тело PR (иначе — переменная PR_BODY)
  --base REF    ветка/коммит для сравнения (иначе BASE_SHA, origin/main, main)
  --title TEXT  заголовок PR (иначе PR_TITLE)

Без --body локально проверяются только diff и CHANGELOG.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --body)
      [ $# -ge 2 ] || { printf 'нет значения для --body\n' >&2; exit 2; }
      body_file="$2"
      shift 2
      ;;
    --base)
      [ $# -ge 2 ] || { printf 'нет значения для --base\n' >&2; exit 2; }
      base="$2"
      shift 2
      ;;
    --title)
      [ $# -ge 2 ] || { printf 'нет значения для --title\n' >&2; exit 2; }
      title="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'неизвестный аргумент: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

say() { printf '%s\n' "$*"; }

fail() {
  status=1
  problems=$((problems + 1))
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::error title=pr-policy::%s\n' "$*"
  fi
  say "· ошибка: $*"
}

ok() { say "· ok: $*"; }
note() { say "· к сведению: $*"; }

# --- база для diff ---------------------------------------------------------

if [ -z "$base" ]; then
  if git rev-parse --verify -q origin/main >/dev/null 2>&1; then
    base=origin/main
  elif git rev-parse --verify -q main >/dev/null 2>&1; then
    base=main
  fi
fi

if [ -z "$base" ] || ! git rev-parse --verify -q "$base^{commit}" >/dev/null 2>&1; then
  printf 'ошибка: не найдена база для сравнения (укажите --base или BASE_SHA)\n' >&2
  exit 2
fi

if ! files=$(git diff --name-only "$base...HEAD" 2>/dev/null); then
  printf 'ошибка: git diff %s...HEAD не выполнился\n' "$base" >&2
  exit 2
fi

file_count=$(printf '%s\n' "$files" | grep -c . || true)
say "pr-check: база $base, изменено файлов: $file_count"

# --- release PR ------------------------------------------------------------
# Релизный PR неизбежно меняет noctalia/ и plasmoid|app/ (версии в
# манифестах) и не добавляет пункт в [Unreleased], а переносит его в
# раздел версии. Для заголовка chore(release): X.Y.Z действуют отдельные
# правила: только файлы релиза и непустой раздел новой версии.

release_pr=0
release_version=""
if [ -n "$title" ] \
    && printf '%s' "$title" | grep -Eq '^chore\(release\): [0-9]+\.[0-9]+\.[0-9]+$'; then
  release_version="${title#chore(release): }"
  if [ "$file_count" -gt 0 ]; then
    release_files_ok=1
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      case "$path" in
        CHANGELOG.md|Cargo.toml|Cargo.lock|noctalia/plugin.toml|plasmoid/metadata.json|app/CMakeLists.txt)
          ;;
        *)
          release_files_ok=0
          break
          ;;
      esac
    done <<<"$files"
    if [ "$release_files_ok" -eq 1 ]; then
      release_pr=1
      ok "release PR: только манифесты версий и CHANGELOG"
    else
      note "заголовок chore(release), но в diff есть посторонние файлы — действуют обычные правила"
    fi
  fi
fi

# --- тело PR ---------------------------------------------------------------

body=""
if [ -n "$body_file" ]; then
  if [ ! -r "$body_file" ]; then
    printf 'ошибка: не читается файл тела PR: %s\n' "$body_file" >&2
    exit 2
  fi
  body=$(cat "$body_file")
elif [ -n "${PR_BODY:-}" ]; then
  body="$PR_BODY"
fi

# Вырезает HTML-комментарии, в том числе многострочные.
strip_comments() {
  awk '
    BEGIN { in_c = 0 }
    {
      out = ""
      rest = $0
      while (length(rest) > 0) {
        if (in_c) {
          i = index(rest, "-->")
          if (i == 0) { rest = "" }
          else { rest = substr(rest, i + 3); in_c = 0 }
        } else {
          i = index(rest, "<!--")
          if (i == 0) { out = out rest; rest = "" }
          else {
            out = out substr(rest, 1, i - 1)
            rest = substr(rest, i + 4)
            in_c = 1
          }
        }
      }
      print out
    }
  '
}

# Печатает строки раздела "## <heading>" до следующего "## ".
section() {
  printf '%s\n' "$body" | awk -v h="$1" '
    {
      line = $0
      sub(/\r$/, "", line)
      sub(/[ \t]+$/, "", line)
      if (line == "## " h) { inside = 1; next }
      if (inside && line ~ /^## /) { inside = 0 }
      if (inside) print
    }
  '
}

# В разделе есть содержательная строка (не комментарий и не пробелы).
has_text() {
  printf '%s\n' "$1" | strip_comments | grep -qE '[^[:space:]]'
}

# В разделе есть хотя бы одна отмеченная галочка.
has_check() {
  printf '%s\n' "$1" | grep -qE '^[[:space:]]*-[[:space:]]*\[[xX]\]'
}

# Заголовок раздела присутствует в теле.
has_section() {
  printf '%s\n' "$body" | sed 's/\r$//' \
    | grep -qE "^## $1[[:space:]]*$"
}

if [ -z "$body" ]; then
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    fail "тело PR пустое: заполните .github/PULL_REQUEST_TEMPLATE.md"
  else
    note "тело PR не передано — проверки шаблона пропущены (--body FILE)"
  fi
else
  what=$(section "Что меняется")
  client=$(section "Клиент")
  checks=$(section "Проверки")
  how=$(section "Как проверить")

  missing=""
  for name in "Что меняется" "Клиент" "Проверки" "Как проверить" "Связанные issue"; do
    # Раздел может быть пустым, но заголовок обязан быть.
    has_section "$name" || missing="$missing «$name»"
  done

  if [ -n "$missing" ]; then
    fail "нет разделов шаблона:$missing"
  else
    ok "все разделы шаблона на месте"
  fi

  if has_section "Что меняется" && ! has_text "$what"; then
    fail "раздел «Что меняется» пустой — одно-два предложения о задаче PR"
  fi

  if has_section "Клиент" && ! has_check "$client"; then
    fail "в разделе «Клиент» не отмечен ни один клиент"
  fi

  if has_section "Проверки" && ! has_check "$checks"; then
    fail "в разделе «Проверки» не отмечено ни одной проверки"
  fi

  if has_section "Как проверить" && ! has_text "$how"; then
    fail "раздел «Как проверить» пустой — команды и ожидаемый результат"
  fi

  # Галочки должны соответствовать каталогам в diff. У release-PR
  # манифесты всех клиентов, поэтому сверка с каталогами не применяется.
  if has_section "Клиент" && [ "$file_count" -gt 0 ] && [ "$release_pr" -eq 0 ]; then
    check_client() {
      printf '%s\n' "$client" \
        | grep -E '^[[:space:]]*-[[:space:]]*\[[xX]\]' \
        | grep -qE "$1"
    }
    client_bad=0
    for spec in "noctalia/:Noctalia" "plasmoid/:Plasma" "app/:ymd-qt" \
        "daemon/:демон" "macos/:macOS|macos"; do
      dir="${spec%%:*}"
      label="${spec#*:}"
      if printf '%s\n' "$files" | grep -q "^$dir"; then
        if ! check_client "$label"; then
          fail "PR меняет $dir, но в «Клиент» не отмечено «$label»"
          client_bad=1
        fi
      fi
    done
    [ "$client_bad" -eq 0 ] && ok "галочки «Клиент» сверены с diff"
  fi
fi

# --- заголовок -------------------------------------------------------------

if [ -n "$title" ]; then
  if printf '%s\n' "$title" | grep -qE '^(feat|fix|docs|chore|refactor|test|ci|build|perf|style|revert)(\([^)]+\))?!?: .+'; then
    ok "заголовок в стиле Conventional Commits"
  else
    fail "заголовок PR должен быть вида «fix(scope): что изменено» — squash-merge делает его сообщением коммита"
  fi
  if [ "${#title}" -gt 72 ]; then
    note "заголовок длиннее 72 символов — в истории main он обрежется"
  fi
fi

# --- CHANGELOG при правках кода -------------------------------------------

code_dirs=""
for dir in daemon plasmoid app noctalia macos; do
  if printf '%s\n' "$files" | grep -q "^$dir/"; then
    code_dirs="$code_dirs $dir/"
  fi
done

count_unreleased() {
  git show "$1:CHANGELOG.md" 2>/dev/null | awk '
    /^## \[Unreleased\]/ { inside = 1; next }
    inside && /^## / { exit }
    inside && /^- / { n++ }
    END { print n + 0 }
  '
}

if [ "$release_pr" -eq 1 ]; then
  if ! printf '%s\n' "$files" | grep -qx 'CHANGELOG.md'; then
    fail "release PR: CHANGELOG.md не изменён"
  else
    head_section=$(git show "HEAD:CHANGELOG.md" 2>/dev/null | awk -v v="$release_version" '
      index($0, "## [" v "]") == 1 { inside = 1; next }
      inside && /^## \[/ { exit }
      inside && /^- / { n++ }
      END { print n + 0 }
    ')
    head_unreleased=$(count_unreleased HEAD)
    if [ "${head_section:-0}" -gt 0 ] && [ "${head_unreleased:-0}" -eq 0 ]; then
      ok "release PR: раздел $release_version заполнен, [Unreleased] пуст"
    else
      fail "release PR: нужен непустой раздел [$release_version] и пустой [Unreleased] (сейчас $release_version: ${head_section:-0}, Unreleased: ${head_unreleased:-0})"
    fi
  fi
elif [ -n "$code_dirs" ]; then
  if ! printf '%s\n' "$files" | grep -qx 'CHANGELOG.md'; then
    fail "изменён код ($code_dirs), а CHANGELOG.md — нет"
  else
    base_n=$(count_unreleased "$base")
    head_n=$(count_unreleased HEAD)
    if [ "${head_n:-0}" -gt "${base_n:-0}" ]; then
      ok "CHANGELOG.md: новый пункт в [Unreleased]"
    else
      fail "в [Unreleased] не появилось нового пункта (было ${base_n:-0}, стало ${head_n:-0})"
    fi
  fi
else
  note "код не менялся — CHANGELOG не обязателен"
fi

# --- итог ------------------------------------------------------------------

say ""
if [ "$status" -eq 0 ]; then
  say "ok: оформление PR в порядке"
else
  say "ошибка: замечаний — $problems; правила — CONTRIBUTING.md"
fi

exit "$status"
