#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
arch=amd64
# The repository lives on a CIFS mount without the executable bit, so cargo's
# target directory must live on a local filesystem.
cache_root="${YMD_CACHE_ROOT:-/var/tmp/opencode/ymd-cache}"
mkdir -p "$cache_root/cargo-$arch" "$cache_root/target-$arch"
docker build --platform linux/amd64 -t "ymd-builder:$arch" packaging
docker run --rm --platform linux/amd64 \
  -u "$(id -u):$(id -g)" -e HOME=/tmp \
  -e CARGO_HOME="/cache/cargo-$arch" \
  -e CARGO_TARGET_DIR="/cache/target-$arch" \
  -v "$cache_root:/cache" \
  -v "$PWD:/work" -w /work \
  "ymd-builder:$arch" cargo test "$@"
