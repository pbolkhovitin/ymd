#!/usr/bin/env bash
# Сборка меню-бар клиента ymd для macOS (Apple Silicon и Intel).
#
#   bash macos/build.sh            # собрать dist/ymd-menubar.app
#   bash macos/build.sh --install  # ещё и скопировать в ~/Applications
#
# Нужны: Xcode Command Line Tools (`xcode-select --install`).
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "нужен macOS (сейчас $(uname -s))" >&2
  exit 1
fi
if ! command -v swift >/dev/null 2>&1; then
  echo "нет swift: xcode-select --install" >&2
  exit 1
fi

version="$(bash scripts/version.sh)"
app="$repo/dist/ymd-menubar.app"

echo "сборка ymd-menubar ${version}…"
swift build --package-path macos -c release --product ymd-menubar

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp macos/.build/release/ymd-menubar "$app/Contents/MacOS/ymd-menubar"
sed "s/@VERSION@/$version/g" macos/Info.plist > "$app/Contents/Info.plist"
codesign --force --sign - "$app" >/dev/null 2>&1 || true

echo "готово: $app"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/ymd-menubar.app"
  cp -R "$app" "$HOME/Applications/ymd-menubar.app"
  echo "установлено: $HOME/Applications/ymd-menubar.app"
  echo "запуск: open ~/Applications/ymd-menubar.app"
fi
