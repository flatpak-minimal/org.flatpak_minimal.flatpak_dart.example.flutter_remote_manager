#!/usr/bin/env bash
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PKG_DIR"

if ! command -v flatpak-builder >/dev/null 2>&1; then
  echo "ERROR: flatpak-builder not found. Install it first: sudo apt install flatpak-builder" >&2
  exit 1
fi

FLATPAK_ARCH="${FLATPAK_ARCH:-$(flatpak --default-arch)}"
OUT_FILE="${OUT_FILE:-org.flatpak_minimal.flatpak_dart.example.flutter_remote_manager-${FLATPAK_ARCH}.flatpak}"

flatpak-builder --arch="$FLATPAK_ARCH" --repo=repo --force-clean build-dir org.flatpak_minimal.flatpak_dart.example.flutter_remote_manager.dev.yml
flatpak build-bundle --arch="$FLATPAK_ARCH" repo "$OUT_FILE" org.flatpak_minimal.flatpak_dart.example.flutter_remote_manager

echo
echo "Bundle written to $PKG_DIR/$OUT_FILE"
