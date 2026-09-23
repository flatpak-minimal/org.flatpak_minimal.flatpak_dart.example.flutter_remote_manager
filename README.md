# Flatpak packaging via emb_cli

Packages a Flutter app as a Flatpak that runs under `homescreen` from
[ivi-homescreen](https://github.com/toyota-connected/ivi-homescreen) rather than Flutter's
own Linux runner, because that is what the target hardware uses.

A repo like this one is a manifest and two assets. Everything else, via
[emb_cli](https://github.com/toyota-connected/emb_cli), clones the embedder and the app at
the pinned revisions, provisions the Flutter SDK, cross-builds the embedder, builds the app
(including any Dart build hooks that produce FFI libraries), assembles the bundle, vendors
the libraries the runtime does not provide, and emits the `.flatpak`. There is no build
script and no hand-written flatpak-builder manifest; emb generates both.

The worked example here is
[flutter_remote_manager](https://github.com/flatpak-minimal/flutter_remote_manager), whose
app ID is the repo name, so the manifest and metadata files are named after it. To package a
different app, point `cross.app:` at it and rename the assets to match its app ID.

## Build

```sh
sudo apt install flatpak flatpak-builder

# emb on PATH (bootstrap.sh fetches a pinned Dart SDK; --shellenv prints the
# PATH update for this shell)
git clone https://github.com/toyota-connected/emb_cli
eval "$(emb_cli/bootstrap.sh --shellenv)"

# the runtime, which emb also reads to decide what needs vendoring
flatpak install --user org.freedesktop.Platform//25.08 org.freedesktop.Sdk//25.08

emb cross <manifest>.emb.yaml --target local --build --flatpak

flatpak install --user staging/emb-workspace/.config/flutter_workspace/*/dist/*.flatpak
flatpak run <app-id>
```

For this repo that is `flatpak-app-store.emb.yaml` and
`org.flatpak_minimal.flatpak_dart.example.flutter_remote_manager`.

`--target local` is not optional for a native build. A flat manifest declaring a single
cross target (here `arm-gnu`) has that target selected when `--target` is omitted, which then
asks for a cross toolchain nobody wants on the host. `local` is the reserved name for the
host build.

The first build provisions everything into the `workspace:` directory and takes a while;
later ones reuse it. `emb cross` prints the path it wrote the bundle to.

To work against your own checkouts instead of the pinned ones, override either side:

```sh
emb cross <manifest>.emb.yaml --target local --build --flatpak \
  --app ../<app-checkout>                  # --app beats cross.app:
emb cross ... -w /path/to/workspace        # -w beats workspace:
```

`--dry-run` reports the plan and fetches nothing.

## The manifest

The `.emb.yaml` holds the whole pipeline. The keys that matter:

| key | what it does |
|---|---|
| `workspace:` | where the SDK and engine artifacts are provisioned |
| `flutter_version:` | the SDK provisioned into that workspace |
| `cross.source:` | the embedder repo, and the branch or revision to build |
| `cross.app:` | the app repo, and the branch or revision to build |
| `cross.defines:` / `cross.backends:` | embedder build options and the backend matrix |
| `cross.package.flatpak:` | app ID, runtime, permissions, and runtime environment |

`icon:` resolves against the manifest's directory, which is why the assets can live beside it
while the build happens in the checkout emb makes under the workspace. Scaling is by adding
entries, not scripts: another backend is one more key under `backends:`, another board is a
`cross.targets:` entry, and app-specific `-dev` packages belong in the app's own
`.emb/*.emb.yaml`, which emb merges over the target.

## CI

`ci.yml` builds natively per arch (x86_64 on `ubuntu-latest`, aarch64 on `ubuntu-24.04-arm`)
and uploads the `.flatpak` from each. It installs host build dependencies, the runtime and
emb_cli, then runs the one `emb cross`. `EMB_CLI_REF` is the only pin left in the workflow,
because which emb builds this is CI's business and everything else is the manifest's.

Deploying to flat-manager happens only from `main`; releases only on tags. Branches and PRs
build and stop. flat-manager needs secrets `FLAT_MANAGER_URL` and `FLAT_MANAGER_TOKEN` plus
variable `FLAT_MANAGER_REPOSITORY`; until those exist the step fails, and `continue-on-error`
keeps it from blocking the rest.

## Debugging

```sh
flatpak run --command=sh -li <app-id>
APP=/app/<app-id>
readelf -d $APP/homescreen | grep RPATH      # $ORIGIN/lib:$ORIGIN
ldd $APP/homescreen | grep 'not found'
ldd $APP/lib/<dlopened-lib>.so | grep 'not found'
```

An empty `not found` is the check that vendoring did its job. It won't catch libraries the
app `dlopen`s under a bare soname; those carry no `DT_NEEDED` entry, arrive in the bundle
because the build hooks put them there, and resolve because `vendor_libs` puts the bundle's
`lib/` on the launcher's `LD_LIBRARY_PATH`.
