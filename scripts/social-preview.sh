#!/usr/bin/env bash
# Social preview 1280x640 для GitHub (docs/images/social-preview.png).
set -euo pipefail
cd "$(dirname "$0")/.."
src="docs/images/noctalia-panel.png"
out="docs/images/social-preview.png"
ver="$(bash scripts/version.sh)"
tmp="/tmp/opencode/social"
mkdir -p "$tmp"

# 1. Скруглённая панель нужной высоты (кроп — только сама панель, без полосы бара).
h=430
magick "$src" -crop 486x405+4+4 +repage -resize "x$h" "$tmp/panel-flat.png"
w=$(magick identify -format '%w' "$tmp/panel-flat.png")
magick "$tmp/panel-flat.png" \
  \( +clone -alpha extract -fill black -colorize 100 \
     -fill white -draw "roundrectangle 0,0,$((w-1)),$((h-1)),22,22" \) \
  -alpha off -compose CopyOpacity -composite "$tmp/panel.png"

# 2. Фон: тёмный градиент + фиолетовое свечение справа.
magick -size 1280x640 gradient:'#121823-#0a0e14' \
  \( -size 1280x640 xc:black -fill '#7c6cf0' -draw 'circle 1080,520 1080,760' -blur 0x180 \) \
  -compose screen -composite \
  \( -size 1280x640 xc:black -fill '#2a3a55' -draw 'circle 250,80 250,320' -blur 0x200 \) \
  -compose screen -composite \
  "$tmp/bg.png"

# 3. Панель на сцене.
magick "$tmp/bg.png" \
  "$tmp/panel.png" -geometry +690+105 -compose over -composite \
  "$tmp/stage.png"

# 4. Текст (Pango — корректные веса и кириллица Inter).
magick "$tmp/stage.png" \
  -background none -fill '#f2f5fa' -font "Inter" -pointsize 168 \
  -annotate +76+268 'ymd' \
  -fill '#a78bfa' -draw 'roundrectangle 82,330 202,338,4,4' \
  -fill '#d7deea' -font "Inter" -pointsize 30 \
  -annotate +80+368 'Яндекс Музыка для Linux и macOS' \
  -fill '#8e9ab0' -pointsize 26 \
  -annotate +80+420 'KDE Plasma 6 · niri · Noctalia' \
  -annotate +80+456 'macOS Apple Silicon · меню-бар' \
  -annotate +80+492 'Rust-демон · GStreamer · MPRIS' \
  -fill '#6f7b90' -pointsize 22 \
  -annotate +80+570 "github.com/pbolkhovitin/ymd · v${ver}" \
  -depth 8 -strip "$out"

identify "$out"
