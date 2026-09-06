# org.flatpak_minimal.flatpak_dart.example.flutter_remote_manager

Flatpak packaging for
[flutter_remote_manager](https://github.com/flatpak-minimal/flutter_remote_manager).
It runs under `homescreen` from
[ivi-homescreen](https://github.com/toyota-connected/ivi-homescreen), not Flutter's own
Linux runner, because that's what the target hardware uses.

The app ID is the repo name, so the manifest and the metadata files are named after it.

Everything is built by [emb_cli](https://github.com/toyota-connected/emb_cli). One
`emb cross` invocation cross-builds the embedder, builds the app (including the Dart
build hooks that produce flatpak_dart's FFI libraries), assembles the bundle, vendors the
libraries the runtime doesn't provide, and emits the `.flatpak`. This repo contributes a
manifest and the metadata; it does not assemble anything itself.

## Build

```sh
sudo apt install flatpak flatpak-builder

# emb on PATH (bootstrap.sh fetches a pinned Dart SDK; --shellenv prints the
# PATH update for this shell), then provision the SDK into this repo's workspace
git clone https://github.com/toyota-connected/emb_cli
eval "$(emb_cli/bootstrap.sh --shellenv)"
FLUTTER_WORKSPACE=$PWD/staging/emb-workspace emb flutter --flutter-version 3.44.2

# the runtime, which emb also reads to decide what needs vendoring
flatpak install --user org.freedesktop.Platform//25.08 org.freedesktop.Sdk//25.08

git clone --recurse-submodules https://github.com/toyota-connected/ivi-homescreen

export APP_DIR=/path/to/flutter_remote_manager
export IHS_DIR=$PWD/ivi-homescreen
./scripts/build.sh

flatpak install --user dist/*.flatpak
flatpak run org.flatpak_minimal.flatpak_dart.example.flutter_remote_manager
```

Anything unset stops the build with a message naming it.

`scripts/build.sh` is only staging. It pins `FLUTTER_WORKSPACE` to
`staging/emb-workspace` (emb reuses whatever engine artifacts it finds in a workspace,
and a mismatched set fails later at Dart VM init rather than at build time), sources the
`setup_env.sh` that `emb env` writes there — which scopes `PUB_CACHE` and
`XDG_CONFIG_HOME` to the workspace, so a build does not reach into your global pub
cache — copies `emb/` into the ivi-homescreen checkout, and runs:

```sh
emb cross flatpak-app-store.emb.yaml --target local --mode release \
  --build --app "$APP_DIR" --flatpak
```

The copy is not incidental: `emb cross <file>` uses the file's parent directory as the
CMake source dir, and resolves `icon:`/`files:` against that same directory, so the
manifest and its assets have to sit at the source root.

## The manifest

`emb/flatpak-app-store.emb.yaml` holds the whole pipeline — embedder defines, the
backend matrix, and a `cross.package.flatpak` block carrying the app id, runtime,
sandbox permissions, launcher environment and embedder flags. There is no
flatpak-builder manifest in this repo; emb generates one.

Scaling is by adding entries, not scripts: another backend is one more key under
`backends:`, another board is a `cross.targets:` entry, and app-specific `-dev` packages
belong in the app's own `.emb/*.emb.yaml`, which `--app` merges over the target.

## CI

`ci.yml` runs on pushes to `main`, on tags, on pull requests, and on demand. It builds
natively per arch — x86_64 on `ubuntu-latest`, aarch64 on `ubuntu-24.04-arm` — and
uploads the `.flatpak` from each. There is no intermediate tarball release and no
checksum to pin back into a manifest: the build that produces the bundle is the build
that publishes it.

Deploying to flat-manager happens only from `main`; releases only on tags. Branches and
PRs build and stop.

`versions.env` holds the pins and is loaded into `$GITHUB_ENV`; `APP_REF` is a commit SHA
rather than a branch so unrelated commits can't drift into a build.

flat-manager deployment needs secrets `FLAT_MANAGER_URL` and `FLAT_MANAGER_TOKEN` plus
variable `FLAT_MANAGER_REPOSITORY`. Until those exist the step fails, and
`continue-on-error` keeps it from blocking the rest.

## Debugging

```sh
flatpak run --command=sh -li org.flatpak_minimal.flatpak_dart.example.flutter_remote_manager
APP=/app/org.flatpak_minimal.flatpak_dart.example.flutter_remote_manager
readelf -d $APP/homescreen | grep RPATH      # $ORIGIN/lib:$ORIGIN
ldd $APP/homescreen | grep 'not found'
ldd $APP/lib/libflatpak_nc.so | grep 'not found'
```

An empty `not found` is the check that vendoring did its job — though it won't catch the
`dlopen`ed libraries below.

## Gotchas

`XDG_DATA_HOME` in the manifest's `env:` block looks redundant and isn't. Without it,
libflatpak reads Flatpak's private per-app data dir and every remote and installed app
comes back empty — silently.

`GIO_USE_PROXY_RESOLVER=dummy` stops glib asking `xdg-desktop-portal` for proxy
configuration. Without a portal running — AGL images typically have none — that call
blocks for the full D-Bus timeout and adds over a minute to startup. Override it with
`flatpak run --env=` if a target needs a real proxy; every entry in `env:` is a default,
not a forced value.

`libflatpak_nc.so`, `libappstream.so` and `libsqlite3.so` are `dlopen`ed by Dart under
their bare sonames, so they carry no `DT_NEEDED` entry anywhere and no closure walk will
find them. They arrive in the bundle because the build hooks put them there; `env:` sets
`LD_LIBRARY_PATH` to the bundle's `lib/` so the `dlopen` resolves even from a caller with
no rpath of its own.

The appdata file is shipped in `emb/` but deliberately not installed: putting it in
`/app/share/metainfo` makes flatpak-builder run `appstream-compose`, which the
freedesktop SDK does not have, and the build fails.

`agl_shell` may only be bound by one client, and on a real AGL image the launcher already
owns it — binding it aborts the whole connection. `ENABLE_AGL_SHELL_CLIENT=OFF` in the
manifest compiles that client out and the app uses plain xdg-shell instead.

The wayland libraries come from the runner's `/usr/lib`, not an AGL sysroot, so CI and
local dev may not ship identical versions.
