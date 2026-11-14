#!/usr/bin/env bash
# Версии проекта: один источник истины — Cargo.toml [workspace.package].
#
#   bash scripts/version.sh              # напечатать текущую версию
#   bash scripts/version.sh --check      # сверить все манифесты (CI, docs-check)
#   bash scripts/version.sh --set 0.3.0  # записать версию во все манифесты
#   bash scripts/version.sh --bump patch # 0.2.0 -> 0.2.1 (и запись во все)
#   bash scripts/version.sh --tag        # аннотированный тег v<version>
#   bash scripts/version.sh --check-tag v0.2.1
#
# Семантика: MAJOR.MINOR.PATCH (semver). Тег всегда с префиксом `v`.
set -euo pipefail

cd "$(dirname "$0")/.."

cargo_toml="Cargo.toml"
plugin_toml="noctalia/plugin.toml"
metadata_json="plasmoid/metadata.json"
cmake_lists="app/CMakeLists.txt"

die() { printf 'ошибка: %s\n' "$*" >&2; exit 1; }

read_cargo() {
  sed -n '/^\[workspace\.package\]/,/^\[/p' "$cargo_toml" \
    | sed -n 's/^version = "\(.*\)"/\1/p' | head -n1
}

read_plugin() {
  sed -n 's/^version = "\(.*\)"/\1/p' "$plugin_toml" | head -n1
}

read_metadata() {
  sed -n 's/.*"Version": "\([^"]*\)".*/\1/p' "$metadata_json" | head -n1
}

read_cmake() {
  sed -n 's/^project(ymd-qt VERSION \([0-9][0-9.]*\).*/\1/p' "$cmake_lists" | head -n1
}

current() {
  local version
  version=$(read_cargo)
  [ -n "$version" ] || die "не нашёл version в [workspace.package] ($cargo_toml)"
  printf '%s\n' "$version"
}

valid_version() {
  printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
}

check() {
  local expected status=0
  expected=$(current)
  local -a names=("$cargo_toml" "$plugin_toml" "$metadata_json" "$cmake_lists")
  local -a values=("$expected" "$(read_plugin)" "$(read_metadata)" "$(read_cmake)")
  local i

  for i in "${!names[@]}"; do
    if [ "${values[$i]}" = "$expected" ]; then
      printf '  ok  %-28s %s\n' "${names[$i]}" "${values[$i]}"
    else
      printf '  !!  %-28s %s (ожидалось %s)\n' \
        "${names[$i]}" "${values[$i]:-нет}" "$expected"
      status=1
    fi
  done

  if [ "$status" -eq 0 ]; then
    printf 'версии согласованы: %s\n' "$expected"
  else
    printf 'версии расходятся — запустите: bash scripts/version.sh --set %s\n' "$expected" >&2
  fi
  return "$status"
}

write_atomically() {
  local file="$1" tmp
  tmp=$(mktemp)
  cat >"$tmp"
  mv "$tmp" "$file"
}

set_version() {
  local version="$1"
  valid_version "$version" || die "версия должна быть MAJOR.MINOR.PATCH: $version"

  awk -v v="$version" '
    /^\[workspace\.package\]/ { in_pkg = 1 }
    in_pkg && /^version = "/ {
      sub(/^version = ".*"/, "version = \"" v "\"")
      in_pkg = 0
    }
    { print }
  ' "$cargo_toml" | write_atomically "$cargo_toml"

  awk -v v="$version" '
    !done && /^version = "/ {
      sub(/^version = ".*"/, "version = \"" v "\"")
      done = 1
    }
    { print }
  ' "$plugin_toml" | write_atomically "$plugin_toml"

  awk -v v="$version" '
    !done && /"Version": "/ {
      sub(/"Version": "[^"]*"/, "\"Version\": \"" v "\"")
      done = 1
    }
    { print }
  ' "$metadata_json" | write_atomically "$metadata_json"

  awk -v v="$version" '
    /^project\(ymd-qt VERSION / {
      sub(/VERSION [0-9][0-9.]*/, "VERSION " v)
    }
    { print }
  ' "$cmake_lists" | write_atomically "$cmake_lists"

  note_changelog "$version"
  printf 'версия записана: %s\n' "$version"
}

note_changelog() {
  local version="$1" file="CHANGELOG.md" date
  [ -f "$file" ] || return 0
  grep -q '^## \[Unreleased\]' "$file" || return 0
  # Уже есть раздел этой версии — не дублируем.
  grep -q "^## \[$version\]" "$file" && return 0
  date=$(date +%Y-%m-%d)
  awk -v v="$version" -v d="$date" '
    !done && /^## \[Unreleased\]/ {
      print
      print ""
      print "## [" v "] - " d
      done = 1
      next
    }
    { print }
  ' "$file" | write_atomically "$file"
  printf 'CHANGELOG.md: добавлен раздел %s\n' "$version"
}

bump() {
  local part="$1" old major minor patch
  old=$(current)
  IFS=. read -r major minor patch <<<"$old"
  case "$part" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
    *) die "ожидалось major|minor|patch, получено: $part" ;;
  esac
  set_version "$major.$minor.$patch"
}

tag() {
  local version tag_name
  version=$(current)
  tag_name="v$version"
  git rev-parse --git-dir >/dev/null 2>&1 || die "это не git-репозиторий"
  if git rev-parse -q --verify "refs/tags/$tag_name" >/dev/null; then
    die "тег $tag_name уже существует"
  fi
  git tag -a "$tag_name" -m "ymd $version"
  printf 'создан тег %s\nдальше: git push origin main && git push origin %s\n' \
    "$tag_name" "$tag_name"
}

check_tag() {
  local ref="${1:-}" version
  version=$(current)
  [ -n "$ref" ] || die "укажите тег: --check-tag v$version"
  if [ "${ref#v}" != "$version" ]; then
    die "тег $ref не совпадает с версией в манифестах ($version)"
  fi
  printf 'тег %s совпадает с версией %s\n' "$ref" "$version"
}

case "${1:-}" in
  ""|--get)
    current
    ;;
  --check)
    check
    ;;
  --set)
    [ $# -eq 2 ] || die "использование: $0 --set MAJOR.MINOR.PATCH"
    set_version "$2"
    ;;
  --bump)
    [ $# -eq 2 ] || die "использование: $0 --bump major|minor|patch"
    bump "$2"
    ;;
  --tag)
    tag
    ;;
  --check-tag)
    check_tag "${2:-}"
    ;;
  -h|--help)
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    die "неизвестный аргумент: $1 (см. --help)"
    ;;
esac
