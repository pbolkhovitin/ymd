#!/usr/bin/env bash
# Сборка RPM демона и плазмоида внутри Fedora-контейнера.
# Вызывается из packaging/build-rpm.sh, не напрямую.
set -euo pipefail
arch="${1:?usage: rpm-in-docker.sh amd64|arm64}"
cd "$(dirname "$0")/.."

version=$(bash scripts/version.sh)
test -n "$version"

if [ "$arch" = "amd64" ]; then
  cargo test --locked
fi
cargo build --release --locked

top="/tmp/rpmbuild-$arch"
rm -rf "$top"
mkdir -p "$top/BUILD" "$top/RPMS" "$top/SOURCES" "$top/SPECS" "$top/SRPMS"

install -Dm755 "$CARGO_TARGET_DIR/release/ymd" "$top/SOURCES/ymd"
sed 's|%h/.local/bin/ymd|/usr/bin/ymd|' packaging/ymd.service > "$top/SOURCES/ymd.service"
install -Dm644 README.md "$top/SOURCES/README.md"
install -Dm644 LICENSE "$top/SOURCES/LICENSE"
tar -czf "$top/SOURCES/plasma-widget-ymd.tar.gz" --exclude="plasmoid/tests" plasmoid

for spec in ymd plasma-widget-ymd; do
  sed "s/@VERSION@/$version/g" "packaging/rpm/$spec.spec" > "$top/SPECS/$spec.spec"
  rpmbuild -bb --define "_topdir $top" "$top/SPECS/$spec.spec"
done

mkdir -p dist
find "$top/RPMS" -name '*.rpm' -exec cp -f {} dist/ \;

rpm=$(ls dist/ymd-"$version"-*.rpm | head -n1)
echo "--- $rpm"
rpm -qp --requires "$rpm" | grep -v '^rpmlib' | head -20
rpm -qlp "$rpm"
