#!/usr/bin/env bash
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$PKG_DIR/staging/emb-paths.env" ]]; then
  # shellcheck disable=SC1091
  source "$PKG_DIR/staging/emb-paths.env"
fi

: "${HOMESCREEN_BIN:?must be set - path to the built homescreen binary (or run 01 first)}"
: "${IHS_SHARED_DIR:?must be set - path to the built ivi-homescreen shared dir (or run 01 first)}"
HOMESCREEN="$HOMESCREEN_BIN"

if [[ ! -d "$IHS_SHARED_DIR" ]]; then
  echo "ERROR: directory does not exist: $IHS_SHARED_DIR" >&2
  exit 1
fi
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
    IFS=':' read -r -a extra_dirs <<< "${EXTRA_LIB_PATH:-}${EXTRA_LIB_PATH:+:}${LD_LIBRARY_PATH:-}"
    for d in "${extra_dirs[@]}"; do
      [[ -n "$d" && -e "$d/$lib" ]] || continue
      src="$d/$lib"
      break
    done
  fi

  if [[ -z "$src" || ! -e "$src" ]]; then
    echo "WARN: could not resolve $lib — not on the ldconfig path, EXTRA_LIB_PATH or LD_LIBRARY_PATH" >&2
    continue
  fi
  realsrc=$(readlink -f "$src")
  cp -a "$realsrc" "$VENDOR_DIR/$(basename "$realsrc")"
  [[ "$(basename "$realsrc")" != "$lib" ]] && ln -sf "$(basename "$realsrc")" "$VENDOR_DIR/$lib"
done < "$VENDOR_LIST"

echo "Staged homescreen binary + $(find "$VENDOR_DIR" -type f | wc -l) lib files ($(find "$VENDOR_DIR" -type l | wc -l) symlinks) in $VENDOR_DIR"
