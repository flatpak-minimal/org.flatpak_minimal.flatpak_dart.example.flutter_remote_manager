#!/usr/bin/env bash
set -euo pipefail

: "${HOMESCREEN_BIN:?must be set - path to the built homescreen binary}"
: "${IHS_SHARED_DIR:?must be set - path to the built ivi-homescreen shared dir}"
: "${AGL_LIB_DIR:?must be set - path to the AGL wayland lib dir}"
: "${TOOLCHAIN_LIB_DIR:?must be set - path to the LLVM toolchain lib dir containing libc++abi.so*}"
HOMESCREEN="$HOMESCREEN_BIN"

for d in "$IHS_SHARED_DIR" "$AGL_LIB_DIR" "$TOOLCHAIN_LIB_DIR"; do
  if [[ ! -d "$d" ]]; then
    echo "ERROR: directory does not exist: $d" >&2
    exit 1
  fi
done

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

cp -a "$HOMESCREEN" "$BIN_DIR/"

cp -a "$IHS_SHARED_DIR"/libihs_shared.so* "$VENDOR_DIR/"

for soname in libwayland-client.so.0 libwayland-egl.so.1 libwayland-cursor.so.0; do
  if [[ ! -e "$AGL_LIB_DIR/$soname" ]]; then
    echo "ERROR: $soname not found in AGL_LIB_DIR=$AGL_LIB_DIR" >&2
    exit 1
  fi
  realsrc=$(readlink -f "$AGL_LIB_DIR/$soname")
  cp -a "$realsrc" "$VENDOR_DIR/$(basename "$realsrc")"
  if [[ "$(basename "$realsrc")" != "$soname" ]]; then
    ln -sf "$(basename "$realsrc")" "$VENDOR_DIR/$soname"
  fi
done

cp -a "$TOOLCHAIN_LIB_DIR"/libc++.so* "$TOOLCHAIN_LIB_DIR"/libc++abi.so* "$TOOLCHAIN_LIB_DIR"/libunwind.so* "$VENDOR_DIR/"

NATIVE_ASSETS_DIR="$PKG_DIR/staging/bundle/data/flutter_assets/native_assets/linux"
if [[ ! -d "$NATIVE_ASSETS_DIR" ]]; then
  echo "ERROR: $NATIVE_ASSETS_DIR not found — run 01-build-flutter-bundle.sh first" >&2
  exit 1
fi
for f in libflatpak_nc.so libappstream.so libsqlite3.so; do
  if [[ ! -f "$NATIVE_ASSETS_DIR/$f" ]]; then
    echo "ERROR: $f missing from $NATIVE_ASSETS_DIR — the app's FFI layer will fail at flatpak_bridge_init" >&2
    exit 1
  fi
  cp -a "$NATIVE_ASSETS_DIR/$f" "$VENDOR_DIR/"
done

if [ "${VENDOR_DEV_GPU_STACK:-0}" = "1" ]; then
  ARCH_TRIPLET="$(uname -m)-linux-gnu"
  GL_LIB_DIR="${GL_LIB_DIR:-/lib/$ARCH_TRIPLET}"
  DRI_DIR="${DRI_DIR:-/usr/lib/$ARCH_TRIPLET/dri}"
  for f in libEGL.so.1 libGLESv2.so.2 libGLdispatch.so.0 libgbm.so.1; do
    realsrc=$(readlink -f "$GL_LIB_DIR/$f")
    cp -a "$realsrc" "$VENDOR_DIR/$(basename "$realsrc")"
    [[ "$(basename "$realsrc")" != "$f" ]] && ln -sf "$(basename "$realsrc")" "$VENDOR_DIR/$f"
  done
  mkdir -p "$VENDOR_DIR/dri"
  cp -a "$DRI_DIR/virtio_gpu_dri.so" "$VENDOR_DIR/dri/"
  cp -a "$DRI_DIR/kms_swrast_dri.so" "$VENDOR_DIR/dri/"
  cp -a "$DRI_DIR/swrast_dri.so" "$VENDOR_DIR/dri/"

  realsrc=$(readlink -f "$GL_LIB_DIR/libEGL_mesa.so.0")
  cp -a "$realsrc" "$VENDOR_DIR/$(basename "$realsrc")"
  [[ "$(basename "$realsrc")" != "libEGL_mesa.so.0" ]] && ln -sf "$(basename "$realsrc")" "$VENDOR_DIR/libEGL_mesa.so.0"

  cp -a "$PKG_DIR/50_mesa.json" "$MESA_JSON_DIR/50_mesa.json"
fi

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
