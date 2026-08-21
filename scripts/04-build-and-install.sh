#!/usr/bin/env bash
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PKG_DIR"

if ! command -v flatpak-builder >/dev/null 2>&1; then
  echo "ERROR: flatpak-builder not found. Install it first: sudo apt install flatpak-builder" >&2
  exit 1
fi

MISSING=()
for v in APP_DIR IHS_DIR; do
  [[ -n "${!v:-}" ]] || MISSING+=("$v")
done
if (( ${#MISSING[@]} )); then
  echo "ERROR: set the following before running (see README):" >&2
  printf '  %s\n' "${MISSING[@]}" >&2
  exit 1
fi
export APP_DIR IHS_DIR

"$PKG_DIR/scripts/01-build-flutter-bundle.sh"
"$PKG_DIR/scripts/02-discover-vendor-libs.sh"
"$PKG_DIR/scripts/03-stage-vendor-libs.sh"

FLATPAK_ARCH="${FLATPAK_ARCH:-$(flatpak --default-arch)}"
flatpak-builder --arch="$FLATPAK_ARCH" --user --install --force-clean build-dir org.flatpak_minimal.flatpak_dart.example.flutter_remote_manager.dev.yml

echo
echo "Done. Launch with: flatpak run org.flatpak_minimal.flatpak_dart.example.flutter_remote_manager"
