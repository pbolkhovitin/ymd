#!/usr/bin/env bash
# Проверка окружения KDE-версии. Запуск: bash scripts/check-env.sh
set -uo pipefail

pass=0
warn=0
ok()   { printf '  [ok]   %s\n' "$1"; pass=$((pass + 1)); }
no()   { printf '  [warn] %s\n' "$1"; warn=$((warn + 1)); }
head1(){ printf '\n== %s ==\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

head1 "KDE Plasma"
if [[ "${XDG_CURRENT_DESKTOP:-}" == *KDE* ]]; then
  ok "XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP}"
else
  no "сессия не KDE (XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-не задан})"
fi
if have plasmashell; then ok "plasmashell есть"; else no "plasmashell не найден (apt install plasma-workspace)"; fi
if have kpackagetool6; then ok "kpackagetool6 есть"; else no "kpackagetool6 не найден (apt install plasma-workspace)"; fi
if have qdbus6; then ok "qdbus6 есть"; else no "qdbus6 не найден (apt install qdbus-qt6)"; fi

head1 "QML-модули"
for mod in org.kde.kirigami org.kde.plasma.components org.kde.plasma.plasma5support; do
  if [[ -d "/usr/lib/x86_64-linux-gnu/qt6/qml/${mod//.//}" || -d "/usr/lib/aarch64-linux-gnu/qt6/qml/${mod//.//}" ]]; then
    ok "$mod"
  else
    no "$mod не найден (qml6-module-org-kde-…)"
  fi
done

head1 "Демон ymd"
if have ymd; then
  ok "ymd: $(command -v ymd)"
else
  no "ymd не в PATH (собери или поставь .deb)"
fi
key="${XDG_RUNTIME_DIR:-/tmp}/ymd/session.key"
if [[ -r "$key" ]]; then
  ok "session.key: $key"
else
  no "session.key нет — запусти ymd serve"
fi
if curl -fsS --max-time 2 http://127.0.0.1:8765/v1/health >/dev/null 2>&1; then
  ok "демон отвечает на /v1/health"
else
  no "демон не отвечает на :8765"
fi

head1 "MPRIS"
if have playerctl; then
  ok "playerctl: $(playerctl --version 2>&1 | head -n1)"
  if playerctl --player=ymd status >/dev/null 2>&1; then
    ok "MPRIS ymd виден"
  else
    no "MPRIS ymd не виден (демон запущен?)"
  fi
else
  no "playerctl не установлен (apt install playerctl)"
fi
if have busctl; then ok "busctl есть"; else no "busctl не найден (systemd)"; fi

head1 "Звук"
if have gst-launch-1.0; then
  ok "gst-launch-1.0 есть"
else
  no "gst-launch-1.0 нет (apt install gstreamer1.0-tools)"
fi
if have pactl; then
  ok "pactl есть"
  if pactl info 2>/dev/null | grep -qi pipewire; then
    ok "PipeWire как звуковой сервер"
  else
    no "PipeWire не обнаружен через pactl"
  fi
else
  no "pactl нет (apt install pulseaudio-utils)"
fi
if have mpv; then ok "mpv есть (резервный backend)"; else no "mpv нет (опционально)"; fi

head1 "Плазмоид"
id="io.github.pbolkhovitin.ymd"
if have kpackagetool6 && kpackagetool6 --type Plasma/Applet --list 2>/dev/null | grep -qx "$id"; then
  ok "плазмоид установлен: $id"
else
  no "плазмоид не установлен — bash scripts/dev-install.sh"
fi

printf '\nИтого: ok=%d warn=%d\n' "$pass" "$warn"
printf 'warn — не всегда ошибка; см. docs/09-p0-spikes.md\n'
