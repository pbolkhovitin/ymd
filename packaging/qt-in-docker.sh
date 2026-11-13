#!/usr/bin/env bash
set -euo pipefail
arch="${1:?usage: qt-in-docker.sh amd64|arm64}"
cd "$(dirname "$0")/.."

build_dir="${YMD_QT_BUILD_DIR:-/tmp/ymd-qt-build}"
rm -rf "$build_dir"
cmake -S app -B "$build_dir" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr
cmake --build "$build_dir"
ctest --test-dir "$build_dir" --output-on-failure

version=$(sed -n 's/^project(ymd-qt VERSION \([0-9.]*\).*/\1/p' app/CMakeLists.txt)
test -n "$version"

stage="/tmp/ymd-qt-stage"
rm -rf "$stage"
mkdir -p "$stage" dist
rm -f "dist/ymd-qt_${version}_${arch}.deb"
DESTDIR="$stage" cmake --install "$build_dir"

install -Dm644 LICENSE "$stage/usr/share/doc/ymd-qt/copyright"

shlib_root="packaging/.shlibdeps/qt-$arch"
rm -rf "$shlib_root"
mkdir -p "$shlib_root/debian"
printf 'Source: ymd-qt\nMaintainer: Pavel Bolkhovitin <pbolkhovitin@yandex.ru>\nStandards-Version: 4.7.0\n\nPackage: ymd-qt\nArchitecture: %s\n' "$arch" > "$shlib_root/debian/control"
printf 'ymd-qt (%s) unstable; urgency=medium\n\n  * Local build.\n\n -- Pavel Bolkhovitin <pbolkhovitin@yandex.ru>  %s\n' \
  "$version" "$(date -R)" > "$shlib_root/debian/changelog"
binary="$stage/usr/bin/ymd-qt"
shlibs=$(cd "$shlib_root" && dpkg-shlibdeps -O "$binary" \
  | sed -n 's/^shlibs:Depends=//p')
test -n "$shlibs"

mkdir -p "$stage/DEBIAN"
sed -e "s/@VERSION@/$version/g" -e "s/@ARCH@/$arch/g" -e "s|@SHLIBS@|$shlibs|g" \
  packaging/deb/ymd-qt/control.in > "$stage/DEBIAN/control"

find "$stage/usr" -type d -exec chmod 0755 {} +
find "$stage/usr" -type f -exec chmod 0644 {} +
chmod 0755 "$stage/usr/bin/ymd-qt" "$stage/DEBIAN"
dpkg-deb --build --root-owner-group "$stage" "/tmp/ymd-qt_${version}_${arch}.deb"
cp "/tmp/ymd-qt_${version}_${arch}.deb" dist/
