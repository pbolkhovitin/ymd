# Общие флаги запуска контейнера для packaging/*.sh (подключать через source).
#
# Rootless podman отображает владельца файлов хоста как root внутри
# контейнера, поэтому `-u $(id -u)` даёт «Permission denied» на файлы с
# режимом 0600. В podman нужен `--userns=keep-id`; в docker — обычный `-u`.

ENGINE_BIN="${YMD_ENGINE:-docker}"
if "$ENGINE_BIN" --version 2>/dev/null | grep -qi podman; then
  # keep-id — чтобы uid совпадал с хостом; label=disable — иначе SELinux
  # не пускает контейнер к файлам рабочего каталога.
  RUN_USER=(--userns=keep-id --security-opt label=disable)
else
  RUN_USER=(-u "$(id -u):$(id -g)")
fi
