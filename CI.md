# CI reference

Two GitHub Actions workflows, with two different jobs:

- **`.github/workflows/build-artifacts.yml`** (manual `workflow_dispatch`
  only) — builds `homescreen` from source (aarch64 on a self-hosted runner,
  x86_64 on `ubuntu-latest`) plus the Flutter app bundle, packages both into
  per-arch tarballs, and publishes them as assets on a `artifacts` GitHub
  Release. Run this whenever `homescreen`/the plugin/the toolchain/the
  Flutter app changes enough to need a new pinned artifact — **not** on
  every push.
- **`.github/workflows/ci.yml`** (every push + PR, using
  [`flatpak/flatpak-github-actions`](https://github.com/flatpak/flatpak-github-actions))
  — builds `org.agl.FlatpakAppStore.yml` (the production manifest) for both
  `x86_64` and `aarch64` (aarch64 via QEMU emulation on a regular
  `ubuntu-latest` runner — feasible because this job only *packages* the
  prebuilt artifact tarballs, it never compiles anything), deploys to
  flat-manager on every push, and on tag pushes additionally creates a
  GitHub Release with both `.flatpak` bundles.

## Two manifests

- `org.agl.FlatpakAppStore.yml` — **production**. Fetches the two per-arch
  artifact tarballs from `build-artifacts.yml`'s GitHub Release as
  `type: archive` sources (`only-arches: [aarch64]` / `[x86_64]`), no local
  staging dependency. This is what `ci.yml` builds via
  `flatpak/flatpak-github-actions/flatpak-builder@v6`.
- `org.agl.FlatpakAppStore.dev.yml` — **local dev only**. Sources are local
  `staging/` directories populated by `scripts/01-04-*.sh`, and supports the
  dev-only GPU vendoring workaround (`VENDOR_DEV_GPU_STACK=1`). Not used by
  either CI workflow.

## Artifact pinning

`org.agl.FlatpakAppStore.yml`'s archive sources have placeholder
`sha256: "000...0"` values and point at
`releases/download/artifacts/{homescreen,flutter-bundle}-<arch>.tar.xz`.
After running `build-artifacts.yml` (once per arch, or whenever inputs
change):
1. Download `SHA256SUMS-<arch>.txt` from the `artifacts` release (also
   printed in the workflow's last step's logs).
2. Update the matching `sha256:` field(s) in `org.agl.FlatpakAppStore.yml`.
3. Commit. `ci.yml` will now fetch the new, correctly-pinned tarball.

The URLs themselves are stable (same release, `--clobber` overwrites the
assets each `build-artifacts.yml` run) — only the `sha256:` values need
updating when the underlying binaries change.

## versions.env-driven inputs (used by build-artifacts.yml, not ci.yml)

| Env var | Consumed by | Set by |
|---|---|---|
| `TCNA_PACKAGES_REF`, `FLUTTER_VERSION`, `IVI_HOMESCREEN_REF`, `IVI_HOMESCREEN_PLUGINS_REF`, `LLVM_TOOLCHAIN_VERSION`, `LLVM_TOOLCHAIN_AARCH64_SHA256` | `build-artifacts.yml` | `versions.env`, loaded into `$GITHUB_ENV` |
| `FLUTTER_ENGINE_ARTIFACT_URL_AARCH64` / `_X86_64` | `build-artifacts.yml`'s "Fetch Flutter engine artifact" step | `versions.env` — see "Flutter engine" below; **blank by default**, that step fails loudly until filled in |

`ci.yml` itself doesn't source `versions.env` — the production manifest has
no build-time inputs beyond its pinned archive URLs/hashes.

## Flutter engine

`libflutter_engine.so` is a custom-patched build (not the stock engine
`flutter precache` fetches) — see `versions.env`'s `FLUTTER_ENGINE_VERSION`
and `workspace-automation/configs/flutter-engine.json` for the patch set and
`gclient`/`gn`/`ninja` build process. This is a separate, infrequent,
manual pipeline, not part of `build-artifacts.yml` itself:
1. Build once per architecture (multi-hour) on a matching-arch machine.
2. Publish `libflutter_engine.so` as a downloadable artifact (e.g. a GitHub
   Release asset on a low-frequency "engine build" tag).
3. Record the download URL in `versions.env`'s
   `FLUTTER_ENGINE_ARTIFACT_URL_AARCH64` / `_X86_64`.
4. `build-artifacts.yml` fetches the pinned artifact by URL.

## flat-manager

`ci.yml`'s "Deploy to flat-manager" step needs, once flat-manager is
deployed:
- Repo secret `FLAT_MANAGER_URL` — the flat-manager instance's API endpoint.
- Repo secret `FLAT_MANAGER_TOKEN` — a build-token scoped to the target repo.
- Repo variable `FLAT_MANAGER_REPOSITORY` — the flat-manager repo name to
  publish into (e.g. a `beta`/`nightly` channel).

Until those are set, the step runs with empty inputs and fails —
`continue-on-error: true` keeps that from blocking the rest of `ci.yml` in
the meantime. Once flat-manager is live, add the three secrets/variables and
remove `continue-on-error` (or leave it, as a safety net against transient
flat-manager outages — your call).

## Validation

`flatpak/flatpak-github-actions/flatpak-builder@v6` fails the job outright if
`flatpak-builder` fails (missing/mismatched sources, manifest errors, etc) —
that's the primary automated gate now that packaging itself runs through the
"upstream" tool rather than our own script. A dependency-closure `ldd ...
not found` sweep (the kind of check that caught most of this project's
historical bugs — see README.md's "The EGL/GPU problem" section) is not run
by `ci.yml` itself; if you want that gate back, add it as a step in
`build-artifacts.yml` right after `scripts/03-stage-vendor-libs.sh`, since
that's where the full dependency closure actually gets assembled now.

## What CI does NOT verify

A headless GUI/EGL smoke test isn't attempted: this build's `homescreen` has
no `software` backend compiled in, so a nested-headless-Wayland render check
isn't feasible without first adding `BUILD_BACKEND_SOFTWARE=ON` to
`build-artifacts.yml`'s build recipe (a concrete, scoped follow-up, not
solved here). "The app actually renders" remains a manual check on real
hardware or a self-hosted runner's GPU.
