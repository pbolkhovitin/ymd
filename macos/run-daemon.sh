#!/usr/bin/env bash
# Запуск демона с аудиоплагинами, без конфликтующих GTK/Python-плагинов Homebrew.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
prefix="$(brew --prefix)"
plugins="$repo/dist/gstreamer-audio"
mkdir -p "$plugins"

# Отдельный каталог и реестр не затрагивают другие приложения GStreamer.
for plugin in coreelements playback typefindfunctions audioconvert audioresample \
  autodetect osxaudio volume gio soup libav audioparsers isomp4 id3demux apetag \
  flac mpg123 ogg vorbis opus wavparse wavenc aiff alaw mulaw audiotestsrc; do
  source="$prefix/lib/gstreamer-1.0/libgst${plugin}.dylib"
  if [[ ! -f "$source" ]]; then
    echo "Не найден аудиоплагин: $source" >&2
    exit 1
  fi
  ln -sfn "$source" "$plugins/libgst${plugin}.dylib"
done

export GST_PLUGIN_SYSTEM_PATH_1_0="$plugins"
export GST_PLUGIN_PATH_1_0=""
export GST_REGISTRY="$repo/dist/gstreamer-audio-registry.bin"
export GST_REGISTRY_1_0="$GST_REGISTRY"

if [[ $# -eq 0 ]]; then
  set -- serve
fi
exec "$repo/target/release/ymd" "$@"
