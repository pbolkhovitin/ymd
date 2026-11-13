#!/usr/bin/env bash
# Установка демона ymd как пользовательского systemd-сервиса.
#
#   bash scripts/install-user-service.sh            # собрать release, установить, включить
#   bash scripts/install-user-service.sh --no-build # использовать готовый бинарь
#   bash scripts/install-user-service.sh --uninstall
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_SRC="$REPO_DIR/packaging/ymd.service"
UNIT_DST="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/ymd.service"
BIN_DST="$HOME/.local/bin/ymd"

build=1
uninstall=0
for arg in "$@"; do
    case "$arg" in
        --no-build) build=0 ;;
        --uninstall) uninstall=1 ;;
        -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
        *) echo "неизвестный аргумент: $arg" >&2; exit 2 ;;
    esac
done

if [[ $uninstall -eq 1 ]]; then
    systemctl --user disable --now ymd.service 2>/dev/null || true
    rm -f "$UNIT_DST"
    systemctl --user daemon-reload
    echo "сервис удалён (бинарь $BIN_DST оставлен)"
    exit 0
fi

if [[ $build -eq 1 ]]; then
    echo "сборка release…"
    cargo build --release --manifest-path "$REPO_DIR/Cargo.toml" -p ymd
fi

install -Dm755 "$REPO_DIR/target/release/ymd" "$BIN_DST"
install -Dm644 "$UNIT_SRC" "$UNIT_DST"

systemctl --user daemon-reload
systemctl --user enable --now ymd.service

sleep 1
systemctl --user --no-pager --lines=0 status ymd.service || true
echo
echo "проверка:"
"$BIN_DST" status --json 2>/dev/null | head -c 200 || echo "демон ещё поднимается"
echo
echo "готово: $BIN_DST, юнит $UNIT_DST"
