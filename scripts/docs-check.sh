#!/usr/bin/env bash
# Проверка, что документация не отстала от кода.
#
# Использование: bash scripts/docs-check.sh
# Код возврата: 0 — всё согласовано, 1 — есть что обновить.

set -u

cd "$(dirname "$0")/.." || exit 1

status=0

say() { printf '%s\n' "$*"; }

# 1. Маркеры устаревания в документации.
markers=$(grep -Rn --include='*.md' -E 'не начат|не сделано|TODO|устарел|FIXME' \
  README.md AGENTS.md docs notes 2>/dev/null)

if [ -n "$markers" ]; then
  say "· маркеры к сведению (убедитесь, что они всё ещё верны):"
  printf '%s\n' "$markers" | sed 's/^/    /'
else
  say "· маркеров устаревания нет"
fi

# 2. Документация новее кода?
# Гейт — только исходники клиентов и демона: они меняют поведение.
# Упаковка, скрипты и workflow — подсказка, а не блокер (правка в spec или
# исключение тестов из rpm не требует раздела в docs).
# --no-merges: merge-коммит (например, «Update branch» в PR) иначе выглядит
# как свежая правка кода и ложно роняет проверку свежести документации.
src_ts=$(git log -1 --no-merges --format=%ct -- daemon plasmoid app noctalia macos 2>/dev/null || echo 0)
pkg_ts=$(git log -1 --no-merges --format=%ct -- packaging scripts .github 2>/dev/null || echo 0)
docs_ts=$(git log -1 --no-merges --format=%ct -- README.md AGENTS.md CONTRIBUTING.md CHANGELOG.md docs notes 2>/dev/null || echo 0)

if [ "${src_ts:-0}" -gt "${docs_ts:-0}" ]; then
  say "· код менялся позже документации — проверьте, что этап описан"
  say "    код:  $(date -d "@$src_ts" '+%Y-%m-%d %H:%M')"
  say "    доки: $(date -d "@$docs_ts" '+%Y-%m-%d %H:%M')"
  status=1
else
  say "· документация не старше кода"
fi

if [ "${pkg_ts:-0}" -gt "${docs_ts:-0}" ]; then
  say "· упаковка или скрипты менялись позже документации (к сведению)"
  say "    упаковка: $(date -d "@$pkg_ts" '+%Y-%m-%d %H:%M')"
  say "    доки:     $(date -d "@$docs_ts" '+%Y-%m-%d %H:%M')"
fi

# 3. Файлы кода без упоминания в документации.
missing=""
for file in daemon/src/*.rs plasmoid/contents/ui/*.qml plasmoid/contents/ui/*.js \
    app/src/*.cpp app/qml/*.qml app/qml/*.js \
    noctalia/*.luau noctalia/lib/*.luau; do
  [ -e "$file" ] || continue
  base=$(basename "$file")
  case "$base" in main.rs|lib.rs|main.cpp) continue ;; esac
  if ! grep -Rq --include='*.md' "$base" README.md AGENTS.md docs notes 2>/dev/null; then
    missing="$missing $base"
  fi
done

if [ -n "$missing" ]; then
  say "· не упомянуты в документации:$missing"
  status=1
else
  say "· все модули упомянуты"
fi

# 4. Каждый маршрут из httpd.rs описан в документации.
routes=$(grep -oE '"/v1/[^"]*"' daemon/src/httpd.rs 2>/dev/null \
  | tr -d '"' | sed 's/?.*//' | sort -u)
undocumented=""
for route in $routes; do
  if ! grep -Rq --include='*.md' -- "$route" README.md AGENTS.md docs notes 2>/dev/null; then
    undocumented="$undocumented $route"
  fi
done

if [ -n "$undocumented" ]; then
  say "· маршруты без описания в документации:"
  for route in $undocumented; do say "    $route"; done
  status=1
else
  count=$(printf '%s\n' $routes | grep -c . || true)
  say "· все маршруты описаны ($count)"
fi

# 5. Копии format.js у клиентов должны совпадать.
fmt_ref="plasmoid/contents/ui/format.js"
fmt_copies="app/qml/format.js"
fmt_bad=""
if [ -f "$fmt_ref" ]; then
  for copy in $fmt_copies; do
    [ -f "$copy" ] || continue
    if ! cmp -s "$fmt_ref" "$copy"; then
      fmt_bad="$fmt_bad $copy"
    fi
  done
fi

if [ -n "$fmt_bad" ]; then
  say "· format.js расходится с $fmt_ref:$fmt_bad"
  status=1
else
  say "· format.js у клиентов совпадает"
fi

# 6. Версии в манифестах совпадают (один источник — Cargo.toml).
if version_out=$(bash scripts/version.sh --check 2>&1); then
  say "· версии манифестов согласованы"
else
  say "· версии манифестов расходятся:"
  printf '%s\n' "$version_out" | sed 's/^/    /'
  status=1
fi

[ "$status" -eq 0 ] && say "ok: документация, клиенты и версии согласованы"
exit "$status"
