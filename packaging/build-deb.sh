#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. packaging/container-env.sh

arch=arm64
while [ $# -gt 0 ]; do
  case "$1" in
    --arch) arch="${2:?}"; shift 2 ;;
    *) echo "usage: $0 [--arch amd64|arm64]" >&2; exit 2 ;;
  esac
done

case "$arch" in
  amd64) platform=linux/amd64 ;;
  arm64) platform=linux/arm64 ;;
  *) echo "unsupported arch: $arch" >&2; exit 2 ;;
esac

cache_root="${YMD_CACHE_ROOT:-/var/tmp/opencode/ymd-cache}"
mkdir -p "$cache_root/cargo-$arch" "$cache_root/target-$arch" dist
"$ENGINE_BIN" build --platform "$platform" -t "ymd-builder:$arch" packaging
"$ENGINE_BIN" run --rm --platform "$platform" "${RUN_USER[@]}" -e HOME=/tmp \
  -e CARGO_HOME="/cache/cargo-$arch" \
  -e CARGO_TARGET_DIR="/cache/target-$arch" \
  -v "$cache_root:/cache" \
  -v "$PWD:/work" -w /work \
  "ymd-builder:$arch" bash packaging/in-docker.sh "$arch"
