#!/usr/bin/env bash
# Оценка влияния изменений на версию по SemVer.
#
#   bash scripts/version-impact.sh                 # с последнего тега
#   bash scripts/version-impact.sh v0.3.0 --json
#
# Печатает рекомендуемый bump (none|patch|minor|major), причины и следующую
# версию. Правило — docs/13-versioning.md, раздел «Критерии повышения версии».
set -euo pipefail

cd "$(dirname "$0")/.."

since=""
json=0
for arg in "$@"; do
  case "$arg" in
    --json) json=1 ;;
    -h|--help)
      sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) printf 'неизвестный флаг: %s\n' "$arg" >&2; exit 2 ;;
    *) since="$arg" ;;
  esac
done

if [ -z "$since" ]; then
  since=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)
fi
if [ -z "$since" ]; then
  since=$(git rev-list --max-parents=0 HEAD | tail -1)
fi
git rev-parse -q --verify "$since^{commit}" >/dev/null \
  || { printf 'нет такой ревизии: %s\n' "$since" >&2; exit 2; }

range="$since..HEAD"

# --- 1. Сообщения коммитов (Conventional Commits) --------------------------
major_reasons=()
minor_reasons=()
patch_reasons=()
count_major=0 count_minor=0 count_patch=0 count_other=0

while IFS=$'\t' read -r subject breaking; do
  [ -n "$subject" ] || continue
  type=$(printf '%s' "$subject" | sed -nE 's/^([a-z]+)(\([^)]*\))?!?:.*/\1/p')

  if [ "$breaking" = 1 ]; then
    count_major=$((count_major + 1))
    major_reasons+=("$subject")
    continue
  fi
  case "$type" in
    feat)
      count_minor=$((count_minor + 1)); minor_reasons+=("$subject") ;;
    fix|perf|revert)
      count_patch=$((count_patch + 1)); patch_reasons+=("$subject") ;;
    refactor|build|ci|style|test|docs|chore|"")
      count_other=$((count_other + 1)) ;;
    *)
      count_other=$((count_other + 1)) ;;
  esac
done < <(git log --no-merges --format='%s%x1f%b%x1e' "$range" | awk '
  BEGIN { RS = "\036" }
  NF {
    split($0, parts, "\037")
    subject = parts[1]
    sub(/^[[:space:]]+/, "", subject)
    body = $0
    sub(/^[^\037]*\037/, "", body)
    breaking = (subject ~ /^[a-z]+(\([^)]*\))?!:/) || (body ~ /BREAKING CHANGE/)
    gsub(/[\t\n\r]/, " ", subject)
    print subject "\t" (breaking ? 1 : 0)
  }
')

# --- 2. Контракт: маршруты /v1/* ------------------------------------------
httpd_diff=$(git diff "$since"..HEAD -- daemon/src/httpd.rs || true)
removed_routes=$(printf '%s\n' "$httpd_diff" | grep -E '^-[^-].*\.route\(' \
  | grep -oE '"/v1/[^"]*"' | tr -d '"' | sort -u || true)
added_routes=$(printf '%s\n' "$httpd_diff" | grep -E '^\+[^+].*\.route\(' \
  | grep -oE '"/v1/[^"]*"' | tr -d '"' | sort -u || true)

# --- 3. Контракт: поля состояния ------------------------------------------
state_diff=$(git diff "$since"..HEAD -- daemon/src/state.rs || true)
removed_fields=$(printf '%s\n' "$state_diff" | grep -E '^-[^-][[:space:]]+pub [a-z_0-9]+:' \
  | sed -E 's/.*pub ([a-z_0-9]+):.*/\1/' | sort -u || true)
added_fields=$(printf '%s\n' "$state_diff" | grep -E '^\+[^+][[:space:]]+pub [a-z_0-9]+:' \
  | sed -E 's/.*pub ([a-z_0-9]+):.*/\1/' | sort -u || true)

# --- 4. plugin_api: повышение — новая возможность, понижение — разрыв ----
api_diff=$(git diff "$since"..HEAD -- noctalia/plugin.toml || true)
old_api=$(git show "$since:noctalia/plugin.toml" 2>/dev/null \
  | sed -nE 's/^plugin_api *= *([0-9]+).*/\1/p' || true)
new_api=$(sed -nE 's/^plugin_api *= *([0-9]+).*/\1/p' noctalia/plugin.toml 2>/dev/null || true)

bump="none"
raise() {
  case "$1" in
    major) bump="major" ;;
    minor) [ "$bump" = major ] || bump="minor" ;;
    patch) [ "$bump" = major ] || [ "$bump" = minor ] || bump="patch" ;;
  esac
}

[ "$count_major" -gt 0 ] && raise major
if [ -n "$removed_routes" ] || [ -n "$removed_fields" ]; then
  raise major
fi
if [ -n "$old_api" ] && [ -n "$new_api" ] && [ "$new_api" -lt "$old_api" ]; then
  raise major
fi

[ "$count_minor" -gt 0 ] && raise minor
if [ -n "$added_routes" ] || [ -n "$added_fields" ]; then
  raise minor
fi
if [ -n "$old_api" ] && [ -n "$new_api" ] && [ "$new_api" -gt "$old_api" ]; then
  raise minor
fi

[ "$count_patch" -gt 0 ] && raise patch
# Правки кода без feat/fix (refactor, ci, сборка) всё равно меняют артефакты.
if [ "$bump" = none ] && [ -n "$(git diff --name-only "$since"..HEAD -- daemon/src noctalia plasmoid app macos packaging 2>/dev/null || true)" ]; then
  raise patch
fi

current=$(bash scripts/version.sh)
case "$bump" in
  none|patch) : ;;
esac
next=$(bash scripts/version.sh --next "$bump" 2>/dev/null || printf '%s' "$current")

json_list() {
  local first=1 item escaped
  printf '['
  for item in "$@"; do
    [ -n "$item" ] || continue
    [ "$first" = 1 ] || printf ','
    first=0
    escaped=$(printf '%s' "$item" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '"%s"' "$escaped"
  done
  printf ']'
}

if [ "$json" = 1 ]; then
  all_reasons=()
  for reason in ${major_reasons[@]+"${major_reasons[@]}"} ${minor_reasons[@]+"${minor_reasons[@]}"} ${patch_reasons[@]+"${patch_reasons[@]}"}; do
    [ -n "$reason" ] && all_reasons+=("$reason")
  done
  mapfile -t reason_items < <(printf '%s\n' ${all_reasons[@]+"${all_reasons[@]}"} | sed '/^$/d' | head -40)
  routes_items=()
  [ -n "$removed_routes" ] && read -r -a routes_items <<<"$removed_routes"
  fields_items=()
  [ -n "$removed_fields" ] && read -r -a fields_items <<<"$removed_fields"

  reasons_json=$(json_list ${reason_items[@]+"${reason_items[@]}"})
  route_json=$(json_list ${routes_items[@]+"${routes_items[@]}"})
  field_json=$(json_list ${fields_items[@]+"${fields_items[@]}"})
  cat <<EOF
{
  "since": "$since",
  "current": "$current",
  "bump": "$bump",
  "next": "$next",
  "commits": {"major": $count_major, "minor": $count_minor, "patch": $count_patch, "other": $count_other},
  "removedRoutes": $route_json,
  "removedFields": $field_json,
  "reasons": $reasons_json
}
EOF
  exit 0
fi

say() { printf '%s\n' "$*"; }
say "с ${since} по HEAD"
say "  коммитов: major=$count_major minor=$count_minor patch=$count_patch прочих=$count_other"
[ -n "$removed_routes" ] && say "  удалены маршруты: $(printf '%s ' $removed_routes)"
[ -n "$added_routes" ] && say "  добавлены маршруты: $(printf '%s ' $added_routes)"
[ -n "$removed_fields" ] && say "  удалены поля состояния: $(printf '%s ' $removed_fields)"
[ -n "$added_fields" ] && say "  добавлены поля состояния: $(printf '%s ' $added_fields)"
if [ -n "$old_api$new_api" ] && [ "$old_api" != "$new_api" ]; then
  say "  plugin_api: ${old_api:-?} → ${new_api:-?}"
fi
for r in "${major_reasons[@]:-}"; do [ -n "$r" ] && say "  major: $r"; done
for r in "${minor_reasons[@]:-}"; do [ -n "$r" ] && say "  minor: $r"; done
say ""
if [ "$bump" = none ]; then
  say "версия не меняется (остаётся $current)"
else
  say "рекомендация: $bump → $next"
  say "  bash scripts/release.sh prepare $bump"
fi
