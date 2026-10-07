<!--
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# 🦀 Rust Build

<!-- prettier-ignore-start -->
<!-- markdownlint-disable-next-line MD013 -->
[![Linux Foundation](https://img.shields.io/badge/Linux-Foundation-blue)](https://linuxfoundation.org/) [![Source Code](https://img.shields.io/badge/GitHub-100000?logo=github&logoColor=white&color=blue)](https://github.com/lfreleng-actions/rust-build-action) [![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0) [![pre-commit.ci status badge]][pre-commit.ci results page] [![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/lfreleng-actions/rust-build-action/badge)](https://scorecard.dev/viewer/?uri=github.com/lfreleng-actions/rust-build-action)
<!-- prettier-ignore-end -->

Builds a Rust project with Cargo. On request, it also collects the
binaries the build produced, packages the publishable crates as
`.crate` files, records SHA-256 checksums for both, and uploads them
as one workflow artefact.

The action holds no credentials and needs no `id-token` permission.
Attest, sign or publish the uploaded artefact in a separate job that
holds those permissions.

## rust-build-action

## Usage Example

<!-- markdownlint-disable MD013 MD046 -->

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false

      - name: "Build Rust project"
        id: build
        # Pin to a commit SHA
        uses: lfreleng-actions/rust-build-action@<commit-sha>
        with:
          binaries: "true"
          package_crates: "true"

      - name: "Show what the build produced"
        shell: bash
        env:
          BINARIES: ${{ steps.build.outputs.binaries_json }}
          CRATES: ${{ steps.build.outputs.crates_json }}
        run: |
          echo "Binaries: $BINARIES"
          echo "Crates: $CRATES"
```

A later job fetches the artefact by name, through a job output:

```yaml
  # In the build job above, add:
  #   outputs:
  #     artefact_name: ${{ steps.build.outputs.artefact_name }}
  verify:
    needs: build
    runs-on: ubuntu-latest
    permissions: {}
    steps:
      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
        with:
          name: ${{ needs.build.outputs.artefact_name }}
          path: dist
      - name: "Verify checksums"
        shell: bash
        working-directory: dist
        run: sha256sum -c SHA256SUMS
```

<!-- markdownlint-enable MD013 MD046 -->

## Inputs

All inputs are optional. Boolean inputs accept `true` or `false`
and nothing else.

<!-- markdownlint-disable MD013 -->

| Name                | Default      | Description                                                                           |
| ------------------- | ------------ | ------------------------------------------------------------------------------------- |
| path_prefix         | `.`          | Directory holding the project, inside the workspace                                   |
| manifest_path       | `Cargo.toml` | Path to `Cargo.toml`, relative to `path_prefix` or absolute; must not be a symlink    |
| workspace           | `true`       | Build every workspace member (`--workspace`); a non-empty `packages` replaces it      |
| packages            | `''`         | Whitespace-separated packages to build (`--package`), in place of `--workspace`       |
| exclude             | `''`         | Whitespace-separated packages to skip (`--exclude`); needs `workspace`, no `packages` |
| features            | `''`         | Features to enable, separated by whitespace or commas; `package/feature` allowed      |
| all_features        | `false`      | Enable all features (`--all-features`)                                                |
| no_default_features | `false`      | Disable default features (`--no-default-features`)                                    |
| toolchain           | `''`         | rustup channel to use; empty uses the toolchain that `path_prefix` selects            |
| lockfile_required   | `false`      | Fail when `Cargo.lock` is missing, instead of generating one                          |
| setup_script        | `''`         | Script to run with bash before Cargo, relative to `path_prefix`                       |
| target              | `''`         | Target triple to build for; empty builds for the host                                 |
| profile             | `release`    | Cargo profile: `dev`, `release` or a custom profile name                              |
| cargo_args          | `''`         | Extra `cargo build` arguments, split on whitespace and never run by a shell           |
| binaries            | `false`      | Copy built binaries into `artefact_path` with a `SHA256SUMS` file                     |
| package_crates      | `false`      | Package publishable crates into `artefact_path/crates` with `crates.json`             |
| artefact_upload     | `true`       | Upload `artefact_path` as a workflow artefact when it holds files                     |
| artefact_name       | `''`         | Artefact name; empty uses `rust-build-<target triple>`                                |
| artefact_path       | `dist`       | Directory for binaries and crates, relative to `path_prefix`; must be empty or new    |
| summary             | `true`       | Write a job summary                                                                   |

<!-- markdownlint-enable MD013 -->

## Outputs

<!-- markdownlint-disable MD013 -->

| Name           | Description                                                                          |
| -------------- | ------------------------------------------------------------------------------------ |
| toolchain      | Toolchain used: a rustup channel or a path; empty without rustup                     |
| toolchain_kind | How the action chose the toolchain: `channel`, `path` or `none`                      |
| cargo_version  | Cargo version that ran the build                                                     |
| rustc_version  | rustc version that ran the build                                                     |
| target         | Target triple built for; the host triple when `target` is empty                      |
| profile        | Cargo profile used                                                                   |
| artefact_name  | Artefact name the upload uses; set even when the action uploads nothing              |
| artefact_path  | Artefact directory, relative to the workspace                                        |
| binaries_json  | JSON array of `{name, path, sha256}`; `path` is relative to `artefact_path`          |
| crates_json    | JSON array of `{name, version, file, sha256}`; `file` is relative to `artefact_path` |
| rust_version   | `rust-version` (MSRV) the manifest's package declares; empty if none                 |

<!-- markdownlint-enable MD013 -->

## Implementation Details

The action runs these stages in order and stops at the first failure.
The job summary names the stage that failed.

1. **Check inputs.** Rejects any invalid input before running anything.
   Error messages name the input and never echo its value.
2. **Resolve toolchain.** With an empty `toolchain`,
   `rustup show active-toolchain` names the toolchain that
   `path_prefix` selects (`rust-toolchain.toml`, an override, or the
   default). The action pins a channel through `RUSTUP_TOOLCHAIN` for
   every later call. A path-based toolchain runs unpinned from
   `path_prefix`, with a warning. Without rustup, the action uses the
   `cargo` on `PATH` and reports `toolchain_kind` as `none`.
3. **Run setup script.** Runs `setup_script` with bash from
   `path_prefix`, for example to install the native libraries that
   `-sys` crates need.
4. **Inspect toolchain.** Records the Cargo and rustc versions and
   the host triple.
5. **Add target.** For a non-host `target` on a channel toolchain,
   runs `rustup target add`. Other toolchains must already have it.
6. **Read metadata.** Runs `cargo metadata` and works out the
   selected packages the same way Cargo does: the named ones, every
   member less exclusions, or with `workspace: false` the default
   members (the manifest's own package, else
   `workspace.default-members`, else every member). A non-empty
   `packages` replaces `--workspace`, because Cargo ignores
   `--package` under `--workspace` and builds every member. With
   `package_crates` on Cargo older than 1.90, the action fails here
   (as "Check packaging") when one crate it would package depends on
   another; see [Notes](#notes).
7. **Check lockfile.** Without `Cargo.lock`, the action fails when
   `lockfile_required` is `true`. Otherwise it runs
   `cargo generate-lockfile` and warns. Every later Cargo command
   runs with `--locked`.
8. **Build.** Runs `cargo build` with the selected profile, target,
   packages and features, then `cargo_args`. The action always passes
   `--target`, the host triple included, so `build.target` in Cargo
   configuration cannot build for a target the outputs do not name.
   Cargo then writes to `target/<triple>/<profile>` and, as with any
   explicit `--target`, does not pass `RUSTFLAGS` to build scripts
   and proc macros.
9. **Package crates.** With `package_crates`, runs `cargo package`
   for the selected packages that Cargo may publish, skipping those
   with `publish = false`.
10. **Collect artefacts.** Copies binaries to the top of
    `artefact_path` with a `SHA256SUMS` file covering them. Copies
    `.crate` files to `artefact_path/crates`, and writes
    `crates.json` at the top of `artefact_path`. Then uploads
    `artefact_path` unless `artefact_upload` is `false`.

The job summary shows the outcome, a table of the stages, each file
collected with its size and checksum, and any warnings.

### Binaries

The action takes binaries from the executables that Cargo reports
while building, and keeps the `bin` targets of the selected packages.
It leaves out test harnesses, build scripts and binaries of packages
that the build pulled in as dependencies. A `bin` target that Cargo
skipped, for example for unmet `required-features`, produces a
warning. A binary named `SHA256SUMS`, `crates` or `crates.json`, in
any letter case, fails the build: it would collide with the
artefact's own files.

### Security

- Cargo, rustc, rustup and `setup_script` run without these
  environment variables, so that repository code (build scripts,
  proc macros, `setup_script`) never sees them:
  - registry credentials: `CARGO_REGISTRY_TOKEN` and every
    `CARGO_REGISTRIES_<NAME>_TOKEN`, for crates.io and alternate
    registries alike; other registry settings such as
    `CARGO_REGISTRIES_<NAME>_INDEX` stay;
  - GitHub OIDC and runtime tokens: `ACTIONS_ID_TOKEN_REQUEST_TOKEN`,
    `ACTIONS_ID_TOKEN_REQUEST_URL` and `ACTIONS_RUNTIME_TOKEN`;
  - the runner's command files: `GITHUB_OUTPUT`, `GITHUB_ENV`,
    `GITHUB_PATH`, `GITHUB_STATE` and `GITHUB_STEP_SUMMARY`, through
    which a child could forge step outputs, set the environment or
    `PATH` of later steps, or spoof the job summary. The action's own
    writes to them still happen.
- This is defence in depth, not a boundary. Code running as the same
  user can still read an ancestor process's environment, and find the
  command files at their predictable paths: give this job no
  credentials it does not need. The action replaces the output file
  with its validated outputs when it exits, whether the build passed
  or failed, which discards what a build script wrote there before the
  action ended. A process that a setup or build script leaves running
  can still write to the output file or `artefact_path` afterwards.
  Trust every project you build with this action as you trust the
  job's upload.
- `path_prefix`, `manifest_path`, `setup_script` and `artefact_path`
  must resolve inside the workspace after following symlinks.
  `manifest_path` and `setup_script` must not be symlinks themselves.
  The action checks `artefact_path` again after creating it.
- `artefact_path` must not contain `path_prefix`, and must be empty or
  absent, so the artefact holds this build's files and nothing else.
  The action checks again before collecting, and fails if the setup
  script or the build (`--target-dir`, say) wrote anything there.
- `upload-artifact` reads its `path` as a glob pattern, so the
  resolved `artefact_path` may not contain `*`, `?`, `[`, `]` or a
  backslash, start with `!`, `#` or `~`, or start or end with a space.
- `cargo_args` cannot set options that inputs control: `--target`,
  `--profile`, `--release`/`-r`, `--package`/`-p`, `--workspace`,
  `--exclude`, `--features`/`-F`, `--all-features`,
  `--no-default-features`, `--manifest-path` and `--message-format`.
  The check also reads clustered short flags such as `-vr`.
- The action validates every output as a single line before writing
  it, and escapes values it shows in the job summary.

## Notes

- The action runs on Linux runners, which its CI tests. It refuses
  Windows runners, whose native paths its workspace checks and binary
  collection do not handle. Its CI does not cover macOS runners.
- `workspace: false` needs Cargo 1.71 or later: older releases omit
  the default members from `cargo metadata`, and the action reads them
  to select packages.
- Before Cargo 1.90, `cargo package` checks each crate against the
  registry alone, so it cannot package a crate together with another
  selected crate that it depends on. Independent crates package fine
  on older releases. With `package_crates: true` and an older Cargo,
  the action fails before building when one crate it would package
  depends on another, through a path dependency of any kind (a path
  dev-dependency without a version does not count: Cargo drops it).
  `cargo metadata` reports a path dev-dependency with `version = "*"`
  the same way as one without a version, but Cargo keeps it, so that
  case still fails in `cargo package`, after the build, with a warning
  that names the cause. Select fewer packages, or use Cargo 1.90 or
  later.
- Cargo runs from `path_prefix`, so it reads `.cargo/config.toml`
  files from `path_prefix` and its parents, not from a deeper
  directory holding `manifest_path`.
- Cross-compiling needs a linker for the target. Provide one with
  `setup_script`, or use a runner that matches the target.
- The action does not cache Cargo's registry or build directory.
- In a git repository, `cargo package` refuses untracked or modified
  files in a package directory. Commit or ignore them, including any
  that `setup_script` writes there. A `Cargo.lock` that the action
  generates does not count.
- With `binaries` and `package_crates` both `false`, `artefact_path`
  stays empty and the action uploads nothing.

[pre-commit.ci results page]: https://results.pre-commit.ci/latest/github/lfreleng-actions/rust-build-action/main
[pre-commit.ci status badge]: https://results.pre-commit.ci/badge/github/lfreleng-actions/rust-build-action/main.svg
