#!/bin/sh
# Installed as /app/bin/flatpak-app-store — the Flatpak manifest's `command`.
# Thin wrapper that launches homescreen against the bundled Flutter app.
set -e
export IHS_LOG_LEVEL="${IHS_LOG_LEVEL:-info}"
# /etc/ld.so.conf.d is empty in this sandbox (the `simple` buildsystem never
# registers /app/lib the way cmake/autotools modules do via ldconfig), so
# only libraries reachable via a caller's baked-in RPATH resolve without this
# — dlopen'd libraries with no RPATH of their own (e.g. the DRI driver's own
# dependency on libLLVM) silently fail to load otherwise.
export LD_LIBRARY_PATH=/app/lib
# Dev-only GPU workaround (see scripts/03-stage-vendor-libs.sh's
# VENDOR_DEV_GPU_STACK gate): on machines where this was staged, force
# Mesa's DRI loader and libglvnd's EGL dispatcher to use the vendored driver
# matching the *build host's* tested Mesa, instead of
# org.freedesktop.Platform.GL.default's version — needed on this dev VM's
# virtio-gpu/virgl backend, where a Mesa version skew breaks EGL config/dmabuf
# negotiation. On production builds (profile off), /app/lib/dri and
# /app/lib/50_mesa.json simply don't exist, these are no-ops, and the app
# falls through to the runtime's GL extension like any normal Flatpak app.
[ -d /app/lib/dri ] && export LIBGL_DRIVERS_PATH=/app/lib/dri
[ -f /app/lib/50_mesa.json ] && export __EGL_VENDOR_LIBRARY_FILENAMES=/app/lib/50_mesa.json
# Flatpak isolates $XDG_DATA_HOME to a private per-app directory
# (~/.var/app/<id>/data) inside the sandbox. libflatpak's
# flatpak_installation_new_user() resolves the user installation via
# $XDG_DATA_HOME/flatpak, so without this override it reads that empty
# private directory instead of the real ~/.local/share/flatpak this app was
# granted access to via --filesystem — remotes/apps always come back empty
# or "not found" even though the bind mount itself is correct.
export XDG_DATA_HOME="$HOME/.local/share"
exec /app/bin/homescreen \
  -b /app/share/flatpak-app-store/bundle \
  --backend wayland-egl \
  --shell auto \
  --app-id org.agl.FlatpakAppStore \
  "$@"
