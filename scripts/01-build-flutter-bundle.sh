#!/usr/bin/env bash
set -euo pipefail

: "${APP_DIR:?must be set - path to the flutter_remote_manager checkout}"
PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE_BUNDLE="$PKG_DIR/staging/bundle"

if [[ ! -d "$APP_DIR" ]]; then
  echo "ERROR: app not found at APP_DIR=$APP_DIR" >&2
  exit 1
fi

if ! command -v emb >/dev/null; then
  echo "ERROR: emb (emb_cli) not found on PATH — bootstrap it first (see README)" >&2
  exit 1
fi

rm -rf "$STAGE_BUNDLE"
mkdir -p "$STAGE_BUNDLE"

env -u CXXFLAGS -u LDFLAGS \
  CXXFLAGS="-stdlib=libc++" LDFLAGS="-lc++abi" \
  emb bundle --app-path "$APP_DIR" --mode release --build --output "$STAGE_BUNDLE"

if [[ ! -f "$STAGE_BUNDLE/lib/libapp.so" ]]; then
  echo "ERROR: libapp.so missing from $STAGE_BUNDLE/lib — emb bundle's AOT build likely failed, or its output layout differs from what's expected here; inspect $STAGE_BUNDLE" >&2
  exit 1
fi
if [[ ! -f "$STAGE_BUNDLE/data/icudtl.dat" || ! -d "$STAGE_BUNDLE/data/flutter_assets" ]]; then
  echo "ERROR: data/icudtl.dat or data/flutter_assets missing from $STAGE_BUNDLE/data" >&2
  exit 1
fi

if [[ ! -f "$STAGE_BUNDLE/lib/libflutter_engine.so" ]]; then
  echo "ERROR: libflutter_engine.so missing from $STAGE_BUNDLE/lib — emb bundle did not provision the release engine; check the 'emb engine --mode release' step output" >&2
  exit 1
fi

NATIVE_ASSETS="$STAGE_BUNDLE/data/flutter_assets/native_assets/linux"
if [[ ! -d "$NATIVE_ASSETS" ]]; then
  echo "ERROR: $NATIVE_ASSETS missing — the app's FFI native assets were not built; check NativeAssetsManifest.json and flatpak_dart's build hook" >&2
  exit 1
fi

echo "Bundle assembled at $STAGE_BUNDLE"
du -sh "$STAGE_BUNDLE"
