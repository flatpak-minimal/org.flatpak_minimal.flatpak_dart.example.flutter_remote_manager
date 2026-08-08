# CI reference

`versions.env` pins version/ref strings shared by every build. The env vars
below are **not** version pins — they're filesystem paths to build artifacts
that only exist once a prerequisite CI step has produced them. Each CI job
must set all of these explicitly; there is no auto-derivable default for a
runner that doesn't already have this dev workspace's exact layout.

| Env var | Consumed by | CI job step that must set it |
|---|---|---|
| `EXAMPLE_DIR` | `scripts/01-build-flutter-bundle.sh` | After checking out `tcna-packages` at `TCNA_PACKAGES_REF` (from `versions.env`): `$GITHUB_WORKSPACE/tcna-packages/packages/flatpak/example` |
| `FLUTTER_ENGINE_LIB` | `scripts/01-build-flutter-bundle.sh` | After fetching the pinned per-arch custom engine artifact (`FLUTTER_ENGINE_ARTIFACT_URL_AARCH64` / `_X86_64` in `versions.env` — see "Flutter engine" below): path to the downloaded `libflutter_engine.so` |
| `HOMESCREEN_BIN` | `scripts/02-discover-vendor-libs.sh`, `scripts/03-stage-vendor-libs.sh` | After the "build homescreen" step (x86_64: `homescreen-build` composite action; aarch64: `build-homescreen-aarch64` composite action): path to the built `shell/homescreen` binary |
| `IHS_SHARED_DIR` | `scripts/03-stage-vendor-libs.sh` | Same homescreen build step's `shared/` output directory |
| `AGL_LIB_DIR` | `scripts/03-stage-vendor-libs.sh` | Only required when `VENDOR_DEV_GPU_STACK=1` (dev-only profile — **not set in production CI**). Path to a directory containing `libwayland-{client,egl,cursor}.so.*` |
| `TOOLCHAIN_LIB_DIR` | `scripts/03-stage-vendor-libs.sh` | Only required when `VENDOR_DEV_GPU_STACK=1`. Path to the LLVM toolchain's `lib/<triplet>` dir (`libc++`/`libc++abi`/`libunwind`) |
| `GL_LIB_DIR` / `DRI_DIR` | `scripts/02-discover-vendor-libs.sh`, `scripts/03-stage-vendor-libs.sh` | Only required when `VENDOR_DEV_GPU_STACK=1`. Default arch-aware (`/lib/<uname -m>-linux-gnu`, `/usr/lib/<uname -m>-linux-gnu/dri`) — override only if the runner's layout differs |
| `FLATPAK_ARCH` | `scripts/04-build-and-install.sh`, `scripts/05-build-bundle.sh` | Set from the CI job matrix (`x86_64` / `aarch64`) |

## Production vs. dev-only GPU profile

`VENDOR_DEV_GPU_STACK` gates the host-Mesa/DRI-driver vendoring workaround
(see README.md's "The EGL/GPU problem" section). **CI must leave this unset**
— it exists only to work around a specific dev VM's virtualized-GPU (virtio-gpu/virgl)
Mesa version mismatch, which real IVI/AGL target hardware shouldn't hit
(single native Mesa/DRM stack, no virtualized GPU passthrough pair). Setting
it in production would vendor one dev machine's Mesa build into every user's
sandbox, which is wrong on hardware that doesn't match it.

## Flutter engine

`libflutter_engine.so` is a custom-patched build (not the stock engine
`flutter precache` fetches) — see `versions.env`'s `FLUTTER_ENGINE_VERSION`
and `workspace-automation/configs/flutter-engine.json` for the patch set and
`gclient`/`gn`/`ninja` build process. This is a separate, infrequent pipeline
from per-push app CI:
1. Build once per architecture (multi-hour).
2. Publish as a versioned artifact (GitHub Release asset on a low-frequency
   "engine build" tag, or equivalent).
3. Record the download URL in `versions.env`'s `FLUTTER_ENGINE_ARTIFACT_URL_AARCH64` / `_X86_64`.
4. Per-push app CI fetches the pinned artifact by URL — it never rebuilds
   the engine itself.

## Validation gate

After `flatpak-builder` populates `build-dir/files`, CI sweeps the built tree
for any library that fails to resolve:
```bash
find build-dir/files -type f \( -executable -o -name '*.so*' \) -exec sh -c \
  'ldd "$1" 2>&1 | grep -q "not found" && echo "BROKEN: $1"' _ {} \; | tee missing.txt
[ -s missing.txt ] && exit 1 || true
```
This is the single highest-value automated gate available without a display —
it catches the exact class of bug (missing transitive `.so`) this project's
debugging history (see README.md) was mostly fighting.

## What CI does NOT verify

A headless GUI/EGL smoke test isn't attempted: this build's `homescreen` has
no `software` backend compiled in, so a nested-headless-Wayland render check
isn't feasible without first adding `BUILD_BACKEND_SOFTWARE=ON` to the CI
build recipe (a concrete, scoped follow-up, not solved here). "The app
actually renders" remains a manual check on real hardware or the self-hosted
runner's GPU.
