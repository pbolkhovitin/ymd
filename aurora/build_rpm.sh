#!/bin/sh
# Cross-build the Aurora Silica app and package it as an RPM.
#
# The binary is compiled outside rpmbuild (the Aurora SDK image has no
# aarch64/armv7hl native compiler), then a staged source tarball is handed to
# rpmbuild. This is the same pattern as OpenSoar's aurora/build_rpm.sh.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
NAME=ru.pbolkhovitin.ymd
# Every rebuild gets a new patch version (spec + main.cpp are updated).
VERSION=$(sh "$ROOT/bump_version.sh")
IMAGE=aurora-build-tools-leo:5.2.1.200
SDK_TOOLS=${AURORA_SDK_TOOLS:-$HOME/AuroraOS/sdk/5.2.1.200/tools}
OUT=$ROOT/output/aurora-rpm

rm -rf "$OUT" "$ROOT/.rpm-stage"
mkdir -p "$OUT/SOURCES" "$OUT/SPECS" "$OUT/RPMS" "$OUT/BUILD" "$OUT/BUILDROOT"
cp "$ROOT/rpm/$NAME.spec" "$OUT/SPECS/$NAME.spec"

for ARCH in aarch64 armv7hl; do
    case "$ARCH" in
        aarch64)
            TRIPLET=aarch64-meego-linux-gnu
            RPM_TARGET=aarch64-meego-linux
            QMAKE=qmake-aarch64
            ;;
        armv7hl)
            TRIPLET=armv7hl-meego-linux-gnueabi
            RPM_TARGET=armv7hl-meego-linux
            QMAKE=qmake-armv7hl
            ;;
        *)
            echo "unknown arch: $ARCH" >&2
            exit 1
            ;;
    esac

    BUILD=$ROOT/build-$ARCH
    STAGE=$ROOT/stage-$ARCH
    mkdir -p "$BUILD" "$STAGE"

    if [ ! -f "$BUILD/Makefile" ]; then
        (cd "$BUILD" && WORKSPACE_DIR="$ROOT" "$SDK_TOOLS/$QMAKE" "../$NAME.pro")
    fi

    docker run --rm -v "$ROOT:/workspace" -w "/workspace/build-$ARCH" \
        "$IMAGE" bash -lc 'make -j8'

    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    docker run --rm -v "$ROOT:/workspace" -w "/workspace/build-$ARCH" \
        "$IMAGE" bash -lc "make INSTALL_ROOT=/workspace/stage-$ARCH install"

    docker run --rm -v "$ROOT:/workspace" "$IMAGE" \
        "/opt/cross/bin/$TRIPLET-strip" "/workspace/stage-$ARCH/usr/bin/$NAME"
    cp "$ROOT/manifest.json" "$STAGE/manifest.json"

    PKGDIR=$NAME-$VERSION-$ARCH
    rm -rf "$ROOT/.rpm-stage/$PKGDIR"
    mkdir -p "$ROOT/.rpm-stage/$PKGDIR"
    cp -a "$STAGE/usr" "$ROOT/.rpm-stage/$PKGDIR/"
    cp "$STAGE/manifest.json" "$ROOT/.rpm-stage/$PKGDIR/"
    # Aurora runs apps as a regular user; never ship root:root 770 files.
    find "$ROOT/.rpm-stage/$PKGDIR" -type d -exec chmod 755 {} +
    find "$ROOT/.rpm-stage/$PKGDIR" -type f -exec chmod 644 {} +
    chmod 755 "$ROOT/.rpm-stage/$PKGDIR/usr/bin/$NAME"
    tar -C "$ROOT/.rpm-stage" --mode='u=rwX,go=rX' --owner=root --group=root \
        -czf "$OUT/SOURCES/$PKGDIR.tar.gz" "$PKGDIR"

    docker run --rm -v "$ROOT:/workspace" -v "$OUT:/work" "$IMAGE" \
        bash -lc "mkdir -p /tmp/rpmbuild && rpmbuild -bb --target $RPM_TARGET \
            --define '_topdir /tmp/rpmbuild' \
            --define '_sourcedir /work/SOURCES' \
            --define '_specdir /work/SPECS' \
            --define '_rpmdir /work/RPMS' \
            --define '_srcrpmdir /work/SRPMS' \
            /work/SPECS/$NAME.spec"
done

find "$OUT/RPMS" -name '*.rpm' -print
