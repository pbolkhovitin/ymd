#!/usr/bin/env bash
# Генерация справочных разделов документации из кода.
#
#   bash scripts/docs-sync.sh            # переписать файлы
#   bash scripts/docs-sync.sh --check    # только проверить (CI)
#
# Генерируются блоки между маркерами <!-- generated:routes --> …
# в docs/reference/routes.md и docs/reference/state.md. Проза вокруг
# маркеров не трогается.
set -euo pipefail

cd "$(dirname "$0")/.."

mode="write"
case "${1:-}" in
  --check) mode="check" ;;
  ""|--write) mode="write" ;;
  -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) printf 'неизвестный флаг: %s\n' "$1" >&2; exit 2 ;;
esac

httpd=daemon/src/httpd.rs
state=daemon/src/state.rs
routes_doc=docs/reference/routes.md
state_doc=docs/reference/state.md

[ -f "$httpd" ] || { printf 'нет %s\n' "$httpd" >&2; exit 1; }
[ -f "$state" ] || { printf 'нет %s\n' "$state" >&2; exit 1; }

# --- маршруты -------------------------------------------------------------
gen_routes() {
  awk '
    /\.route\(/ {
      line = $0
      if (line !~ /"\/v1\//) { getline nxt; line = line " " nxt }
      print line
    }
  ' "$httpd" \
  | while IFS= read -r line; do
      path=$(printf '%s' "$line" | grep -oE '"/v1/[^"]*"' | head -1 | tr -d '"')
      [ -n "$path" ] || continue
      method=""
      printf '%s' "$line" | grep -q 'get(' && method="GET"
      printf '%s' "$line" | grep -q 'post(' && method="${method:-}POST"
      printf '%s' "$line" | grep -q 'patch(' && method="${method:-}PATCH"
      printf '%s' "$line" | grep -q 'put(' && method="${method:-}PUT"
      printf '%s' "$line" | grep -q 'delete(' && method="${method:-}DELETE"
      [ -n "$method" ] || method="?"
      printf '| %s | `%s` |\n' "$method" "$path"
    done | sort -t'`' -k2,2
}

# --- поля состояния -------------------------------------------------------
camel() {
  printf '%s' "$1" | awk -F_ '{
    out = $1
    for (i = 2; i <= NF; i++) out = out toupper(substr($i, 1, 1)) substr($i, 2)
    print out
  }'
}

gen_state() {
  awk '/^pub struct State \{/{inside=1; next} inside && /^\}/{exit} inside{print}' "$state" \
  | grep -E '^[[:space:]]+pub [a-z_0-9]+:' \
  | while IFS= read -r line; do
      field=$(printf '%s' "$line" | sed -E 's/.*pub ([a-z_0-9]+):.*/\1/')
      type=$(printf '%s' "$line" | sed -E 's/.*:[[:space:]]*//; s/,$//')
      printf '| `%s` | `%s` |\n' "$(camel "$field")" "$type"
    done
}

routes_block=$(gen_routes)
state_block=$(gen_state)

[ -n "$routes_block" ] || { printf 'не удалось разобрать маршруты\n' >&2; exit 1; }
[ -n "$state_block" ] || { printf 'не удалось разобрать поля State\n' >&2; exit 1; }

ensure_file() {
  local file="$1" title="$2" name="$3"
  [ -f "$file" ] && return 0
  mkdir -p "$(dirname "$file")"
  {
    printf '# %s\n\n' "$title"
    printf 'Файл генерируется `bash scripts/docs-sync.sh`; правьте код, а не таблицу.\n\n'
    printf '<!-- generated:%s -->\n<!-- /generated:%s -->\n' "$name" "$name"
  } >"$file"
}

block_of() {
  local file="$1" name="$2"
  awk -v name="$name" '
    $0 == "<!-- generated:" name " -->" {inside=1; next}
    $0 == "<!-- /generated:" name " -->" {inside=0; next}
    inside {print}
  ' "$file"
}

replace_block() {
  local file="$1" name="$2" content
  content=$(cat)
  awk -v name="$name" -v content="$content" '
    BEGIN { inblock = 0; printed = 0 }
    $0 == "<!-- generated:" name " -->" {
      print
      print content
      inblock = 1
      printed = 1
      next
    }
    $0 == "<!-- /generated:" name " -->" { inblock = 0; print; next }
    !inblock { print }
    END { if (!printed) print "<!-- generated:" name " -->\n" content "\n<!-- /generated:" name " -->" }
  ' "$file" >"$file.tmp"
  mv "$file.tmp" "$file"
}

sync_one() {
  local file="$1" name="$2" title="$3" content="$4"
  ensure_file "$file" "$title" "$name"
  if [ "$mode" = check ]; then
    local current
    current=$(block_of "$file" "$name")
    if [ "$current" != "$content" ]; then
      printf '· %s (%s) расходится с кодом\n' "$file" "$name"
      diff <(printf '%s\n' "$current") <(printf '%s\n' "$content") | head -20 | sed 's/^/    /'
      return 1
    fi
    printf '· %s актуален\n' "$file"
    return 0
  fi
  printf '%s\n' "$content" | replace_block "$file" "$name"
  printf '· %s обновлён\n' "$file"
}

status=0
sync_one "$routes_doc" routes "HTTP-контракт демона" "$routes_block" || status=1
sync_one "$state_doc" state "Состояние плеера" "$state_block" || status=1

if [ "$mode" = check ]; then
  if [ "$status" -ne 0 ]; then
    printf 'документация разошлась с кодом — запустите bash scripts/docs-sync.sh\n' >&2
  else
    printf 'ok: справочные разделы совпадают с кодом\n'
  fi
fi
exit "$status"
