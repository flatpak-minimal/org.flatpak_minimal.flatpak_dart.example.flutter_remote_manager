#!/bin/sh
set -e
export IHS_LOG_LEVEL="${IHS_LOG_LEVEL:-info}"
export LD_LIBRARY_PATH=/app/lib:/app/share/flatpak-app-store/bundle/lib
[ -d /app/lib/dri ] && export LIBGL_DRIVERS_PATH=/app/lib/dri
[ -f /app/lib/50_mesa.json ] && export __EGL_VENDOR_LIBRARY_FILENAMES=/app/lib/50_mesa.json
export XDG_DATA_HOME="$HOME/.local/share"
exec /app/bin/homescreen \
  -b /app/share/flatpak-app-store/bundle \
  --backend wayland-egl \
  --shell auto \
  --app-id org.flatpak_minimal.flatpak_dart.example.flutter_remote_manager \
  "$@"
