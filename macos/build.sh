#!/usr/bin/env bash
# Сборка меню-бар клиента ymd для macOS (Apple Silicon и Intel).
#
#   bash macos/build.sh            # собрать dist/ymd-menubar.app
#   bash macos/build.sh --install  # ещё и скопировать в ~/Applications
#
# Нужны при сборке: Xcode CLT, Rust, Python 3 и pkg-config.
# На целевом Mac зависимости устанавливать не требуется.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "нужен macOS (сейчас $(uname -s))" >&2
  exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
  echo "самостоятельное приложение собирается для Apple Silicon (arm64)" >&2
  exit 1
fi
if ! command -v swift >/dev/null 2>&1; then
  echo "нет swift: xcode-select --install" >&2
  exit 1
fi

version="$(bash scripts/version.sh)"
app="${YMD_APP_OUTPUT:-$repo/dist/ymd-menubar.app}"
prefix="$(python3 macos/prepare-runtime.py)"

export MACOSX_DEPLOYMENT_TARGET=13.0
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"
export CARGO_TARGET_DIR="$repo/target/macos13"
export CARGO_ENCODED_RUSTFLAGS="-Clink-arg=-Wl,-rpath,$prefix/lib"
echo "сборка встроенного демона…"
cargo build --locked --release -p ymd

echo "сборка ymd-menubar ${version}…"
swift build --package-path macos -c release --product ymd-menubar --build-system native

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp macos/.build/release/ymd-menubar "$app/Contents/MacOS/ymd-menubar"
sed "s/@VERSION@/$version/g" macos/Info.plist > "$app/Contents/Info.plist"
python3 macos/bundle-runtime.py --app "$app" \
  --daemon "$CARGO_TARGET_DIR/release/ymd" --prefix "$prefix"
bash macos/sign-app.sh "$app"

echo "готово: $app"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/ymd-menubar.app"
  cp -R "$app" "$HOME/Applications/ymd-menubar.app"
  echo "установлено: $HOME/Applications/ymd-menubar.app"
  echo "запуск: open ~/Applications/ymd-menubar.app"
fi
