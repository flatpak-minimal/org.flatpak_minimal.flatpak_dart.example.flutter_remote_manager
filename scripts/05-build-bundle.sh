#!/usr/bin/env bash
# CI's bundle-producing path: builds an exportable ostree repo and packages it
# into a single-file .flatpak bundle. Kept separate from 04-build-and-install.sh
# (the --user --install dev-loop script) so CI and a developer's "just install
# it for me" flow don't fight over the same build-dir.
#
# Run 01-04's prerequisite steps (01-03) first; this script only does the
# flatpak-builder/build-bundle stage.
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PKG_DIR"

if ! command -v flatpak-builder >/dev/null 2>&1; then
  echo "ERROR: flatpak-builder not found. Install it first: sudo apt install flatpak-builder" >&2
  exit 1
fi

FLATPAK_ARCH="${FLATPAK_ARCH:-$(flatpak --default-arch)}"
OUT_FILE="${OUT_FILE:-org.agl.FlatpakAppStore-${FLATPAK_ARCH}.flatpak}"

flatpak-builder --arch="$FLATPAK_ARCH" --repo=repo --force-clean build-dir org.agl.FlatpakAppStore.yml
flatpak build-bundle --arch="$FLATPAK_ARCH" repo "$OUT_FILE" org.agl.FlatpakAppStore

echo
echo "Bundle written to $PKG_DIR/$OUT_FILE"
