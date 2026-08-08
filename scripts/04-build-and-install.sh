#!/usr/bin/env bash
# Runs the full pipeline: assemble the Flutter bundle, discover vendor libs,
# stage them, then build and --user install the Flatpak.
#
# Prerequisite (one-time): sudo apt install flatpak-builder
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PKG_DIR"

if ! command -v flatpak-builder >/dev/null 2>&1; then
  echo "ERROR: flatpak-builder not found. Install it first: sudo apt install flatpak-builder" >&2
  exit 1
fi

"$PKG_DIR/scripts/01-build-flutter-bundle.sh"
"$PKG_DIR/scripts/02-discover-vendor-libs.sh"
"$PKG_DIR/scripts/03-stage-vendor-libs.sh"

FLATPAK_ARCH="${FLATPAK_ARCH:-$(flatpak --default-arch)}"
flatpak-builder --arch="$FLATPAK_ARCH" --user --install --force-clean build-dir org.agl.FlatpakAppStore.yml

echo
echo "Done. Launch with: flatpak run org.agl.FlatpakAppStore"
