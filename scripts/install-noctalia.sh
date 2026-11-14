#!/usr/bin/env bash
# Подключение плагина Noctalia из репозитория (симлинк, а не копия).
#
#   bash scripts/install-noctalia.sh            # подключить/обновить ссылку
#   bash scripts/install-noctalia.sh --remove   # отключить
#
# Копию Noctalia перезаписывает при обновлении плагина из источника, поэтому
# источником истины остаётся рабочий каталог репозитория.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
id="pbolkhovitin/yandex-music"
name="${id#*/}"                       # yandex-music
plugins="${XDG_DATA_HOME:-$HOME/.local/share}/noctalia/plugins"
link="$plugins/$name"

if [[ "${1:-}" == "--remove" ]]; then
  rm -f "$link"
  echo "удалён симлинк: $link"
  if command -v noctalia >/dev/null 2>&1; then
    noctalia msg plugins disable "$id" >/dev/null 2>&1 || true
  fi
  exit 0
fi

if [[ ! -f "$repo/noctalia/plugin.toml" ]]; then
  echo "нет $repo/noctalia/plugin.toml — запустите из корня репозитория" >&2
  exit 1
fi

mkdir -p "$plugins"
ln -sfn "$repo/noctalia" "$link"
echo "ссылка: $link -> $repo/noctalia"

if ! command -v noctalia >/dev/null 2>&1; then
  echo "Noctalia не найдена в PATH: поставьте плагин вручную или запустите позже"
  exit 0
fi

if ! noctalia msg plugins list 2>/dev/null | grep -q "^$id "; then
  noctalia msg plugins enable "$id" >/dev/null 2>&1 || true
  echo "плагин включён: $id"
else
  echo "плагин уже включён: $id (правки .luau подхватывает хот-релоад)"
fi

echo "дальше: добавьте виджет «ymd» в бар через настройки Noctalia"
