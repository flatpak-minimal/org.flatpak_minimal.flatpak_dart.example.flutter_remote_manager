#!/usr/bin/env bash
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PKG_DIR"

if [ "${VENDOR_DEV_GPU_STACK:-0}" = "1" ]; then
  echo "ERROR: refusing to publish artifacts staged with VENDOR_DEV_GPU_STACK=1 — production tarballs must not include the dev-only GPU workaround." >&2
  exit 1
fi

FLATPAK_ARCH="${FLATPAK_ARCH:-$(flatpak --default-arch)}"
OUT_DIR="${OUT_DIR:-$PKG_DIR/artifacts}"
mkdir -p "$OUT_DIR"

HOMESCREEN_TAR="$OUT_DIR/homescreen-${FLATPAK_ARCH}.tar.xz"
BUNDLE_TAR="$OUT_DIR/flutter-bundle-${FLATPAK_ARCH}.tar.xz"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/lib"
cp -a "$PKG_DIR/staging/vendor-bin/homescreen" "$WORK/bin/homescreen"
cp -a "$PKG_DIR/staging/vendor-lib/." "$WORK/lib/"
tar -C "$WORK" -cJf "$HOMESCREEN_TAR" bin lib

tar -C "$PKG_DIR/staging/bundle" -cJf "$BUNDLE_TAR" .

sha256sum "$HOMESCREEN_TAR" "$BUNDLE_TAR" | tee "$OUT_DIR/SHA256SUMS-${FLATPAK_ARCH}.txt"

echo
echo "Artifacts written to $OUT_DIR/"
echo "Update org.flatpak_minimal.flatpak_dart.example.flutter_remote_manager.yml's ${FLATPAK_ARCH} archive sources with the sha256 values above."
