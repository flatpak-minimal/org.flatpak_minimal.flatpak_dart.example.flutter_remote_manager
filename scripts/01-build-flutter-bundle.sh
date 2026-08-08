#!/usr/bin/env bash
# Builds the flatpak_flutter example app in release mode and assembles the
# ivi-homescreen "bundle" directory (data/flutter_assets, data/icudtl.dat, lib/libapp.so)
# that `homescreen -b <bundle-dir>` expects.
set -euo pipefail

EXAMPLE_DIR="${EXAMPLE_DIR:-/home/wafdy/workspace-automation/app/tcna-packages/packages/flatpak/example}"
# Default only resolves on this dev machine's aarch64 checkout; CI must
# always pass FLUTTER_ENGINE_LIB explicitly per arch (see CI.md) — the
# custom-patched engine build has no auto-derivable per-arch path.
FLUTTER_ENGINE_LIB="${FLUTTER_ENGINE_LIB:-/home/wafdy/workspace-automation/.config/flutter_workspace/flutter-engine/bundle-release-arm64/lib/libflutter_engine.so}"
PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE_BUNDLE="$PKG_DIR/staging/bundle"

if [[ ! -d "$EXAMPLE_DIR" ]]; then
  echo "ERROR: example app not found at $EXAMPLE_DIR (override with EXAMPLE_DIR=...)" >&2
  exit 1
fi

cd "$EXAMPLE_DIR"
# The workspace's global CXXFLAGS ("-stdlib=libc++ -lc++abi") puts a
# link-only flag into compile-step flags; CMake's -Werror then turns the
# resulting "unused command line argument" warning into a build failure.
# Unset the inherited CXXFLAGS/LDFLAGS first, then move -lc++abi to LDFLAGS
# (link-only) for this build, without touching the caller's shell environment.
env -u CXXFLAGS -u LDFLAGS \
  CXXFLAGS="-stdlib=libc++" LDFLAGS="-lc++abi" \
  flutter build linux --release

# Flutter names its Linux build output dir after uname -m, but not literally:
# aarch64 -> "arm64", x86_64 -> "x64".
case "$(uname -m)" in
  aarch64) FLUTTER_ARCH_DIR=arm64 ;;
  x86_64)  FLUTTER_ARCH_DIR=x64 ;;
  *) echo "ERROR: unsupported build arch $(uname -m)" >&2; exit 1 ;;
esac
REL_DIR="build/linux/${FLUTTER_ARCH_DIR}/release/bundle"
if [[ ! -d "$REL_DIR" ]]; then
  echo "ERROR: expected release bundle at $EXAMPLE_DIR/$REL_DIR, found instead:" >&2
  find build/linux -maxdepth 3 -type d >&2 || true
  exit 1
fi
if [[ ! -f "$REL_DIR/lib/libapp.so" ]]; then
  echo "ERROR: libapp.so missing from $REL_DIR/lib — AOT build likely failed" >&2
  exit 1
fi
if [[ ! -f "$REL_DIR/data/icudtl.dat" || ! -d "$REL_DIR/data/flutter_assets" ]]; then
  echo "ERROR: data/icudtl.dat or data/flutter_assets missing from $REL_DIR/data" >&2
  exit 1
fi

rm -rf "$STAGE_BUNDLE"
mkdir -p "$STAGE_BUNDLE/data" "$STAGE_BUNDLE/lib"
cp -a "$REL_DIR/data/flutter_assets" "$STAGE_BUNDLE/data/flutter_assets"
cp -a "$REL_DIR/data/icudtl.dat"     "$STAGE_BUNDLE/data/icudtl.dat"
cp -a "$REL_DIR/lib/libapp.so"       "$STAGE_BUNDLE/lib/libapp.so"

# homescreen dlopen's libflutter_engine.so at runtime (it's not a linked dep,
# so ldd-based vendor discovery never sees it) — the ivi-homescreen bundle
# layout expects an optional lib/libflutter_engine.so here. Without it,
# homescreen fails immediately after plugin init with
# "dlopen(libflutter_engine.so) failed: ... No such file or directory".
if [[ ! -f "$FLUTTER_ENGINE_LIB" ]]; then
  echo "ERROR: libflutter_engine.so not found at $FLUTTER_ENGINE_LIB (override with FLUTTER_ENGINE_LIB=...)" >&2
  exit 1
fi
cp -a "$FLUTTER_ENGINE_LIB" "$STAGE_BUNDLE/lib/libflutter_engine.so"

echo "Bundle assembled at $STAGE_BUNDLE"
du -sh "$STAGE_BUNDLE"