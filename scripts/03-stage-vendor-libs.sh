#!/usr/bin/env bash
# Stages the homescreen binary and every shared library it needs (beyond what
# org.freedesktop.Platform//25.08 provides) into staging/vendor-bin and
# staging/vendor-lib, ready to be copied into /app by the flatpak-builder
# manifest. Run 02-discover-vendor-libs.sh first to produce vendor-libs.txt.
set -euo pipefail

HOMESCREEN="${HOMESCREEN_BIN:-/home/wafdy/workspace-automation/app/ivi-homescreen/build/shell/homescreen}"
IHS_SHARED_DIR="${IHS_SHARED_DIR:-/home/wafdy/workspace-automation/app/ivi-homescreen/build/shared}"
AGL_LIB_DIR="${AGL_LIB_DIR:-/home/wafdy/workspace-automation/AGL/lib/aarch64-linux-gnu}"
TOOLCHAIN_LIB_DIR="${TOOLCHAIN_LIB_DIR:-/home/wafdy/workspace-automation/.tmp/toolchain-llvm-18.1.8/lib/aarch64-unknown-linux-gnu}"

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$PKG_DIR/staging/vendor-lib"
BIN_DIR="$PKG_DIR/staging/vendor-bin"
VENDOR_LIST="$PKG_DIR/staging/vendor-libs.txt"

if [[ ! -f "$VENDOR_LIST" ]]; then
  echo "ERROR: $VENDOR_LIST not found — run 02-discover-vendor-libs.sh first" >&2
  exit 1
fi

MESA_JSON_DIR="$PKG_DIR/staging/mesa-json"
rm -rf "$VENDOR_DIR" "$BIN_DIR" "$MESA_JSON_DIR"
mkdir -p "$VENDOR_DIR" "$BIN_DIR" "$MESA_JSON_DIR"

# 1. homescreen binary itself
cp -a "$HOMESCREEN" "$BIN_DIR/"

# 2. homescreen's own shared lib
cp -a "$IHS_SHARED_DIR"/libihs_shared.so* "$VENDOR_DIR/"

# 3. AGL-prefix wayland libs (tested combo — vendor rather than trust the runtime's)
for f in libwayland-client.so.0.23.1 libwayland-egl.so.1.23.1 libwayland-cursor.so.0.23.1; do
  cp -a "$AGL_LIB_DIR/$f" "$VENDOR_DIR/"
done
(cd "$VENDOR_DIR" && \
  ln -sf libwayland-client.so.0.23.1 libwayland-client.so.0 && \
  ln -sf libwayland-egl.so.1.23.1    libwayland-egl.so.1 && \
  ln -sf libwayland-cursor.so.0.23.1 libwayland-cursor.so.0)

# 4. LLVM 18.1.8 toolchain runtime libs (libc++, libc++abi, libunwind)
cp -a "$TOOLCHAIN_LIB_DIR"/libc++.so* "$TOOLCHAIN_LIB_DIR"/libc++abi.so* "$TOOLCHAIN_LIB_DIR"/libunwind.so* "$VENDOR_DIR/"

# 5. DEV-ONLY: host Mesa GL stack + DRI drivers, vendored explicitly.
#    org.freedesktop.Platform.GL.default (auto-attached by --device=dri) ships
#    a much newer Mesa than this dev VM's tested 23.2.1. On this VM's
#    virtio-gpu/virgl backend, that version skew breaks EGL config/dmabuf
#    negotiation (confirmed: native run succeeds via the EGL fallback path,
#    sandboxed run does not, even though both advertise the same Wayland
#    protocols). Real IVI/AGL target hardware has one native Mesa/DRM stack,
#    not a version-skewed virtualized GPU passthrough pair, so it should not
#    need this — gated behind VENDOR_DEV_GPU_STACK=1, off by default (i.e. in
#    CI/production builds).
if [ "${VENDOR_DEV_GPU_STACK:-0}" = "1" ]; then
  ARCH_TRIPLET="$(uname -m)-linux-gnu"
  GL_LIB_DIR="${GL_LIB_DIR:-/lib/$ARCH_TRIPLET}"
  DRI_DIR="${DRI_DIR:-/usr/lib/$ARCH_TRIPLET/dri}"
  for f in libEGL.so.1 libGLESv2.so.2 libGLdispatch.so.0 libgbm.so.1; do
    realsrc=$(readlink -f "$GL_LIB_DIR/$f")
    cp -a "$realsrc" "$VENDOR_DIR/$(basename "$realsrc")"
    # Skip the symlink when the real file's name already equals the soname
    # (e.g. no separate "x.y.z" suffix) — `ln -sf` would otherwise clobber the
    # just-copied real file with a symlink pointing at itself.
    [[ "$(basename "$realsrc")" != "$f" ]] && ln -sf "$(basename "$realsrc")" "$VENDOR_DIR/$f"
  done
  mkdir -p "$VENDOR_DIR/dri"
  cp -a "$DRI_DIR/virtio_gpu_dri.so" "$VENDOR_DIR/dri/"
  cp -a "$DRI_DIR/kms_swrast_dri.so" "$VENDOR_DIR/dri/"
  cp -a "$DRI_DIR/swrast_dri.so" "$VENDOR_DIR/dri/"

  # libEGL.so.1 above is libglvnd's vendor-neutral dispatcher, not the real
  # driver — it resolves the actual backend (libEGL_mesa.so.0) via a JSON
  # vendor file (/usr/share/glvnd/egl_vendor.d/50_mesa.json on the host).
  # Without vendoring that backend too, glvnd falls through to whatever
  # libEGL_mesa.so.0 it finds on the library search path — i.e. the GL
  # extension's mismatched Mesa 26.1.5 — silently defeating the libEGL.so.1
  # vendoring above. Vendor the real backend explicitly; stage a matching
  # 50_mesa.json for the manifest to install and the wrapper script to
  # point glvnd at.
  realsrc=$(readlink -f "$GL_LIB_DIR/libEGL_mesa.so.0")
  cp -a "$realsrc" "$VENDOR_DIR/$(basename "$realsrc")"
  [[ "$(basename "$realsrc")" != "libEGL_mesa.so.0" ]] && ln -sf "$(basename "$realsrc")" "$VENDOR_DIR/libEGL_mesa.so.0"

  cp -a "$PKG_DIR/50_mesa.json" "$MESA_JSON_DIR/50_mesa.json"
fi

# 6. Everything 02-discover-vendor-libs.sh flagged as VENDOR-NEEDED — this
#    includes homescreen's own deps AND the transitive deps of the GL stack
#    staged above (libEGL_mesa.so.0 and the DRI drivers pull in libglapi,
#    libLLVM (shader compiler), libxcb/libdrm/libX11-xcb, etc. that homescreen
#    itself never links against directly, so ldd on homescreen alone can't
#    see them — 02's closure walk does). Resolve each via ldconfig, since the
#    introducing binary varies.
while read -r lib; do
  [[ -z "$lib" ]] && continue
  [[ -e "$VENDOR_DIR/$lib" ]] && continue
  set +o pipefail
  src=$(ldconfig -p | awk -v l="$lib" '$1==l{print $NF; exit}')
  set -o pipefail
  if [[ -z "$src" || ! -e "$src" ]]; then
    echo "WARN: could not resolve $lib via ldconfig — check manually" >&2
    continue
  fi
  realsrc=$(readlink -f "$src")
  cp -a "$realsrc" "$VENDOR_DIR/$(basename "$realsrc")"
  [[ "$(basename "$realsrc")" != "$lib" ]] && ln -sf "$(basename "$realsrc")" "$VENDOR_DIR/$lib"
done < "$VENDOR_LIST"

echo "Staged homescreen binary + $(find "$VENDOR_DIR" -type f | wc -l) lib files ($(find "$VENDOR_DIR" -type l | wc -l) symlinks) in $VENDOR_DIR"