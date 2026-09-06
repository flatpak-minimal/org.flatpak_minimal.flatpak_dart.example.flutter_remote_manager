#!/usr/bin/env bash
# Build the flatpak. One emb invocation does the whole pipeline; everything here
# is just staging its inputs.
set -euo pipefail

: "${APP_DIR:?must be set - path to the flutter_remote_manager checkout}"
EMB_TARGET="${EMB_TARGET:-local}"
EMB_MODE="${EMB_MODE:-release}"

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST=flatpak-app-store.emb.yaml

[[ -d "$APP_DIR" ]] || { echo "ERROR: not a directory: $APP_DIR" >&2; exit 1; }

command -v emb >/dev/null || {
  echo "ERROR: emb (emb_cli) not found on PATH - bootstrap it first (see README)" >&2
  exit 1
}

# emb reuses any engine artifacts it finds in the workspace, and an engine from
# an unrelated SDK silently mismatches gen_snapshot and dies at Dart VM init.
# Pin the workspace to ours rather than inheriting one.
if [[ -n "${FLUTTER_WORKSPACE:-}" && "$FLUTTER_WORKSPACE" != "$PKG_DIR/staging/emb-workspace" ]]; then
  echo "NOTE: ignoring inherited FLUTTER_WORKSPACE=$FLUTTER_WORKSPACE" >&2
fi
export FLUTTER_WORKSPACE="$PKG_DIR/staging/emb-workspace"

if [[ ! -x "$FLUTTER_WORKSPACE/flutter/bin/flutter" ]]; then
  echo "ERROR: no Flutter SDK in $FLUTTER_WORKSPACE - run first:" >&2
  echo "  FLUTTER_WORKSPACE=$FLUTTER_WORKSPACE emb flutter --flutter-version <version>" >&2
  exit 1
fi

# setup_env.sh scopes PUB_CACHE and XDG_CONFIG_HOME to the workspace, so a build
# does not reach into the user's global pub cache. It bakes an absolute
# FLUTTER_WORKSPACE, though, so a copy of this repo would inherit whichever
# workspace it was generated against — regenerate it for ours before sourcing.
emb env -w "$FLUTTER_WORKSPACE" >/dev/null
# shellcheck disable=SC1091
. "$FLUTTER_WORKSPACE/setup_env.sh" >/dev/null

# A freshly provisioned SDK is a git checkout with no bin/cache: the Dart SDK
# and engine artifacts only appear once a flutter command runs. emb decides
# which frontend_server to use by probing that cache *before* it invokes
# flutter, so on a cold workspace it takes the wrong branch and the kernel
# snapshot fails. Warm the cache first; it is a no-op once populated.
if [[ ! -f "$FLUTTER_WORKSPACE/flutter/bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot" ]]; then
  echo "Precaching Flutter artifacts (first build in this workspace)..."
  "$FLUTTER_WORKSPACE/flutter/bin/flutter" precache --linux --no-universal
fi

# The embedder source. emb-src/ pins the revision; emb sync clones it into
# <workspace>/app. Set IHS_DIR yourself to build against your own checkout.
if [[ -z "${IHS_DIR:-}" ]]; then
  emb sync -p "$PKG_DIR/emb-src" -w "$FLUTTER_WORKSPACE"
  IHS_DIR="$FLUTTER_WORKSPACE/app/ivi-homescreen"
fi
[[ -d "$IHS_DIR" ]] || { echo "ERROR: not a directory: $IHS_DIR" >&2; exit 1; }

# emb does not resolve the app itself — it expects a package_config.json and
# says so. This repo scopes PUB_CACHE to its own workspace, so an app that was
# resolved anywhere else carries a config pointing at packages this cache does
# not hold, which surfaces as type errors inside Flutter's own sources.
"$FLUTTER_WORKSPACE/flutter/bin/flutter" pub get --directory "$APP_DIR"

# The manifest names the CMake source dir by its own location, and resolves
# `icon:`/`files:` against it, so the whole emb/ directory goes to the
# ivi-homescreen root.
cp -a "$PKG_DIR/emb/." "$IHS_DIR/"

cd "$IHS_DIR"
emb cross "$MANIFEST" \
  --target "$EMB_TARGET" \
  --mode "$EMB_MODE" \
  --build \
  --app "$APP_DIR" \
  --flatpak

# emb writes the bundle to <build-root>/dist/. Collect it where CI and a local
# `flatpak install` can both find it without knowing emb's build-dir hash.
mkdir -p "$PKG_DIR/dist"
find "$FLUTTER_WORKSPACE/.config/flutter_workspace" -path '*/dist/*.flatpak' \
  -exec cp -a {} "$PKG_DIR/dist/" \;
ls -lh "$PKG_DIR/dist"
