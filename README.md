# org.flatpak_minimal.flatpak_dart.example.flutter_remote_manager

Flatpak packaging for
[flutter_remote_manager](https://github.com/flatpak-minimal/flutter_remote_manager).
It runs under `homescreen` from
[ivi-homescreen](https://github.com/toyota-connected/ivi-homescreen), not Flutter's own
Linux runner, because that's what the target hardware uses.

The app ID is the repo name, so the manifests and the desktop/appdata/icon files are all
named after it.

Local builds work. CI can't produce a Flatpak yet — the four archive checksums in the
production manifest are still `000…0` placeholders, filled in after the first
`build-artifacts` run.

## Build

The scripts have no built-in paths — point them at your checkouts:

```sh
sudo apt install flatpak-builder

# emb_cli on PATH, then provision the SDK into this repo's workspace
git clone https://github.com/toyota-connected/emb_cli
eval "$(emb_cli/bootstrap.sh --shellenv)"
FLUTTER_WORKSPACE=$PWD/staging/emb-workspace emb flutter --flutter-version 3.44.2

# ivi-homescreen, with emb's cross manifest alongside it
git clone --recurse-submodules https://github.com/toyota-connected/ivi-homescreen
cp emb_cli/examples/cross/all-backends.emb.yaml ivi-homescreen/

export APP_DIR=/path/to/flutter_remote_manager
export IHS_DIR=$PWD/ivi-homescreen

VENDOR_DEV_GPU_STACK=1 ./scripts/04-build-and-install.sh
flatpak run org.flatpak_minimal.flatpak_dart.example.flutter_remote_manager
```

Anything unset stops the build with a message naming it.

`scripts/04` runs 01 (one `emb cross --build --app`, producing the embedder and the
bundle — engine, AOT snapshot, assets and the app's FFI libraries), 02 (work out which
shared libs the runtime doesn't provide), and 03 (stage them), then builds the dev
manifest. `05` makes a `.flatpak` bundle; `06` makes the tarballs CI publishes.

`scripts/01` pins `FLUTTER_WORKSPACE` to `staging/emb-workspace` and ignores an
inherited value. emb reuses whatever engine artifacts it finds in a workspace, and a
mismatched set fails later at Dart VM init rather than at build time.

`VENDOR_DEV_GPU_STACK=1` is only needed on this dev VM — its virtio-gpu/virgl Mesa is
too old for the runtime's GL extension, so EGL config negotiation fails. Real hardware
shouldn't need it, and CI never sets it.

## Manifests

`<app-id>.yml` is production: fetches prebuilt per-arch tarballs, no local dependencies.
`<app-id>.dev.yml` is for local work: reads from `staging/`. Same permissions, different
sources.

## CI

`build-artifacts.yml` is manual. It builds `homescreen` (`emb cross`) and the app bundle
(`emb bundle`) natively per arch — x86_64 on `ubuntu-latest`, aarch64 on
`ubuntu-24.04-arm` — then publishes four tarballs plus `SHA256SUMS-<arch>.txt` to the
`artifacts` release. Run it only when the app, homescreen or the toolchain actually
change.

`ci.yml` runs on every push. It builds the production manifest for both arches (aarch64
under QEMU, which is fine because this job only repackages prebuilt tarballs), uploads
the bundles, deploys to flat-manager, and cuts a GitHub Release on tags.

The two are joined by a manual pinning step:

1. Dispatch `build-artifacts.yml`.
2. Copy the four hashes from `SHA256SUMS-<arch>.txt` (also printed in the job log).
3. Paste them into the four `sha256:` fields in `<app-id>.yml`, commit, push.
4. `ci.yml` now fetches and verifies them, and emits `.flatpak` bundles.

Repeat 1–3 whenever a pinned input moves. `versions.env` holds those pins and is loaded
into `$GITHUB_ENV`; `APP_REF` is a commit SHA rather than a branch so unrelated commits
can't drift into a build.

flat-manager deployment needs secrets `FLAT_MANAGER_URL` and `FLAT_MANAGER_TOKEN` plus
variable `FLAT_MANAGER_REPOSITORY`. Until those exist the step fails, and
`continue-on-error` keeps it from blocking the rest.

Three things have never been exercised and will surface on the first dispatch: whether
`emb engine --mode release` really provisions a release engine (Flutter publishes only a
debug/JIT embedder, and AOT `libapp.so` needs release), whether the toolchain discovery
step finds emb_cli's LLVM cache, and whether `EMB_TARGET=local` resolves on both legs.

## Debugging

```sh
flatpak run --command=sh -li org.flatpak_minimal.flatpak_dart.example.flutter_remote_manager
ldd /app/bin/homescreen | grep 'not found'
LD_DEBUG=libs IHS_LOG_LEVEL=debug /app/bin/flatpak-app-store
```

That `ldd` check is usually how a missing vendored lib turns up — though it won't catch
the `dlopen`ed ones below.

## Gotchas

`LD_LIBRARY_PATH=/app/lib` and the `XDG_DATA_HOME` override in `flatpak-app-store.sh`
both look redundant and aren't. Without the first, `dlopen`ed libraries with no RPATH
don't resolve. Without the second, libflatpak reads Flatpak's private per-app data dir
and every remote and installed app comes back empty — silently.

`libflutter_engine.so` belongs in the bundle tarball (homescreen resolves it by path),
while `libflatpak_nc.so`, `libappstream.so` and `libsqlite3.so` belong in `/app/lib`
(Dart resolves them by bare soname). None are visible to `ldd`, so `scripts/02` will
never discover them.

Don't install the appdata file — the SDK has no `appstream-compose`, so it fails the
build.

The wayland libraries come from the runner's `/usr/lib`, not an AGL sysroot, so CI and
local dev may not ship identical versions.
