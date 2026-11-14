#!/usr/bin/env bash
# Локальная установка/обновление плазмоида из репозитория.
#
#   bash scripts/dev-install.sh            # установить или обновить
#   bash scripts/dev-install.sh --remove   # удалить
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
id="io.github.pbolkhovitin.ymd"
type="Plasma/Applet"

if ! command -v kpackagetool6 >/dev/null 2>&1; then
  echo "kpackagetool6 не найден: установи plasma-workspace" >&2
  exit 1
fi

if [[ "${1:-}" == "--remove" ]]; then
  kpackagetool6 --type "$type" --remove "$id" || true
  echo "удалён: $id"
  exit 0
fi

if kpackagetool6 --type "$type" --list | grep -qx "$id"; then
  kpackagetool6 --type "$type" --upgrade "$repo/plasmoid"
  echo "обновлён: $id"
else
  kpackagetool6 --type "$type" --install "$repo/plasmoid"
  echo "установлен: $id"
fi

echo
echo "Добавь виджет в панель: ПКМ по панели → «Настроить панель» → «Добавить» →"
echo "«ymd». Если виджет уже добавлен, перезапусти plasmashell:"
echo "  systemctl --user restart plasma-plasmashell"
