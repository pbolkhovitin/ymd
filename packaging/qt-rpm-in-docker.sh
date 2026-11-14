#!/usr/bin/env bash
# Сборка RPM приложения ymd-qt внутри Fedora-контейнера.
# Вызывается из packaging/build-rpm.sh, не напрямую.
set -euo pipefail
arch="${1:?usage: qt-rpm-in-docker.sh amd64|arm64}"
cd "$(dirname "$0")/.."

version=$(bash scripts/version.sh)
test -n "$version"

build_dir="/tmp/ymd-qt-build"
rm -rf "$build_dir"
cmake -S app -B "$build_dir" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr
cmake --build "$build_dir"
ctest --test-dir "$build_dir" --output-on-failure

stage="/tmp/ymd-qt-stage"
rm -rf "$stage"
DESTDIR="$stage" cmake --install "$build_dir"

top="/tmp/rpmbuild-qt-$arch"
rm -rf "$top"
mkdir -p "$top/BUILD" "$top/RPMS" "$top/SOURCES" "$top/SPECS" "$top/SRPMS"

install -Dm755 "$stage/usr/bin/ymd-qt" "$top/SOURCES/ymd-qt"
install -Dm644 "$stage/usr/share/applications/ymd-qt.desktop" "$top/SOURCES/ymd-qt.desktop"
install -Dm644 "$stage/usr/share/icons/hicolor/scalable/apps/ymd-qt.svg" "$top/SOURCES/ymd-qt.svg"
install -Dm644 README.md "$top/SOURCES/README.md"
install -Dm644 LICENSE "$top/SOURCES/LICENSE"

sed "s/@VERSION@/$version/g" packaging/rpm/ymd-qt.spec > "$top/SPECS/ymd-qt.spec"
rpmbuild -bb --define "_topdir $top" "$top/SPECS/ymd-qt.spec"

mkdir -p dist
find "$top/RPMS" -name '*.rpm' -exec cp -f {} dist/ \;

rpm=$(ls dist/ymd-qt-"$version"-*.rpm | head -n1)
echo "--- $rpm"
rpm -qlp "$rpm"
