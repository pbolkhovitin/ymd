#!/usr/bin/env bash
# Сборка DMG с меню-бар клиентом ymd (macOS).
#
#   bash macos/build-dmg.sh                  # собрать .app и dist/ymd-menubar-<вер>.dmg
#   bash macos/build-dmg.sh --no-build       # использовать готовый dist/ymd-menubar.app
#   bash macos/build-dmg.sh --sign "Developer ID Application: …"
#
# Нужны: macOS + Xcode Command Line Tools (`xcode-select --install`).
# Без Developer ID DMG собирается, но приложение не нотаризовано: при первом
# запуске — правый клик → «Открыть» либо `xattr -dr com.apple.quarantine`.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "нужен macOS (сейчас $(uname -s))" >&2
  exit 1
fi

build=1
identity=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build) build=0; shift ;;
    --sign) identity="${2:?--sign требует идентификатор}"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 1 ;;
  esac
done

version="$(bash scripts/version.sh)"
app="$repo/dist/ymd-menubar.app"
dmg="$repo/dist/ymd-menubar-${version}.dmg"

if [[ $build -eq 1 ]]; then
  bash macos/build.sh
fi
if [[ ! -d "$app" ]]; then
  echo "нет $app — сначала bash macos/build.sh" >&2
  exit 1
fi

if [[ -n "$identity" ]]; then
  echo "подпись приложения: $identity"
  codesign --force --deep --options runtime --timestamp \
    --sign "$identity" "$app"
  codesign --verify --deep --strict "$app"
fi

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
cat > "$stage/ЧИТАТЬ.txt" <<'TXT'
ymd-menubar — клиент строки меню для демона ymd.

1. Перетащите ymd-menubar.app в «Программы».
2. Запустите демон: ymd serve (или LaunchAgent из docs/14-macos.md).
3. Откройте приложение — иконка появится в строке меню.

Без подписи Developer ID macOS может предупредить при первом запуске:
правый клик по приложению → «Открыть».
TXT

rm -f "$dmg"
hdiutil create -quiet -volname "ymd ${version}" -srcfolder "$stage" \
  -fs HFS+ -format UDZO -ov "$dmg"

if [[ -n "$identity" ]]; then
  codesign --force --timestamp --sign "$identity" "$dmg"
fi

echo "готово: $dmg ($(du -h "$dmg" | cut -f1))"
echo "приложить к релизу: gh release upload v${version} \"$dmg\""
