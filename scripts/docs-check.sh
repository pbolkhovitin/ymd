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
code_ts=$(git log -1 --format=%ct -- daemon plasmoid app packaging 2>/dev/null || echo 0)
docs_ts=$(git log -1 --format=%ct -- README.md AGENTS.md docs notes 2>/dev/null || echo 0)

if [ "${code_ts:-0}" -gt "${docs_ts:-0}" ]; then
  say "· код менялся позже документации — проверьте, что этап описан"
  say "    код:  $(date -d "@$code_ts" '+%Y-%m-%d %H:%M')"
  say "    доки: $(date -d "@$docs_ts" '+%Y-%m-%d %H:%M')"
  status=1
else
  say "· документация не старше кода"
fi

# 3. Файлы кода без упоминания в документации.
missing=""
for file in daemon/src/*.rs plasmoid/contents/ui/*.qml plasmoid/contents/ui/*.js \
    app/src/*.cpp app/qml/*.qml app/qml/*.js; do
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

[ "$status" -eq 0 ] && say "ok: документация согласована"
exit "$status"
