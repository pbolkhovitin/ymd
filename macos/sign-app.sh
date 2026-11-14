#!/usr/bin/env bash
# Подпись вложенного кода изнутри наружу; без --deep при подписании.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:?нужен путь к .app}"
identity="${2:--}"

sign_binary() {
  if [[ "$identity" == "-" ]]; then
    codesign --force --sign - "$1"
  else
    codesign --force --sign "$identity" --options runtime --timestamp "$1"
  fi
}

while IFS= read -r -d '' binary; do
  if [[ "$identity" != "-" && "$binary" == "$app/Contents/Helpers/ymd" ]]; then
    codesign --force --sign "$identity" --options runtime --timestamp \
      --entitlements "$repo/macos/daemon.entitlements.plist" "$binary"
  else
    sign_binary "$binary"
  fi
done < <(find "$app/Contents/Frameworks" "$app/Contents/Helpers" \
  "$app/Contents/Resources/gstreamer-1.0" "$app/Contents/Resources/gio/modules" \
  -type f \( -name '*.dylib' -o -name '*.so' -o -perm -111 \) -print0)

sign_binary "$app"
codesign --verify --deep --strict "$app"
