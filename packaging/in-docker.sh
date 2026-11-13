#!/usr/bin/env bash
set -euo pipefail
arch="${1:?usage: in-docker.sh amd64|arm64}"
cd "$(dirname "$0")/.."

version=$(sed -n '/\[workspace.package\]/,/^\[/p' Cargo.toml \
  | sed -n 's/^version = "\(.*\)"/\1/p' | head -n1)
test -n "$version"

if [ "$arch" = "amd64" ]; then
  cargo test --locked
fi
cargo build --release --locked

stage="/tmp/ymd-stage"
rm -rf "$stage"
mkdir -p "$stage" dist
rm -f "dist/ymd_${version}_${arch}.deb" "dist/plasma-widget-ymd_${version}_all.deb"
install -Dm755 "$CARGO_TARGET_DIR/release/ymd" "$stage/ymd/usr/bin/ymd"
sed 's|%h/.local/bin/ymd|/usr/bin/ymd|' packaging/ymd.service \
  | install -Dm644 /dev/stdin "$stage/ymd/usr/lib/systemd/user/ymd.service"
install -Dm644 README.md "$stage/ymd/usr/share/doc/ymd/README.md"
install -Dm644 LICENSE "$stage/ymd/usr/share/doc/ymd/copyright"

plasmoid_dir="$stage/plasma-widget-ymd/usr/share/plasma/plasmoids/io.github.pbolkhovitin.ymd"
mkdir -p "$plasmoid_dir"
cp -a plasmoid/metadata.json plasmoid/contents "$plasmoid_dir/"
# CIFS-исходники отдают 770/660; в пакете нужны обычные 755/644.
find "$plasmoid_dir" -type d -exec chmod 0755 {} +
find "$plasmoid_dir" -type f -exec chmod 0644 {} +
install -Dm644 LICENSE "$stage/plasma-widget-ymd/usr/share/doc/plasma-widget-ymd/copyright"

# Resolve exact library versions with dpkg-shlibdeps.
shlib_root="packaging/.shlibdeps/$arch"
rm -rf "$shlib_root"
mkdir -p "$shlib_root/debian"
sed -e "s/@VERSION@/$version/g" -e "s/@ARCH@/$arch/g" \
  packaging/deb/ymd/control.in | grep -v '^Depends:' > "$shlib_root/debian/control"
printf 'ymd (%s) unstable; urgency=medium\n\n  * Local build.\n\n -- Pavel Bolkhovitin <pbolkhovitin@yandex.ru>  %s\n' \
  "$version" "$(date -R)" > "$shlib_root/debian/changelog"
binary="$stage/ymd/usr/bin/ymd"
shlibs=$(cd "$shlib_root" && dpkg-shlibdeps -O "$binary" \
  | sed -n 's/^shlibs:Depends=//p')
test -n "$shlibs"

mkdir -p "$stage/ymd/DEBIAN"
sed -e "s/@VERSION@/$version/g" -e "s/@ARCH@/$arch/g" -e "s|@SHLIBS@|$shlibs|g" \
  packaging/deb/ymd/control.in > "$stage/ymd/DEBIAN/control"

mkdir -p "$stage/plasma-widget-ymd/DEBIAN"
sed -e "s/@VERSION@/$version/g" \
  packaging/deb/plasma-widget-ymd/control.in > "$stage/plasma-widget-ymd/DEBIAN/control"

chmod 0755 "$stage/ymd" "$stage/ymd/DEBIAN" \
  "$stage/plasma-widget-ymd" "$stage/plasma-widget-ymd/DEBIAN"
dpkg-deb --build --root-owner-group "$stage/ymd" "/tmp/ymd_${version}_${arch}.deb"
dpkg-deb --build --root-owner-group "$stage/plasma-widget-ymd" "/tmp/plasma-widget-ymd_${version}_all.deb"
cp "/tmp/ymd_${version}_${arch}.deb" "/tmp/plasma-widget-ymd_${version}_all.deb" dist/
