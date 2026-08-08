#!/usr/bin/env bash
# Packages the outputs of scripts/01-build-flutter-bundle.sh and
# scripts/02/03-*-vendor-libs.sh into the two per-arch tarballs the
# production manifest (org.agl.FlatpakAppStore.yml) fetches as flatpak-builder
# archive sources:
#   homescreen-<arch>.tar.xz      — bin/homescreen + lib/* (full runtime dep closure)
#   flutter-bundle-<arch>.tar.xz  — data/flutter_assets, data/icudtl.dat, lib/libapp.so, lib/libflutter_engine.so
#
# Run 01-03 first (with VENDOR_DEV_GPU_STACK unset — production tarballs must
# never include the dev-only GPU vendoring). This script only packages;
# .github/workflows/build-artifacts.yml handles uploading + computing the
# sha256 values that need to land in org.agl.FlatpakAppStore.yml.
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

# homescreen-<arch>.tar.xz: staging/vendor-bin/homescreen -> bin/homescreen,
# staging/vendor-lib/* -> lib/*
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/lib"
cp -a "$PKG_DIR/staging/vendor-bin/homescreen" "$WORK/bin/homescreen"
cp -a "$PKG_DIR/staging/vendor-lib/." "$WORK/lib/"
tar -C "$WORK" -cJf "$HOMESCREEN_TAR" bin lib

# flutter-bundle-<arch>.tar.xz: staging/bundle/{data,lib} contents, unwrapped
tar -C "$PKG_DIR/staging/bundle" -cJf "$BUNDLE_TAR" .

sha256sum "$HOMESCREEN_TAR" "$BUNDLE_TAR" | tee "$OUT_DIR/SHA256SUMS-${FLATPAK_ARCH}.txt"

echo
echo "Artifacts written to $OUT_DIR/"
echo "Update org.agl.FlatpakAppStore.yml's ${FLATPAK_ARCH} archive sources with the sha256 values above."
