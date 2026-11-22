#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
arch=amd64
# The repository lives on a CIFS mount without the executable bit, so cargo's
# target directory must live on a local filesystem.
cache_root="${YMD_CACHE_ROOT:-/var/tmp/opencode/ymd-cache}"
mkdir -p "$cache_root/cargo-$arch" "$cache_root/target-$arch"
# Rootless podman отдаёт контейнеру subuid, поэтому кэш должен быть
# доступен на запись не только владельцу.
chmod -R a+rwX "$cache_root"
# На Fedora с SELinux контейнер не читает каталог без метки container_file_t,
# а CI (Docker без SELinux) спокойно принимает суффикс :z.
mount_opts=""
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" = "Enforcing" ]; then
  mount_opts=":z"
fi
docker build --platform linux/amd64 -t "ymd-builder:$arch" packaging
docker run --rm --platform linux/amd64 \
  -u "$(id -u):$(id -g)" -e HOME=/tmp \
  -e CARGO_HOME="/cache/cargo-$arch" \
  -e CARGO_TARGET_DIR="/cache/target-$arch" \
  -v "$cache_root:/cache$mount_opts" \
  -v "$PWD:/work$mount_opts" -w /work \
  "ymd-builder:$arch" cargo test "$@"
