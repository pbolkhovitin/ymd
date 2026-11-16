#!/bin/sh
# Cross-build the Aurora package and produce an aarch64 RPM.
#
# The binary is built outside rpmbuild (the SDK's qmake is a host binary that
# cannot select the cross compiler through RPM macros). The spec therefore has
# an empty %build and installs the staged tree.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
NAME=ru.pbolkhovitin.ymd
VERSION=0.1.0
ARCH=aarch64
TRIPLET=aarch64-meego-linux-gnu
RPM_TARGET=aarch64-meego-linux
IMAGE=aurora-build-tools-leo:5.2.1.200
BUILD="$ROOT/build-aarch64"
STAGE="$ROOT/stage"
OUT="$ROOT/output/aurora-rpm"
SDK_TOOLS="$HOME/AuroraOS/sdk/5.2.1.200/tools"

mkdir -p "$BUILD"
if [ ! -f "$BUILD/Makefile" ]; then
    (cd "$BUILD" && WORKSPACE_DIR="$ROOT" "$SDK_TOOLS/qmake-aarch64" "../$NAME.pro")
fi

docker run --rm -v "$ROOT:/workspace" -w /workspace/build-aarch64 "$IMAGE" \
    bash -lc 'make -j8'

rm -rf "$STAGE"
mkdir -p "$STAGE"
docker run --rm -v "$ROOT:/workspace" -w /workspace/build-aarch64 "$IMAGE" \
    bash -lc 'make INSTALL_ROOT=/workspace/stage install'

docker run --rm -v "$ROOT:/workspace" "$IMAGE" \
    bash -lc "/opt/cross/bin/$TRIPLET-strip /workspace/stage/usr/bin/$NAME"
cp "$ROOT/manifest.json" "$STAGE/manifest.json"

rm -rf "$OUT" "$ROOT/.rpm-stage"
mkdir -p "$OUT/SOURCES" "$OUT/SPECS" "$OUT/RPMS" "$OUT/BUILD" "$OUT/BUILDROOT"
PKGDIR="$NAME-$VERSION-$ARCH"
mkdir -p "$ROOT/.rpm-stage/$PKGDIR"
cp -a "$STAGE/usr" "$ROOT/.rpm-stage/$PKGDIR/"
cp "$STAGE/manifest.json" "$ROOT/.rpm-stage/$PKGDIR/"
tar -C "$ROOT/.rpm-stage" -czf "$OUT/SOURCES/$PKGDIR.tar.gz" "$PKGDIR"
cp "$ROOT/rpm/$NAME.spec" "$OUT/SPECS/"

docker run --rm -v "$OUT:/work" "$IMAGE" \
    bash -lc "rpmbuild -bb --target $RPM_TARGET --define '_topdir /work' /work/SPECS/$NAME.spec"

echo "RPM:"
find "$OUT/RPMS" -type f -name '*.rpm' -print
