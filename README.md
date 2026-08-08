# org.agl.FlatpakAppStore

Flatpak packaging for the `flatpak_flutter` example app (a Flutter "app
store" UI for managing Flatpaks on AGL/IVI), launched via the custom
`homescreen` Wayland/EGL shell instead of Flutter's own generated Linux
runner. **Confirmed working end-to-end**: builds, installs, launches, renders,
and runs the Dart/Flutter UI.

## How it works

`homescreen` hosts a prebuilt Flutter "bundle" directory
(`data/flutter_assets`, `data/icudtl.dat`, `lib/libapp.so`,
`lib/libflutter_engine.so`) via `homescreen -b <bundle-dir>`. This repo
vendors the already-built, tested `homescreen` binary (from
`~/workspace-automation/app/ivi-homescreen/build`) plus every shared library
it needs that isn't provided by the `org.freedesktop.Platform//25.08` runtime
— because `homescreen` was built with the Flatpak-management plugin compiled
in, it links directly against `libflatpak`, `libostree`, `libsoup-2.4`,
`libjson-glib`, and a long transitive chain (gpgme, polkit, mount, selinux,
TLS stacks, etc).

Rebuilding ivi-homescreen from source inside the flatpak-builder sandbox was
deliberately avoided (its custom vendored LLVM/libc++ toolchain risks ABI
mismatches against the Flatpak SDK's toolchain, and it's much slower).

## Production / CI

- `versions.env` is the single source of truth for pinned versions/refs
  (Flutter, `org.freedesktop.Platform` runtime, `tcna-packages`/`ivi-homescreen`/
  `ivi-homescreen-plugins` commit refs, LLVM toolchain version + checksum).
- `.github/workflows/ci.yml` builds **both aarch64 and x86_64** on every push
  and PR (aarch64 on a self-hosted runner, x86_64 on GitHub-hosted
  `ubuntu-latest`), validates the built dependency closure, and — on tag
  pushes — publishes single-file `.flatpak` bundles to a GitHub Release. See
  `CI.md` for the required per-job env vars and how the custom Flutter engine
  artifact is fetched (built separately, not per-push).
- `VENDOR_DEV_GPU_STACK=1` is a **dev-only opt-in flag** (unset/off by
  default) that vendors this specific dev VM's Mesa/GL/DRI stack to work
  around its virtualized-GPU (virtio-gpu/virgl) version mismatch — see "The
  EGL/GPU problem" below. Production/CI builds never set it; real IVI target
  hardware has a single native Mesa/DRM stack and shouldn't need it.
- `scripts/05-build-bundle.sh` is CI's bundle-producing path (`flatpak
  build-bundle`, arch-parameterized via `FLATPAK_ARCH`), kept separate from
  the dev-loop `scripts/04-build-and-install.sh` (`--user --install`) so they
  don't contend over the same `build-dir`.

## Build (local dev loop)

```sh
sudo apt install flatpak-builder   # one-time
VENDOR_DEV_GPU_STACK=1 ./scripts/04-build-and-install.sh   # this VM needs the GPU workaround, see below
flatpak run org.agl.FlatpakAppStore
```

The pipeline runs, in order:

1. `scripts/01-build-flutter-bundle.sh` — `flutter build linux --release` in
   the example app, assembles `staging/bundle/` (including
   `lib/libflutter_engine.so`, copied from the Flutter workspace's engine
   build — homescreen `dlopen`s this at runtime, so it isn't visible to any
   `ldd`-based dependency scan).
2. `scripts/02-discover-vendor-libs.sh` — walks the full transitive
   dependency closure (not just `homescreen`'s direct deps, but also the
   Mesa/GL libraries vendored in step 3 below, which pull in their own large
   dependency chain) against the installed runtime tree, writing
   `staging/vendor-libs.txt`.
3. `scripts/03-stage-vendor-libs.sh` — copies `homescreen`, `libihs_shared`,
   the AGL-built wayland libs, the LLVM 18.1.8 toolchain runtime libs, the
   host's Mesa GL/EGL stack + DRI drivers, and everything flagged in
   `vendor-libs.txt` into `staging/vendor-bin` / `staging/vendor-lib`.
4. `flatpak-builder --user --install --force-clean build-dir
   org.agl.FlatpakAppStore.yml`.

## The EGL/GPU problem (solved)

The app would launch, connect to Wayland, and then fail with
`did not find config with buffer size 24` — but only inside the sandbox;
the exact same binary ran fine natively. Root cause and fix, in the order
they were found and fixed (see `scripts/03-stage-vendor-libs.sh` and
`flatpak-app-store.sh` for the actual implementation):

1. **Mesa version skew.** This host renders through `virtio-gpu`/virgl (a VM
   passing GL calls to the host GPU via ANGLE/Metal). Flatpak's
   `--device=dri` auto-attaches `org.freedesktop.Platform.GL.default`, which
   ships Mesa 26.1.5 — three major versions newer than this host's tested,
   working Mesa 23.2.1. That version skew broke EGL config negotiation
   against virgl. **Fix:** vendor the host's own `libEGL.so.1`,
   `libGLESv2.so.2`, `libGLdispatch.so.0`, `libgbm.so.1`, and the
   `virtio_gpu_dri.so`/`swrast_dri.so`/`kms_swrast_dri.so` DRI drivers
   instead of relying on the GL extension.

2. **libglvnd vendor JSON.** `libEGL.so.1` is just a vendor-neutral
   dispatcher — it resolves the real backend (`libEGL_mesa.so.0`) via a JSON
   ICD file (`/usr/share/glvnd/egl_vendor.d/50_mesa.json` on the host).
   Vendoring the dispatcher alone did nothing, because it still resolved the
   backend via the standard search path (i.e. the GL extension's mismatched
   Mesa). **Fix:** vendor `libEGL_mesa.so.0` too, install our own
   `50_mesa.json` pointing at `/app/lib/libEGL_mesa.so.0`, and set
   `__EGL_VENDOR_LIBRARY_FILENAMES=/app/lib/50_mesa.json` in the wrapper.

3. **`/app/lib` never on the loader path.** `/etc/ld.so.conf.d/` is empty
   inside this sandbox — the `simple` buildsystem doesn't register `/app/lib`
   with `ldconfig` the way `cmake`/`autotools` modules do. Everything that
   "just worked" so far did so via baked-in `RPATH`; `dlopen`'d libraries with
   no `RPATH` of their own (like the DRI driver's dependency on
   `libLLVM-15.so.1`) had nowhere to resolve from. **Fix:** export
   `LD_LIBRARY_PATH=/app/lib` in the wrapper script.

4. **Self-clobbering vendor symlinks.** The generic "resolve real file, `cp`
   it, then `ln -sf soname -> realfile`" logic broke for libraries whose real
   filename *is* the soname (e.g. `libLLVM-15.so.1` has no further
   `.x.y.z` suffix) — `cp` created the real file, then `ln -sf` immediately
   overwrote it with a symlink pointing at itself. **Fix:** skip the symlink
   step when `basename(realsrc) == soname`.

Once all four were fixed, `eglChooseConfig` succeeded and the app rendered.

## Other things fixed along the way

- **`flutter build linux --release` failing entirely**: the example app's
  `flutter_permission_handler_plus: ^0.1.0` dependency (unused in code)
  ships a broken Linux `CMakeLists.txt`. Removed from `example/pubspec.yaml`.
- **`-lc++abi` build failure**: the workspace's global
  `CXXFLAGS="-stdlib=libc++ -lc++abi"` puts a link-only flag into every
  compile invocation; CMake's `-Werror` turns the resulting "unused
  argument" warning into a hard failure. Fixed locally in
  `01-build-flutter-bundle.sh` by moving `-lc++abi` to `LDFLAGS`, without
  touching the caller's shell environment.
- **`appstream-compose` missing**: `org.freedesktop.Sdk//25.08` doesn't ship
  it (only `appstreamcli`), so flatpak-builder's automatic AppStream compose
  step fails if an `.appdata.xml` is installed. Not installing it for this
  `--user` build (see `org.agl.FlatpakAppStore.appdata.xml`, kept in-repo for
  reference only).
- **`libflutter_engine.so` not found**: it's `dlopen`'d, not linked, so no
  dependency scan sees it. Now copied into the bundle by
  `01-build-flutter-bundle.sh`.
- **D-Bus system bus**: the FlatpakPlugin needs both `--socket=session-bus`
  and `--socket=system-bus` — it calls D-Bus directly rather than through
  `flatpak-spawn --host`.
- **System Flatpak installation crash**: the plugin queries both the user
  and system Flatpak installations; without `--filesystem=/var/lib/flatpak:ro`
  it hit a null-deref crash on the missing-system-installation error path
  rather than degrading gracefully. Granted read-only.

## Debugging

```sh
flatpak run --command=sh -li org.agl.FlatpakAppStore
ldd /app/bin/homescreen | grep 'not found'      # catch any missed vendor lib
LD_DEBUG=libs IHS_LOG_LEVEL=debug /app/bin/flatpak-app-store
```

## Known open risks

- **Vendor-lib completeness**: the transitive dependency chain is long
  (~45+ libs, including the Mesa/GL stack's own closure).
  `02-discover-vendor-libs.sh` gives a repeatable discovery method, but
  review its output manually, especially TLS/crypto/curl/systemd libs where
  a version mismatch can segfault instead of failing to load.
- **D-Bus permissions**: `--socket=session-bus` + `--socket=system-bus` is a
  broad grant. Harden later by tracing real bus traffic with
  `busctl monitor` and switching to narrow `--talk-name=...` entries.
- **`--filesystem=~/.local/share/flatpak` and `/var/lib/flatpak:ro`**:
  libflatpak/ostree touch these directly in-process (not through a portal),
  so the sandbox needs real filesystem access — the main sandbox-weakening
  grant in this manifest. Acceptable for a single-app IVI kiosk context, but
  call it out to reviewers.
- **Vendored Mesa is host-specific**: the GL stack in step 3 is pinned to
  *this* host's exact Mesa build (23.2.1, `virtio_gpu_dri.so`). On different
  hardware (real IVI target with a native DRM driver, or a different VM/GPU
  passthrough), this vendoring approach should be revisited — it may not be
  necessary at all on real hardware, where there's a single native Mesa/DRM
  stack instead of a version-skewed guest/host GPU passthrough pair.
