#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

arch=amd64
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

cache_root="${YMD_QT_CACHE_ROOT:-/var/tmp/opencode/ymd-qt-cache}"
mkdir -p "$cache_root/build-$arch" dist
docker build --platform "$platform" -f packaging/Dockerfile.qt \
  -t "ymd-qt-builder:$arch" packaging
docker run --rm --platform "$platform" \
  -u "$(id -u):$(id -g)" -e HOME=/tmp \
  -e YMD_QT_BUILD_DIR="/cache/build-$arch" \
  -v "$cache_root:/cache" \
  -v "$PWD:/work" -w /work \
  "ymd-qt-builder:$arch" bash packaging/qt-in-docker.sh "$arch"
