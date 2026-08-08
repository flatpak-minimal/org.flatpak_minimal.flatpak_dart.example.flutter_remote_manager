#!/usr/bin/env bash
# DEV-ONLY: builds an exportable ostree repo from the local dev manifest
# (org.agl.FlatpakAppStore.dev.yml, staged sources) and packages it into a
# single-file .flatpak bundle, for testing a bundle build locally without
# --user installing. Kept separate from 04-build-and-install.sh so a local
# "just install it for me" loop and this bundle-producing path don't fight
# over the same build-dir.
#
# Production/CI bundle production uses flatpak/flatpak-github-actions against
# org.agl.FlatpakAppStore.yml instead (see .github/workflows/ci.yml) — this
# script is not used there.
#
# Run scripts/01-03 first; this script only does the flatpak-builder/build-bundle stage.
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PKG_DIR"

if ! command -v flatpak-builder >/dev/null 2>&1; then
  echo "ERROR: flatpak-builder not found. Install it first: sudo apt install flatpak-builder" >&2
  exit 1
fi

FLATPAK_ARCH="${FLATPAK_ARCH:-$(flatpak --default-arch)}"
OUT_FILE="${OUT_FILE:-org.agl.FlatpakAppStore-${FLATPAK_ARCH}.flatpak}"

flatpak-builder --arch="$FLATPAK_ARCH" --repo=repo --force-clean build-dir org.agl.FlatpakAppStore.dev.yml
flatpak build-bundle --arch="$FLATPAK_ARCH" repo "$OUT_FILE" org.agl.FlatpakAppStore

echo
echo "Bundle written to $PKG_DIR/$OUT_FILE"
