#!/usr/bin/env bash
# Архив плагина Noctalia для ручной установки: dist/ymd-noctalia-plugin-<ver>.tar.gz
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
src="$repo/noctalia"
ver=$(sed -n 's/^version = "\(.*\)"/\1/p' "$src/plugin.toml")

if [[ -z "$ver" ]]; then
  echo "не нашёл version в $src/plugin.toml" >&2
  exit 1
fi

mkdir -p "$repo/dist"
out="$repo/dist/ymd-noctalia-plugin-$ver.tar.gz"
tar czf "$out" -C "$src" .
echo "$out"
