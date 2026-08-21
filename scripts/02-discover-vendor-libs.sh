#!/usr/bin/env bash
set -euo pipefail

: "${HOMESCREEN_BIN:?must be set - path to the built homescreen binary}"
HOMESCREEN="$HOMESCREEN_BIN"
RUNTIME_REF="${RUNTIME_REF:-org.freedesktop.Platform//25.08}"
ARCH_TRIPLET="$(uname -m)-linux-gnu"
GL_LIB_DIR="${GL_LIB_DIR:-/lib/$ARCH_TRIPLET}"
DRI_DIR="${DRI_DIR:-/usr/lib/$ARCH_TRIPLET/dri}"
PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$PKG_DIR/staging/vendor-libs.txt"

if [[ ! -x "$HOMESCREEN" ]]; then
  echo "ERROR: homescreen binary not found/executable at $HOMESCREEN" >&2
  exit 1
fi

RUNTIME_DIR="$(flatpak info --user --show-location "$RUNTIME_REF")"
echo "Runtime tree: $RUNTIME_DIR/files"

mkdir -p "$PKG_DIR/staging"
: > "$OUT"

is_runtime_provided() {
  local lib="$1"
  find "$RUNTIME_DIR/files/lib" "$RUNTIME_DIR/files/lib/$ARCH_TRIPLET" \
    -maxdepth 2 -name "${lib}*" 2>/dev/null | head -1
}

declare -A VISITED_FILES
declare -A VENDOR_SET

SEEDS=("$HOMESCREEN")
if [ "${VENDOR_DEV_GPU_STACK:-0}" = "1" ]; then
  SEEDS+=(
    "$GL_LIB_DIR/libEGL.so.1"
    "$GL_LIB_DIR/libEGL_mesa.so.0"
    "$GL_LIB_DIR/libGLESv2.so.2"
    "$GL_LIB_DIR/libGLdispatch.so.0"
    "$GL_LIB_DIR/libgbm.so.1"
    "$DRI_DIR/virtio_gpu_dri.so"
    "$DRI_DIR/kms_swrast_dri.so"
  )
fi

QUEUE=("${SEEDS[@]}")
while [[ ${#QUEUE[@]} -gt 0 ]]; do
  file="${QUEUE[0]}"
  QUEUE=("${QUEUE[@]:1}")

  realfile=$(readlink -f "$file" 2>/dev/null || true)
  [[ -z "$realfile" || ! -e "$realfile" || -n "${VISITED_FILES[$realfile]:-}" ]] && continue
  VISITED_FILES[$realfile]=1

  while read -r lib; do
    [[ -z "$lib" || "$lib" == "linux-vdso.so.1" ]] && continue
    [[ -n "${VENDOR_SET[$lib]:-}" ]] && continue

    found_in_runtime=$(is_runtime_provided "$lib")
    if [[ -n "$found_in_runtime" ]]; then
      echo "RUNTIME-PROVIDED: $lib -> $found_in_runtime"
    else
      echo "VENDOR-NEEDED:    $lib"
      VENDOR_SET[$lib]=1
      echo "$lib" >> "$OUT"
      libpath=$(ldd "$realfile" 2>/dev/null | awk -v l="$lib" '$1==l{print $3}')
      [[ -n "$libpath" ]] && QUEUE+=("$libpath")
    fi
  done < <(ldd "$realfile" 2>/dev/null | awk '{print $1}' | grep -E '^lib.*\.so' | sort -u)
done

sort -u "$OUT" -o "$OUT"

echo
echo "=== Libs requiring vendoring (cross-check versions manually!) ==="
cat "$OUT"
echo
echo "Wrote $(wc -l < "$OUT") entries to $OUT"
