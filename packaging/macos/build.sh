#!/usr/bin/env bash
# Сборка демона ymd под macOS (Apple Silicon).
#
#   bash packaging/macos/build.sh
#
# Нужны: macOS 13+, Xcode Command Line Tools, Homebrew, Rust (rustup).
# Скрипт ставит GStreamer из Homebrew и собирает release-бинарь.
# GUI (ymd-qt) на macOS пока не поддерживается — см. docs/14-macos.md.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "нужен macOS (сейчас $(uname -s))" >&2
  exit 1
fi

arch="$(uname -m)"
if [[ "$arch" != "arm64" ]]; then
  echo "внимание: $arch — инструкция рассчитана на Apple Silicon (arm64)" >&2
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "нет Homebrew: https://brew.sh" >&2
  exit 1
fi
if ! command -v cargo >/dev/null 2>&1; then
  echo "нет cargo: https://rustup.rs" >&2
  exit 1
fi

need=(pkgconf gstreamer gst-plugins-base gst-plugins-good)
missing=()
for pkg in "${need[@]}"; do
  brew list --versions "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
done
if ((${#missing[@]})); then
  echo "ставлю: ${missing[*]}"
  brew install "${missing[@]}"
fi

export PKG_CONFIG_PATH="$(brew --prefix)/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

echo "сборка ymd…"
cargo build --release -p ymd

binary="$repo/target/release/ymd"
"$binary" --version
echo "готово: $binary"
echo "дальше: $binary auth login && $binary serve"
