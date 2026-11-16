#!/bin/sh
# Bump the Aurora package patch version before every rebuild.
#
# The version is stored in three places; keep them in sync:
#   - aurora/rpm/ru.pbolkhovitin.ymd.spec  (Version + changelog)
#   - aurora/src/main.cpp                  (setApplicationVersion)
#   - the RPM/staging name is derived from the spec by build_rpm.sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SPEC="$ROOT/rpm/ru.pbolkhovitin.ymd.spec"
MAIN="$ROOT/src/main.cpp"

CURRENT=$(awk '/^Version:[[:space:]]*/ { print $2; exit }' "$SPEC")
case "$CURRENT" in
    *.*.*) ;;
    *)
        echo "unexpected version in $SPEC: $CURRENT" >&2
        exit 1
        ;;
esac

MAJOR=${CURRENT%%.*}
REST=${CURRENT#*.}
MINOR=${REST%%.*}
PATCH=${REST#*.}
case "$MAJOR$MINOR$PATCH" in
    *[!0-9]*)
        echo "version is not numeric: $CURRENT" >&2
        exit 1
        ;;
esac

NEXT="$MAJOR.$MINOR.$((PATCH + 1))"
DATE=$(LC_ALL=C date '+%a %b %d %Y')

sed -i "s/^Version:.*/Version: $NEXT/" "$SPEC"
sed -i "s/setApplicationVersion(QStringLiteral(\"[^\"]*\"))/setApplicationVersion(QStringLiteral(\"$NEXT\"))/" "$MAIN"

TMP=$(mktemp)
awk -v entry="* $DATE Leonid Yurasov <leonidy-85@users.noreply.github.com> - $NEXT-1
- Automatic rebuild version bump." '
    { print }
    /^%changelog$/ { print entry }
' "$SPEC" > "$TMP"
mv "$TMP" "$SPEC"

printf '%s\n' "$NEXT"
