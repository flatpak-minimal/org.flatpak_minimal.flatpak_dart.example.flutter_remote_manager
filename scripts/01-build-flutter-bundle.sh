#!/usr/bin/env bash
set -euo pipefail

: "${APP_DIR:?must be set - path to the flutter_remote_manager checkout}"
: "${IHS_DIR:?must be set - path to the ivi-homescreen checkout}"
EMB_TARGET="${EMB_TARGET:-local}"
EMB_BACKEND="${EMB_BACKEND:-wayland-egl}"
EMB_MANIFEST="${EMB_MANIFEST:-all-backends.emb.yaml}"

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE_BUNDLE="$PKG_DIR/staging/bundle"
PATHS_FILE="$PKG_DIR/staging/emb-paths.env"

for d in "$APP_DIR" "$IHS_DIR"; do
  if [[ ! -d "$d" ]]; then
    echo "ERROR: directory does not exist: $d" >&2
    exit 1
  fi
done

if ! command -v emb >/dev/null; then
  echo "ERROR: emb (emb_cli) not found on PATH - bootstrap it first (see README)" >&2
  exit 1
fi

if [[ ! -f "$IHS_DIR/$EMB_MANIFEST" ]]; then
  echo "ERROR: $EMB_MANIFEST not found in $IHS_DIR - copy it from emb_cli/examples/cross/" >&2
  exit 1
fi

if [[ -n "${FLUTTER_WORKSPACE:-}" && "$FLUTTER_WORKSPACE" != "$PKG_DIR/staging/emb-workspace" ]]; then
  echo "NOTE: ignoring inherited FLUTTER_WORKSPACE=$FLUTTER_WORKSPACE" >&2
  echo "      emb reuses any engine artifacts it finds there, which silently" >&2
  echo "      mismatches the gen_snapshot and fails at Dart VM init." >&2
fi
export FLUTTER_WORKSPACE="$PKG_DIR/staging/emb-workspace"
mkdir -p "$FLUTTER_WORKSPACE" "$PKG_DIR/staging"

if [[ ! -x "$FLUTTER_WORKSPACE/flutter/bin/flutter" ]]; then
  echo "ERROR: no Flutter SDK in $FLUTTER_WORKSPACE - run first:" >&2
  echo "  FLUTTER_WORKSPACE=$FLUTTER_WORKSPACE emb flutter --flutter-version <version>" >&2
  exit 1
fi

FLUTTER_BIN="$FLUTTER_WORKSPACE/flutter/bin/flutter"
ENGINE_ARTIFACTS="$FLUTTER_WORKSPACE/flutter/bin/cache/artifacts/engine"
FLUTTER_ARCH="$(uname -m)"
case "$FLUTTER_ARCH" in
  aarch64) FLUTTER_ARCH=arm64 ;;
  x86_64)  FLUTTER_ARCH=x64 ;;
esac
GEN_SNAPSHOT="$ENGINE_ARTIFACTS/linux-$FLUTTER_ARCH-release/gen_snapshot"

if [[ ! -x "$GEN_SNAPSHOT" ]]; then
  echo "Precaching Flutter release artifacts (linux-$FLUTTER_ARCH-release)..."
  "$FLUTTER_BIN" precache --linux --no-universal
fi

if [[ ! -x "$GEN_SNAPSHOT" ]]; then
  echo "ERROR: release gen_snapshot missing at $GEN_SNAPSHOT" >&2
  echo "       A freshly provisioned SDK only ships the host/debug gen_snapshot." >&2
  echo "       Pairing that with the release engine fails at Dart VM init with" >&2
  echo "       'dedup_instructions is false in snapshot'." >&2
  exit 1
fi

EMB_STATUS=0
( cd "$IHS_DIR" && emb cross "$EMB_MANIFEST" \
    --target "$EMB_TARGET" \
    --backend "$EMB_BACKEND" \
    --build \
    --app "$APP_DIR" \
    --mode release ) || EMB_STATUS=$?

BUILD_ROOT="$FLUTTER_WORKSPACE/.config/flutter_workspace"
HOMESCREEN_BIN="$(find "$BUILD_ROOT" -type f -path "*/build-$EMB_BACKEND/shell/homescreen" 2>/dev/null | head -1)"
EMB_BUNDLE="$(find "$BUILD_ROOT" -maxdepth 2 -type d -name 'app-bundle-release-*' 2>/dev/null | head -1)"

# emb reuses exit 70 for several conditions, including a benign complaint that
# the app's FFI libraries are undeclared bundle files (Dart build hooks produce
# them, not cross.modules). So the outputs decide success, not the exit code.
if [[ -z "$HOMESCREEN_BIN" || -z "$EMB_BUNDLE" ]]; then
  echo "ERROR: emb cross exited $EMB_STATUS and did not produce the expected outputs:" >&2
  [[ -z "$HOMESCREEN_BIN" ]] && echo "  missing: build-$EMB_BACKEND/shell/homescreen" >&2
  [[ -z "$EMB_BUNDLE" ]] && echo "  missing: app-bundle-release-*" >&2
  echo "  See emb's output above for the real cause." >&2
  exit "${EMB_STATUS:-1}"
fi

if (( EMB_STATUS != 0 )); then
  echo "NOTE: emb cross exited $EMB_STATUS but produced both outputs; continuing." >&2
fi

rm -rf "$STAGE_BUNDLE"
cp -a "$EMB_BUNDLE" "$STAGE_BUNDLE"

for f in lib/libapp.so lib/libflutter_engine.so data/icudtl.dat data/flutter_assets; do
  if [[ ! -e "$STAGE_BUNDLE/$f" ]]; then
    echo "ERROR: $f missing from the assembled bundle" >&2
    exit 1
  fi
done

MANIFEST_JSON="$STAGE_BUNDLE/data/flutter_assets/NativeAssetsManifest.json"
NATIVE_ASSETS_FILE="$PKG_DIR/staging/native-assets.txt"
: > "$NATIVE_ASSETS_FILE"

if [[ -f "$MANIFEST_JSON" ]]; then
  python3 - "$MANIFEST_JSON" > "$NATIVE_ASSETS_FILE" <<'PY'
import json, sys, os
data = json.load(open(sys.argv[1]))
names = set()
for assets in data.get("native-assets", {}).values():
    for entry in assets.values():
        if isinstance(entry, list) and len(entry) > 1:
            names.add(os.path.basename(entry[1]))
for n in sorted(names):
    print(n)
PY
fi

if [[ -s "$NATIVE_ASSETS_FILE" ]]; then
  while read -r f; do
    [[ -z "$f" ]] && continue
    if [[ ! -f "$STAGE_BUNDLE/lib/$f" ]]; then
      echo "ERROR: $f is declared in NativeAssetsManifest.json but missing from bundle lib/" >&2
      echo "       The app's FFI layer will fail to resolve it at runtime." >&2
      exit 1
    fi
  done < "$NATIVE_ASSETS_FILE"
  echo "Native assets verified: $(tr '\n' ' ' < "$NATIVE_ASSETS_FILE")"
else
  echo "NOTE: no native assets declared - the app uses no FFI libraries." >&2
fi

echo "Rebuilding libapp.so with the release gen_snapshot..."
emb aot --app-path "$APP_DIR" --mode release --exec-native --gen-snapshot "$GEN_SNAPSHOT"
if [[ ! -f "$APP_DIR/libapp.so.release" ]]; then
  echo "ERROR: emb aot did not produce $APP_DIR/libapp.so.release" >&2
  exit 1
fi
cp -a "$APP_DIR/libapp.so.release" "$STAGE_BUNDLE/lib/libapp.so"

{
  echo "HOMESCREEN_BIN=$HOMESCREEN_BIN"
  echo "IHS_SHARED_DIR=$(dirname "$(dirname "$HOMESCREEN_BIN")")/shared"
} > "$PATHS_FILE"

echo "Bundle assembled at $STAGE_BUNDLE"
du -sh "$STAGE_BUNDLE"
cat "$PATHS_FILE"
