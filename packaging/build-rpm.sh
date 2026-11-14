#!/usr/bin/env bash
# Сборка RPM в Fedora-контейнере: демон, плазмоид и (по умолчанию) ymd-qt.
#
#   bash packaging/build-rpm.sh                 # amd64
#   bash packaging/build-rpm.sh --arch arm64
#   bash packaging/build-rpm.sh --no-qt         # без ymd-qt (быстрее)
#
# Результат — dist/*.rpm. Версия берётся из Cargo.toml (scripts/version.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
. packaging/container-env.sh

arch=amd64
with_qt=1
while [ $# -gt 0 ]; do
  case "$1" in
    --arch) arch="${2:?}"; shift 2 ;;
    --no-qt) with_qt=0; shift ;;
    *) echo "usage: $0 [--arch amd64|arm64] [--no-qt]" >&2; exit 2 ;;
  esac
done

case "$arch" in
  amd64) platform=linux/amd64 ;;
  arm64) platform=linux/arm64 ;;
  *) echo "unsupported arch: $arch" >&2; exit 2 ;;
esac

cache_root="${YMD_CACHE_ROOT:-/var/tmp/opencode/ymd-cache}"
mkdir -p "$cache_root/cargo-$arch" "$cache_root/target-$arch" dist

"$ENGINE_BIN" build --platform "$platform" -f packaging/Dockerfile.rpm -t "ymd-rpm-builder:$arch" packaging
"$ENGINE_BIN" run --rm --platform "$platform" "${RUN_USER[@]}" -e HOME=/tmp \
  -e CARGO_HOME="/cache/cargo-$arch" \
  -e CARGO_TARGET_DIR="/cache/target-$arch" \
  -v "$cache_root:/cache" \
  -v "$PWD:/work" -w /work \
  "ymd-rpm-builder:$arch" bash packaging/rpm-in-docker.sh "$arch"

if [ "$with_qt" = "1" ]; then
  "$ENGINE_BIN" build --platform "$platform" -f packaging/Dockerfile.rpm-qt -t "ymd-rpm-qt-builder:$arch" packaging
  "$ENGINE_BIN" run --rm --platform "$platform" "${RUN_USER[@]}" -e HOME=/tmp \
    -v "$PWD:/work" -w /work \
    "ymd-rpm-qt-builder:$arch" bash packaging/qt-rpm-in-docker.sh "$arch"
fi

ls -lh dist/*.rpm
