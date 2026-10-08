#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Unit tests for scripts/rust-build.sh against cargo, rustc and rustup
# stand-ins (fixtures/). Nothing here compiles or touches the network.
# PATH holds only the stand-ins and links to the system tools the
# script needs, so a real Rust installation cannot leak in.

# Variables exported inside a test stay in that test's subshell. Single
# quotes deliberately hold script text for the stand-ins, and 'ls' only
# lists names this suite chose.
# shellcheck disable=SC2012,SC2016,SC2030,SC2031

bats_require_minimum_version 1.7.0

setup() {
  repo_dir="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  action_file="$repo_dir/action.yaml"
  script="$repo_dir/scripts/rust-build.sh"
  mkdir -p "$BATS_TEST_TMPDIR/work space"
  workdir="$(cd "$BATS_TEST_TMPDIR/work space" && pwd -P)"
  project="$workdir/my project"
  mkdir -p "$workdir/bin" "$workdir/sys" "$workdir/runner temp" \
    "$project/crates/lib-a" "$project/crates/tool"

  local tool path
  for tool in cargo rustup rustc; do
    cp "$BATS_TEST_DIRNAME/fixtures/$tool.sh" "$workdir/bin/$tool"
    chmod +x "$workdir/bin/$tool"
  done
  for tool in awk basename bash cat chmod cp cut dirname env grep head jq \
    ln ls mkdir mktemp mv od perl printf readlink rm rmdir sed sha256sum \
    shasum sort tail tee touch tr uname wc xargs; do
    if path="$(command -v "$tool")" && [ -x "$path" ]; then
      ln -s "$path" "$workdir/sys/$tool"
    fi
  done
  export PATH="$workdir/bin:$workdir/sys" LC_ALL=C

  printf '[package]\nname = "app"\n' > "$project/Cargo.toml"
  printf '# lockfile\n' > "$project/Cargo.lock"
  printf '[package]\nname = "lib-a"\n' > "$project/crates/lib-a/Cargo.toml"
  printf '[package]\nname = "tool"\n' > "$project/crates/tool/Cargo.toml"

  export GITHUB_WORKSPACE="$workdir"
  export GITHUB_OUTPUT="$workdir/github output"
  export GITHUB_STEP_SUMMARY="$workdir/job summary"
  export RUNNER_TEMP="$workdir/runner temp"
  export INPUT_PATH_PREFIX="my project"
  export MOCK_ROOT="$project"
  export MOCK_CARGO_LOG="$workdir/cargo calls"
  export MOCK_CARGO_ENV="$workdir/tool env"
  export MOCK_RUSTUP_LOG="$workdir/rustup calls"
  export MOCK_FIXTURES="$BATS_TEST_DIRNAME/fixtures"
  local name
  for name in $(compgen -e); do
    case "$name" in
      INPUT_PATH_PREFIX | MOCK_ROOT | MOCK_CARGO_LOG | MOCK_CARGO_ENV \
        | MOCK_RUSTUP_LOG | MOCK_FIXTURES) ;;
      INPUT_* | MOCK_* | CARGO_REGISTRIES_*) unset "$name" ;;
    esac
  done
  unset CARGO_REGISTRY_TOKEN ACTIONS_ID_TOKEN_REQUEST_TOKEN \
    ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_RUNTIME_TOKEN GITHUB_ENV \
    GITHUB_PATH GITHUB_STATE RUSTUP_TOOLCHAIN CARGO_TARGET_DIR
  : > "$GITHUB_OUTPUT"
  : > "$GITHUB_STEP_SUMMARY"
  : > "$MOCK_CARGO_LOG"
  : > "$MOCK_CARGO_ENV"
  : > "$MOCK_RUSTUP_LOG"
}

run_action() {
  run "$BASH" "$script"
}

# The value the runner keeps for an output: the last one written.
output_value() {
  awk -v key="$1=" 'index($0, key) == 1 { value = substr($0, length(key) + 1); found = 1 }
    END { if (found) print value }' "$GITHUB_OUTPUT"
}

build_call() {
  grep '^build ' "$MOCK_CARGO_LOG"
}

package_call() {
  grep '^package ' "$MOCK_CARGO_LOG"
}

assert_no_cargo() {
  [ ! -s "$MOCK_CARGO_LOG" ]
  [ ! -s "$MOCK_RUSTUP_LOG" ]
}

# Field N of every logged tool environment row, deduplicated:
# 1 command, 2 cwd, 3 RUSTUP_TOOLCHAIN, 4 the withheld variables, and
# any CARGO_REGISTRIES_* one, present (fixtures/record-env.sh).
env_field() {
  awk -F'|' -v f="$1" '{ print $f }' "$MOCK_CARGO_ENV" | LC_ALL=C sort -u
}

sha256_text() {
  if command -v sha256sum > /dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
  else
    printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
  fi
}

readonly base_build="build --locked --message-format=json-render-diagnostics --manifest-path @ROOT/Cargo.toml --profile=release"
readonly default_build="$base_build --target=x86_64-unknown-linux-gnu"
readonly metadata_call="metadata --no-deps --format-version 1 --locked --manifest-path @ROOT/Cargo.toml"

### Default flow ###

@test "builds the whole workspace with the release profile by default" {
  run_action

  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_CARGO_LOG")" = "$(printf '%s\n' --version \
    "$metadata_call" "$default_build --workspace")" ]
  [ "$(cat "$MOCK_RUSTUP_LOG")" = "show active-toolchain --verbose" ]
  # Every output once as found, again after the last child process,
  # then upload.
  local outputs
  outputs="$(printf '%s\n' "artefact_path=my project/dist" \
    toolchain=stable-x86_64-unknown-linux-gnu toolchain_kind=channel \
    cargo_version=1.99.0 rustc_version=1.99.0 \
    target=x86_64-unknown-linux-gnu profile=release \
    artefact_name=rust-build-x86_64-unknown-linux-gnu rust_version=1.80 \
    'binaries_json=[]' 'crates_json=[]')"
  [ "$(cat "$GITHUB_OUTPUT")" = "$outputs"$'\n'upload=false ]
  [ ! -e "$project/dist" ]
  [[ "$output" == *"Rust build complete"* ]]
}

@test "runs every tool from path_prefix and removes its temporary files" {
  run_action

  [ "$status" -eq 0 ]
  [ "$(env_field 2)" = "$project" ]
  run ! compgen -G "$RUNNER_TEMP/rust-build.*"
}

@test "removes its temporary files after a failure too" {
  export MOCK_FAIL=build
  run_action

  [ "$status" -eq 42 ]
  run ! compgen -G "$RUNNER_TEMP/rust-build.*"
}

@test "writes only single-line name=value outputs" {
  export INPUT_BINARIES=true INPUT_PACKAGE_CRATES=true INPUT_WORKSPACE=true
  run_action

  [ "$status" -eq 0 ]
  [ "$(grep -cv '^[a-z_]*=[^=]' "$GITHUB_OUTPUT" || true)" -eq 0 ]
  [ "$(cut -d= -f1 "$GITHUB_OUTPUT" | LC_ALL=C sort -u | wc -l)" -eq 12 ]
}

### Input validation ###

@test "rejects anything but 'true' or 'false' for every boolean input" {
  local input value
  for input in WORKSPACE ALL_FEATURES NO_DEFAULT_FEATURES LOCKFILE_REQUIRED \
    BINARIES PACKAGE_CRATES ARTEFACT_UPLOAD SUMMARY; do
    for value in TRUE yes 1 '' $'true\nfalse'; do
      export "INPUT_$input=$value"
      run_action
      [ "$status" -eq 1 ]
      [[ "$output" == *"${input,,} must be 'true' or 'false'"* ]]
      unset "INPUT_$input"
    done
  done
  assert_no_cargo
}

@test "rejects malformed toolchain names without echoing them" {
  local value
  for value in -stable 'stable nightly' 'stable;id' '../x' \
    $'stable\n::error::injected'; do
    export INPUT_TOOLCHAIN="$value"
    run_action
    [ "$status" -eq 1 ]
    [[ "$output" == *"toolchain must be a rustup channel name"* ]]
    [[ "$output" != *"injected"* ]]
  done
  assert_no_cargo
}

@test "rejects malformed target triples" {
  local value
  for value in x86_64 X86_64-unknown-linux-gnu -x86_64-linux 'a-b c' \
    ../x-y /tmp/custom.json 'x86_64-unknown-linux-gnu;id' a-b-c-d-e-f; do
    export INPUT_TARGET="$value"
    run_action
    [ "$status" -eq 1 ]
    [[ "$output" == *"target must be a target triple"* ]]
  done
  assert_no_cargo
}

@test "rejects malformed profile names" {
  local value
  for value in '' 1fast -r 'dev profile' 'release;id' "$(printf 'p%.0s' {1..70})"; do
    export INPUT_PROFILE="$value"
    run_action
    [ "$status" -eq 1 ]
    [[ "$output" == *"profile must be dev, release or a custom profile name"* ]]
  done
  assert_no_cargo
}

@test "rejects artefact names that upload-artifact or a shell would mangle" {
  local value
  for value in a/b -name 'a:b' 'a b' '.hidden' "$(printf 'n%.0s' {1..101})"; do
    export INPUT_ARTEFACT_NAME="$value"
    run_action
    [ "$status" -eq 1 ]
    [[ "$output" == *"artefact_name may contain only"* ]]
  done
  assert_no_cargo
}

@test "rejects malformed package, exclude and feature names" {
  local value
  for value in 'app@1.0' -x 'a;b' 'a/b' '$(id)'; do
    export INPUT_PACKAGES="$value"
    run_action
    [ "$status" -eq 1 ]
    [[ "$output" == *"packages must list crate names"* ]]
  done
  unset INPUT_PACKAGES
  export INPUT_WORKSPACE=true INPUT_EXCLUDE='tool *'
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"exclude must list crate names"* ]]
  unset INPUT_WORKSPACE INPUT_EXCLUDE
  for value in 'a b;c' -x 'a=b' 'a@b' +x .x 'a/b/c' '/x' 'a/' 'a/+x' 'dep:x'; do
    export INPUT_FEATURES="$value"
    run_action
    [ "$status" -eq 1 ]
    [[ "$output" == *"features must list feature names"* ]]
  done
  assert_no_cargo
}

@test "accepts every feature name Cargo allows" {
  export INPUT_FEATURES='a+b x.y _u 9-z lib-a/c++ lib_a/v1.2'
  run_action

  [ "$status" -eq 0 ]
  [ "$(build_call)" = "$default_build --workspace --features=a+b,x.y,_u,9-z,lib-a/c++,lib_a/v1.2" ]
}

@test "rejects exclude without workspace, or alongside packages" {
  export INPUT_WORKSPACE=false INPUT_EXCLUDE=tool
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"exclude needs workspace set to 'true'"* ]]

  for flag in true false; do
    export INPUT_WORKSPACE="$flag" INPUT_PACKAGES=app
    run_action
    [ "$status" -eq 1 ]
    [[ "$output" == *"exclude cannot be combined with packages"* ]]
  done
  assert_no_cargo
}

@test "refuses Windows runners before running any tool" {
  export RUNNER_OS=Windows
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"Windows runners are not supported; use a Linux runner"* ]]
  assert_no_cargo
}

@test "rejects multi-line cargo_args" {
  export INPUT_CARGO_ARGS=$'--verbose\n--offline'
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"cargo_args must be a single line"* ]]
  assert_no_cargo
}

@test "rejects cargo_args that set an option an input controls" {
  local value
  for value in --message-format=short '--target x' --target=x --profile=dev \
    --release -r '--manifest-path x' -pfoo '--package foo' --workspace \
    --all '--exclude x' '-F x' --features=x --all-features \
    --no-default-features -vr -qvr -vpfoo -vFx -vvF; do
    export INPUT_CARGO_ARGS="--verbose $value"
    run_action
    [ "$status" -eq 1 ]
    [[ "$output" == *"cargo_args must not set "* ]]
  done
  assert_no_cargo
}

@test "reports a missing cargo before doing anything" {
  rm "$workdir/bin/cargo"
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"required tool not found on PATH: cargo"* ]]
  [ ! -s "$MOCK_RUSTUP_LOG" ]
}

### Path containment ###

@test "requires path_prefix to be a directory inside the workspace" {
  export INPUT_PATH_PREFIX=missing
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"path_prefix is not a directory"* ]]

  local value
  for value in .. /tmp "my project/../.."; do
    export INPUT_PATH_PREFIX="$value"
    run_action
    [ "$status" -eq 1 ]
    [[ "$output" == *"path_prefix must resolve inside the workspace"* ]]
  done
  assert_no_cargo
}

@test "refuses a path_prefix symlink that leaves the workspace" {
  mkdir -p "$BATS_TEST_TMPDIR/outside"
  ln -s "$BATS_TEST_TMPDIR/outside" "$workdir/escape"
  export INPUT_PATH_PREFIX=escape
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"path_prefix must resolve inside the workspace"* ]]
  assert_no_cargo
}

@test "requires manifest_path to name an existing, non-symlink Cargo.toml" {
  export INPUT_MANIFEST_PATH=src/lib.rs
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"manifest_path must name a Cargo.toml file"* ]]

  export INPUT_MANIFEST_PATH=missing/Cargo.toml
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"manifest_path does not name a file below path_prefix"* ]]

  mkdir -p "$project/linked"
  ln -s "$project/Cargo.toml" "$project/linked/Cargo.toml"
  export INPUT_MANIFEST_PATH=linked/Cargo.toml
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"manifest_path must not be a symlink"* ]]
  assert_no_cargo
}

@test "refuses a manifest_path whose directory resolves outside the workspace" {
  mkdir -p "$BATS_TEST_TMPDIR/outside"
  printf '[package]\n' > "$BATS_TEST_TMPDIR/outside/Cargo.toml"
  ln -s "$BATS_TEST_TMPDIR/outside" "$project/out"
  local value
  for value in out/Cargo.toml ../../outside/Cargo.toml \
    "$BATS_TEST_TMPDIR/outside/Cargo.toml"; do
    export INPUT_MANIFEST_PATH="$value"
    run_action
    [ "$status" -eq 1 ]
    [[ "$output" == *"manifest_path must resolve inside the workspace"* ]]
  done
  assert_no_cargo
}

@test "accepts a manifest_path given as an absolute path in the workspace" {
  export INPUT_MANIFEST_PATH="$project/crates/lib-a/Cargo.toml"
  run_action

  [ "$status" -eq 0 ]
  [[ "$(build_call)" == *"--manifest-path @ROOT/crates/lib-a/Cargo.toml "* ]]
}

@test "requires the Cargo workspace root to lie inside the workspace" {
  export MOCK_WORKSPACE_ROOT="$BATS_TEST_TMPDIR"
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"the Cargo workspace root must lie inside the workspace"* ]]
  [ -z "$(build_call)" ]
}

@test "requires artefact_path to resolve below the workspace" {
  mkdir -p "$BATS_TEST_TMPDIR/outside"
  ln -s "$BATS_TEST_TMPDIR/outside" "$project/linked"
  local value
  for value in ../.. ../../dist "$BATS_TEST_TMPDIR/abs-out" linked linked/new; do
    export INPUT_ARTEFACT_PATH="$value" INPUT_BINARIES=true
    run_action
    [ "$status" -eq 1 ]
    [[ "$output" == *"artefact_path must resolve to a directory below the workspace"* ]]
  done
  [ ! -e "$BATS_TEST_TMPDIR/outside/new" ]
  assert_no_cargo
}

@test "refuses an artefact_path that contains path_prefix" {
  export INPUT_BINARIES=true
  local value
  for value in . "$project"; do
    export INPUT_ARTEFACT_PATH="$value"
    run_action
    [ "$status" -eq 1 ]
    [[ "$output" == *"artefact_path must not contain path_prefix"* ]]
  done
  export INPUT_PATH_PREFIX="my project/crates/tool" INPUT_ARTEFACT_PATH=../..
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"artefact_path must not contain path_prefix"* ]]
  assert_no_cargo
}

@test "refuses '.', '..' and '//' in the part of artefact_path still to create" {
  export INPUT_BINARIES=true
  local value
  for value in new/../../.. new/./dist new//dist; do
    export INPUT_ARTEFACT_PATH="$value"
    run_action
    [ "$status" -eq 1 ]
    [[ "$output" == *"artefact_path may not use '.', '..' or '//'"* ]]
  done
  assert_no_cargo
}

@test "refuses an artefact_path that is a file or already holds files" {
  printf 'x' > "$project/file"
  export INPUT_ARTEFACT_PATH=file INPUT_BINARIES=true
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"artefact_path must name a directory"* ]]

  mkdir -p "$project/dist"
  printf 'stale' > "$project/dist/.old"
  export INPUT_ARTEFACT_PATH=dist
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"artefact_path must be empty or absent"* ]]
  assert_no_cargo
}

@test "refuses an artefact_path that upload-artifact would read as a glob" {
  local value
  for value in '*' 'a?b' '[ab]' 'a]b' 'a\b' '../!x' '../#x' '../~x' \
    '../ x' 'x '; do
    export INPUT_ARTEFACT_PATH="$value"
    run_action
    [ "$status" -eq 1 ]
    [[ "$output" == *"artefact_path must resolve to a path without glob syntax"* ]]
    [ -z "$(output_value artefact_path)" ]
  done
  assert_no_cargo

  # Only the start of the whole path is special to upload-artifact.
  export INPUT_ARTEFACT_PATH='~x/a!b#c' INPUT_BINARIES=true
  run_action
  [ "$status" -eq 0 ]
  [ "$(output_value artefact_path)" = "my project/~x/a!b#c" ]
}

@test "accepts an existing empty artefact_path and one beside path_prefix" {
  mkdir -p "$project/dist"
  export INPUT_BINARIES=true
  run_action
  [ "$status" -eq 0 ]
  [ -f "$project/dist/SHA256SUMS" ]

  export INPUT_ARTEFACT_PATH=../out/bin/
  run_action
  [ "$status" -eq 0 ]
  [ "$(output_value artefact_path | tail -1)" = out/bin ]
  [ -f "$workdir/out/bin/app" ]
}

@test "refuses an artefact_path replaced by a symlink during the build" {
  mkdir -p "$BATS_TEST_TMPDIR/outside"
  printf 'ln -s "%s" dist\n' "$BATS_TEST_TMPDIR/outside" > "$project/setup.sh"
  export INPUT_SETUP_SCRIPT=setup.sh INPUT_BINARIES=true
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"could not create artefact_path inside the workspace"* ]]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/outside")" ]
}

@test "refuses an artefact_path that would make a multi-line output" {
  export INPUT_ARTEFACT_PATH=$'dist\nupload=true'
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to write a multi-line value for output artefact_path"* ]]
  run ! grep -q '^upload=' "$GITHUB_OUTPUT"
  assert_no_cargo
}

### setup_script ###

@test "runs setup_script with bash from path_prefix before any cargo call" {
  mkdir -p "$project/ci"
  printf '%s\n' 'printf "%s|%s\n" "$PWD" "${RUSTUP_TOOLCHAIN-unset}" > "$SETUP_RECORD"' \
    'echo setup >> "$MOCK_CARGO_LOG"' > "$project/ci/setup.sh"
  export INPUT_SETUP_SCRIPT=ci/setup.sh SETUP_RECORD="$workdir/setup record"
  run_action

  [ "$status" -eq 0 ]
  [ "$(cat "$SETUP_RECORD")" = "$project|stable-x86_64-unknown-linux-gnu" ]
  [ "$(head -1 "$MOCK_CARGO_LOG")" = setup ]
}

@test "logs a setup_script path holding a newline on one line" {
  local name=$'x\n::error::forged.sh'
  mkdir -p "$project/ci"
  printf '%s\n' 'echo ran > "$SETUP_RECORD"' > "$project/ci/$name"
  export INPUT_SETUP_SCRIPT="ci/$name" SETUP_RECORD="$workdir/setup record"
  run_action

  [ "$status" -eq 0 ]
  [ "$(cat "$SETUP_RECORD")" = ran ]
  [[ "$output" == *"Running setup script "*"ci/x"*"::error::forged.sh"* ]]
  run ! grep -q '^::error::forged' <<< "$output"
}

@test "refuses files that reach artefact_path before collection" {
  printf '%s\n' 'mkdir -p dist' 'echo leak > dist/leak.txt' > "$project/setup.sh"
  local input
  for input in INPUT_BINARIES INPUT_PACKAGE_CRATES; do
    rm -rf "$project/dist"
    export INPUT_SETUP_SCRIPT=setup.sh "${input?}=true"
    run_action

    [ "$status" -eq 1 ]
    [[ "$output" == *"artefact_path gained files before collection"* ]]
    [ "$(ls -A "$project/dist")" = leak.txt ]
    [ "$(output_value upload)" = "" ]
    unset "$input"
  done
}

@test "stops when setup_script fails" {
  printf 'exit 7\n' > "$project/setup.sh"
  export INPUT_SETUP_SCRIPT=setup.sh
  run_action

  [ "$status" -eq 7 ]
  [ ! -s "$MOCK_CARGO_LOG" ]
  grep -q 'Failed at Run setup script' "$GITHUB_STEP_SUMMARY"
}

@test "requires setup_script to be a regular, non-symlink file in the workspace" {
  export INPUT_SETUP_SCRIPT=missing.sh
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"setup_script does not name a file below path_prefix"* ]]

  printf 'true\n' > "$BATS_TEST_TMPDIR/outside.sh"
  ln -s "$BATS_TEST_TMPDIR/outside.sh" "$project/linked.sh"
  export INPUT_SETUP_SCRIPT=linked.sh
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"setup_script must not be a symlink"* ]]

  export INPUT_SETUP_SCRIPT="$BATS_TEST_TMPDIR/outside.sh"
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"setup_script must resolve inside the workspace"* ]]
  assert_no_cargo
}

### Toolchain resolution ###

@test "pins every tool call to the channel rustup names for path_prefix" {
  export MOCK_TOOLCHAIN=1.85.0-x86_64-unknown-linux-gnu
  run_action

  [ "$status" -eq 0 ]
  [ "$(output_value toolchain)" = 1.85.0-x86_64-unknown-linux-gnu ]
  [ "$(output_value toolchain_kind)" = channel ]
  # The first row is 'rustup show' itself, which must run unpinned.
  [ "$(head -1 "$MOCK_CARGO_ENV" | cut -d'|' -f1,3)" = "show|unset" ]
  [ "$(tail -n +2 "$MOCK_CARGO_ENV" | cut -d'|' -f3 | sort -u)" \
    = 1.85.0-x86_64-unknown-linux-gnu ]
}

@test "the toolchain input overrides the project's selection" {
  export INPUT_TOOLCHAIN=nightly-2026-09-01
  run_action

  [ "$status" -eq 0 ]
  # Installed already: probed without auto-install, never reinstalled.
  [ "$(cat "$MOCK_RUSTUP_LOG")" = "which --toolchain nightly-2026-09-01 rustc" ]
  [ "$(output_value toolchain)" = nightly-2026-09-01 ]
  [ "$(env_field 3)" = nightly-2026-09-01 ]
}

@test "runs a path toolchain unpinned, with a warning" {
  export MOCK_TOOLCHAIN="/opt/my|toolchain"
  run_action

  [ "$status" -eq 0 ]
  [ "$(output_value toolchain_kind)" = path ]
  [ "$(output_value toolchain)" = "/opt/my|toolchain" ]
  [ "$(env_field 3)" = unset ]
  [[ "$output" == *"::warning title=rust-build::path_prefix selects a path-based toolchain"* ]]
  grep -Fq '<code>/opt/my&#124;toolchain</code>' "$GITHUB_STEP_SUMMARY"
}

@test "names a path toolchain exactly from either rustup output format" {
  # Toolchain directory under $workdir, then the reason rustup gives in
  # parentheses: every reason rustup 1.27 and 1.29 print, with " (",
  # parentheses and reason text inside the toolchain path and the path
  # a reason quotes.
  local q="$project/q (overridden by 'z')/rust-toolchain.toml"
  local -a cases=(
    "my (default)/tool" "overridden by '/w/rust-toolchain.toml'"
    "my (default)/tool" "default"
    "my tool (chain)" "overridden by '/src/p (x)/rust-toolchain.toml'"
    "a (overridden by 'b')/tc" "directory override for '/src/q (default)'"
    "tc (environment override by RUSTUP_TOOLCHAIN)" "environment override by RUSTUP_TOOLCHAIN"
    "x (directory override for 'y')" "overridden by environment variable RUSTUP_TOOLCHAIN"
    "tc" "overridden by +toolchain on the command line"
    "tc (beta)" "overridden by '/w (default)/rust-toolchain'"
    "my (default) tc" "overridden by '$q'"
    "nest" "default"
    "nest (default)" "default"
  )
  local i legacy tc
  for ((i = 0; i < ${#cases[@]}; i += 2)); do
    tc="$workdir/tc/${cases[i]}"
    mkdir -p "$tc"
    for legacy in true false; do
      export MOCK_TOOLCHAIN="$tc" MOCK_TOOLCHAIN_REASON="${cases[i + 1]}" \
        MOCK_RUSTUP_LEGACY="$legacy"
      run_action
      [ "$status" -eq 0 ]
      [ "$(output_value toolchain)" = "$tc" ]
      [ "$(output_value toolchain_kind)" = path ]
      rm "$GITHUB_OUTPUT"
    done
  done

  local -a channel_reasons=(default
    "overridden by environment variable RUSTUP_TOOLCHAIN"
    "overridden by '/w (default)/rust-toolchain.toml'")
  local reason
  for reason in "${channel_reasons[@]}"; do
    export MOCK_TOOLCHAIN=1.85.0-x86_64-unknown-linux-gnu \
      MOCK_TOOLCHAIN_REASON="$reason" MOCK_RUSTUP_LEGACY=true
    run_action
    [ "$status" -eq 0 ]
    [ "$(output_value toolchain)" = 1.85.0-x86_64-unknown-linux-gnu ]
    [ "$(output_value toolchain_kind)" = channel ]
    rm "$GITHUB_OUTPUT"
  done
}

@test "works without rustup, unpinned, reporting kind 'none'" {
  rm "$workdir/bin/rustup"
  run_action

  [ "$status" -eq 0 ]
  [ "$(output_value toolchain_kind)" = none ]
  [ "$(output_value toolchain)" = "" ]
  [ "$(env_field 3)" = unset ]
  grep -q 'no rustup' "$GITHUB_STEP_SUMMARY"
}

@test "refuses the toolchain input without rustup" {
  rm "$workdir/bin/rustup"
  export INPUT_TOOLCHAIN=stable
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"toolchain needs rustup on PATH"* ]]
  [ ! -s "$MOCK_CARGO_LOG" ]
}

@test "fails when rustup cannot name a usable toolchain" {
  export MOCK_FAIL=show
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"rustup could not name the active toolchain"* ]]

  export MOCK_FAIL="" MOCK_TOOLCHAIN='stable;id'
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"rustup reported an unexpected toolchain name"* ]]
  [ ! -s "$MOCK_CARGO_LOG" ]
}

@test "refuses unexpected cargo and rustc versions and host triples" {
  export MOCK_CARGO_VERSION='1.99.0|x'
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"cargo --version reported an unexpected version"* ]]

  export MOCK_CARGO_VERSION=1.99.0 MOCK_RUSTC_VERSION=banana
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"rustc -vV reported an unexpected release"* ]]

  export MOCK_RUSTC_VERSION=1.99.0 MOCK_HOST='x86_64 linux'
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"rustc -vV reported an unexpected host triple"* ]]
  [ -z "$(build_call)" ]
}

### Toolchain components and targets ###

readonly install_call="toolchain install 1.90.0 --profile minimal --no-self-update"

@test "installs requested components and targets in one rustup call" {
  export INPUT_TOOLCHAIN=1.90.0 INPUT_TOOLCHAIN_COMPONENTS='clippy, rustfmt' \
    INPUT_TOOLCHAIN_TARGETS='wasm32-unknown-unknown x86_64-unknown-linux-musl'
  printf '%s\n' 'source "$MOCK_FIXTURES/record-env.sh"' 'record_env setup' \
    > "$project/setup.sh"
  export INPUT_SETUP_SCRIPT=setup.sh
  run_action

  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_RUSTUP_LOG")" = \
    "$install_call --component clippy,rustfmt --target wasm32-unknown-unknown,x86_64-unknown-linux-musl" ]
  # First, pinned, and ahead of the setup script and every cargo call.
  [ "$(head -2 "$MOCK_CARGO_ENV" | cut -d'|' -f1,3 | tr '\n' ' ')" \
    = "toolchain|1.90.0 setup|1.90.0 " ]
  grep -Fq '| Components and targets | ✅ components <code>clippy rustfmt</code>, targets <code>wasm32-unknown-unknown x86_64-unknown-linux-musl</code> |' \
    "$GITHUB_STEP_SUMMARY"
}

@test "splits the lists on commas, spaces and newlines" {
  export INPUT_TOOLCHAIN_COMPONENTS=$'clippy,,rustfmt\n  llvm-tools,' \
    INPUT_TOOLCHAIN_TARGETS=$'\twasm32-wasip1 ,'
  run_action

  [ "$status" -eq 0 ]
  # No toolchain input: the channel the project selects gets them.
  [ "$(sed -n 2p "$MOCK_RUSTUP_LOG")" = \
    "toolchain install stable-x86_64-unknown-linux-gnu --profile minimal --no-self-update --component clippy,rustfmt,llvm-tools --target wasm32-wasip1" ]
  [ "$(wc -l < "$MOCK_RUSTUP_LOG")" -eq 2 ]

  : > "$MOCK_RUSTUP_LOG"
  export INPUT_TOOLCHAIN_COMPONENTS='' INPUT_TOOLCHAIN_TARGETS=wasm32-wasip1
  run_action
  [ "$status" -eq 0 ]
  [ "$(sed -n 2p "$MOCK_RUSTUP_LOG")" = \
    "toolchain install stable-x86_64-unknown-linux-gnu --profile minimal --no-self-update --target wasm32-wasip1" ]
  grep -Fq '| Components and targets | ✅ targets <code>wasm32-wasip1</code> |' \
    "$GITHUB_STEP_SUMMARY"
}

@test "installs a toolchain named by the input only when it is missing" {
  export CARGO_REGISTRY_TOKEN=secret-1 ACTIONS_RUNTIME_TOKEN=secret-2 \
    CARGO_REGISTRIES_PRIVATE_TOKEN=secret-3
  export INPUT_TOOLCHAIN=1.90.0 MOCK_MISSING=1.90.0
  run_action

  [ "$status" -eq 0 ]
  [ "$(tr '\n' '|' < "$MOCK_RUSTUP_LOG")" \
    = "which --toolchain 1.90.0 rustc|$install_call|" ]
  [ "$(env_field 4)" = "" ]
  # Nothing requested, so no summary row.
  run ! grep -q 'Components and targets' "$GITHUB_STEP_SUMMARY"
}

@test "fails at 'Install toolchain' when rustup cannot install" {
  export INPUT_TOOLCHAIN=1.90.0 INPUT_TOOLCHAIN_COMPONENTS=clippy MOCK_FAIL=install
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"rustup could not install toolchain 1.90.0 with the requested toolchain_components and toolchain_targets"* ]]
  [ ! -s "$MOCK_CARGO_LOG" ]
  grep -q 'Failed at Install toolchain' "$GITHUB_STEP_SUMMARY"
  grep -Fq '| Components and targets | ❌ rustup could not install them |' \
    "$GITHUB_STEP_SUMMARY"

  # A toolchain input alone fails the same way when the install does.
  export INPUT_TOOLCHAIN_COMPONENTS='' MOCK_MISSING=1.90.0
  run_action
  [ "$status" -eq 1 ]
  grep -q 'Failed at Install toolchain' "$GITHUB_STEP_SUMMARY"
  [ ! -s "$MOCK_CARGO_LOG" ]
}

@test "rejects malformed component and target names without echoing them" {
  local bad
  for bad in '-Zevil' '.hidden' 'clip$py' 'a/b' '--toolchain=x' 'x::warning' 'é'; do
    export INPUT_TOOLCHAIN_COMPONENTS="clippy $bad" INPUT_TOOLCHAIN_TARGETS=''
    run_action
    [ "$status" -eq 1 ]
    [[ "$output" == *"toolchain_components must list rustup component names"* ]]
    [[ "$output" != *"$bad"* ]]

    export INPUT_TOOLCHAIN_COMPONENTS='' INPUT_TOOLCHAIN_TARGETS="$bad,wasm32-wasip1"
    run_action
    [ "$status" -eq 1 ]
    [[ "$output" == *"toolchain_targets must list target triples"* ]]
    [[ "$output" != *"$bad"* ]]
  done
  assert_no_cargo
}

@test "ignores components and targets for a path toolchain, with a warning" {
  export MOCK_TOOLCHAIN=/opt/rust INPUT_TOOLCHAIN_COMPONENTS=clippy \
    INPUT_TOOLCHAIN_TARGETS=wasm32-wasip1
  run_action

  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_RUSTUP_LOG")" = "show active-toolchain --verbose" ]
  [[ "$output" == *"::warning title=rust-build::toolchain_components and toolchain_targets are ignored for a path toolchain"* ]]
  grep -Fq '| Components and targets | ⚠️ Ignored for a path toolchain |' \
    "$GITHUB_STEP_SUMMARY"
}

@test "refuses components or targets without rustup" {
  rm "$workdir/bin/rustup"
  local input
  for input in INPUT_TOOLCHAIN_COMPONENTS INPUT_TOOLCHAIN_TARGETS; do
    unset INPUT_TOOLCHAIN_COMPONENTS INPUT_TOOLCHAIN_TARGETS
    export "$input=x"
    run_action
    [ "$status" -eq 1 ]
    [[ "$output" == *"toolchain_components and toolchain_targets need rustup on PATH"* ]]
    grep -Fq '| Components and targets | ❌ Needs rustup |' "$GITHUB_STEP_SUMMARY"
  done
  [ ! -s "$MOCK_CARGO_LOG" ]
}

@test "does not add the build target again when toolchain_targets lists it" {
  export INPUT_TOOLCHAIN=1.90.0 INPUT_TARGET=aarch64-unknown-linux-musl \
    INPUT_TOOLCHAIN_TARGETS='wasm32-wasip1,aarch64-unknown-linux-musl'
  run_action

  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_RUSTUP_LOG")" = \
    "$install_call --target wasm32-wasip1,aarch64-unknown-linux-musl" ]
  [ "$(build_call)" = "$base_build --target=aarch64-unknown-linux-musl --workspace" ]

  # A different list leaves the build target to 'rustup target add'.
  : > "$MOCK_RUSTUP_LOG"
  export INPUT_TOOLCHAIN_TARGETS='aarch64-unknown-linux-musl-x'
  run_action
  [ "$status" -eq 0 ]
  [ "$(sed -n 2p "$MOCK_RUSTUP_LOG")" \
    = "target add --toolchain 1.90.0 aarch64-unknown-linux-musl" ]
}

### Credential scrubbing ###

@test "withholds credentials and runner command files from every child" {
  export CARGO_REGISTRY_TOKEN=secret-1 CARGO_REGISTRIES_CRATES_IO_TOKEN=secret-2 \
    ACTIONS_ID_TOKEN_REQUEST_TOKEN=secret-3 \
    ACTIONS_ID_TOKEN_REQUEST_URL=https://example.invalid/secret-4 \
    ACTIONS_RUNTIME_TOKEN=secret-5 CARGO_REGISTRIES_PRIVATE_TOKEN=secret-6 \
    CARGO_REGISTRIES_X_TOKEN_TOKEN=secret-7 \
    CARGO_REGISTRIES_PRIVATE_INDEX=sparse+https://example.invalid/index/ \
    GITHUB_ENV="$workdir/env file" GITHUB_PATH="$workdir/path file" \
    GITHUB_STATE="$workdir/state file"
  printf '%s\n' 'source "$MOCK_FIXTURES/record-env.sh"' 'record_env setup' \
    > "$project/setup.sh"
  export INPUT_SETUP_SCRIPT=setup.sh INPUT_TOOLCHAIN_COMPONENTS=clippy
  export INPUT_BINARIES=true INPUT_PACKAGE_CRATES=true INPUT_TARGET=aarch64-unknown-linux-gnu
  export MOCK_FAIL=none
  run_action

  [ "$status" -eq 0 ]
  # Each child saw the registry index setting and nothing else watched.
  [ "$(env_field 4)" = CARGO_REGISTRIES_PRIVATE_INDEX ]
  # Every kind of call was checked: rustup, rustc, setup_script and
  # each cargo stage.
  [ "$(env_field 1 | tr '\n' ' ')" = "--version build metadata package rustc setup show target toolchain " ]
  # The action itself still wrote its outputs and summary.
  [ "$(output_value cargo_version)" = 1.99.0 ]
  grep -q '## 🦀' "$GITHUB_STEP_SUMMARY"
}

@test "keeps child processes from setting outputs or later steps' state" {
  export GITHUB_ENV="$workdir/env file" GITHUB_PATH="$workdir/path file" \
    GITHUB_STATE="$workdir/state file" OUTPUT_FILE="$GITHUB_OUTPUT"
  printf '%s\n' \
    '[ -z "${GITHUB_OUTPUT+x}${GITHUB_ENV+x}${GITHUB_PATH+x}${GITHUB_STATE+x}${GITHUB_STEP_SUMMARY+x}" ] || exit 7' \
    'printf "%s\n" "artefact_path=*" upload=true "artefact_name=x" >> "$OUTPUT_FILE"' \
    > "$project/setup.sh"
  export INPUT_SETUP_SCRIPT=setup.sh INPUT_BINARIES=true INPUT_ARTEFACT_UPLOAD=false
  run_action

  [ "$status" -eq 0 ]
  [ "$(output_value artefact_path)" = "my project/dist" ]
  [ "$(output_value artefact_name)" = rust-build-x86_64-unknown-linux-gnu ]
  [ "$(output_value upload)" = false ]
}

@test "discards outputs a child forges before the action fails" {
  export OUTPUT_FILE="$GITHUB_OUTPUT" INPUT_SETUP_SCRIPT=setup.sh
  local forge='printf "%s\n" "artefact_path=*" upload=true toolchain=forged "binaries_json<<EOF" >> "$OUTPUT_FILE"'
  printf '%s\n' "$forge" 'exit 3' > "$project/setup.sh"
  run_action
  [ "$status" -ne 0 ]
  [ -z "$(build_call)" ]
  [ "$(output_value artefact_path)" = "my project/dist" ]
  run ! grep -q -e forged -e '<<' -e '^upload=' -e '^artefact_path=\*' "$GITHUB_OUTPUT"

  # A child that forges and succeeds, then a later stage that fails.
  : > "$GITHUB_OUTPUT"
  printf '%s\n' "$forge" > "$project/setup.sh"
  export MOCK_FAIL=build
  run_action
  [ "$status" -ne 0 ]
  [ "$(output_value toolchain)" = stable-x86_64-unknown-linux-gnu ]
  run ! grep -q -e forged -e '<<' -e '^upload=' -e '^artefact_path=\*' "$GITHUB_OUTPUT"
}

### Lockfile ###

@test "uses the committed lockfile with --locked everywhere" {
  run_action

  [ "$status" -eq 0 ]
  run ! grep -q generate-lockfile "$MOCK_CARGO_LOG"
  [ "$(grep -c -- '--locked' "$MOCK_CARGO_LOG")" -eq 2 ]
  grep -q '| Lockfile | ✅ Present |' "$GITHUB_STEP_SUMMARY"
}

@test "generates a missing lockfile with a warning, then builds --locked" {
  rm "$project/Cargo.lock"
  run_action

  [ "$status" -eq 0 ]
  [ "$(sed -n 3p "$MOCK_CARGO_LOG")" \
    = "generate-lockfile --manifest-path @ROOT/Cargo.toml" ]
  [ "$(build_call)" = "$default_build --workspace" ]
  [[ "$output" == *"::warning title=rust-build::Cargo.lock is missing; generated one"* ]]
  grep -q 'Generated for this build' "$GITHUB_STEP_SUMMARY"
}

@test "fails when generate-lockfile leaves no lockfile" {
  rm "$project/Cargo.lock"
  export MOCK_NO_LOCKFILE_WRITE=true
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"cargo generate-lockfile did not create Cargo.lock"* ]]
  [ -z "$(build_call)" ]
}

@test "lockfile_required fails on a missing lockfile before building" {
  rm "$project/Cargo.lock"
  export INPUT_LOCKFILE_REQUIRED=true
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"Cargo.lock is missing and lockfile_required is 'true'"* ]]
  run ! grep -Eq '^(generate-lockfile|build)' "$MOCK_CARGO_LOG"
  grep -q '| Lockfile | ❌ Missing |' "$GITHUB_STEP_SUMMARY"
}

@test "looks for the lockfile at the workspace root, not beside a member" {
  export INPUT_MANIFEST_PATH=crates/lib-a/Cargo.toml INPUT_LOCKFILE_REQUIRED=true
  run_action

  [ "$status" -eq 0 ]
  [ ! -e "$project/crates/lib-a/Cargo.lock" ]
}

### Project selection ###

@test "passes packages as --package flags in place of --workspace" {
  for flag in true false; do
    export INPUT_WORKSPACE="$flag" INPUT_PACKAGES=$'lib-a\n  tool'
    run_action

    [ "$status" -eq 0 ]
    [ "$(build_call)" = "$default_build --package=lib-a --package=tool" ]
    grep -q '| Packages | lib-a, tool |' "$GITHUB_STEP_SUMMARY"
    rm "$MOCK_CARGO_LOG" "$GITHUB_STEP_SUMMARY"
  done
}

@test "refuses packages that are not workspace members" {
  export INPUT_PACKAGES="lib-a serde"
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"packages names serde, which is not a member of this workspace"* ]]
  [ -z "$(build_call)" ]
}

@test "passes workspace and exclude through" {
  export INPUT_WORKSPACE=true INPUT_EXCLUDE="tool lib-a"
  run_action

  [ "$status" -eq 0 ]
  [ "$(build_call)" = "$default_build --workspace --exclude=tool --exclude=lib-a" ]
  grep -q '| Packages | Workspace: app |' "$GITHUB_STEP_SUMMARY"
}

@test "joins features with commas and passes the feature switches" {
  export INPUT_FEATURES="serde, json  derive/full" INPUT_ALL_FEATURES=true \
    INPUT_NO_DEFAULT_FEATURES=true
  run_action

  [ "$status" -eq 0 ]
  [ "$(build_call)" = "$default_build --workspace --features=serde,json,derive/full --all-features --no-default-features" ]
}

@test "selects a member's package when manifest_path names it" {
  export INPUT_MANIFEST_PATH=crates/tool/Cargo.toml INPUT_BINARIES=true \
    INPUT_WORKSPACE=false
  run_action

  [ "$status" -eq 0 ]
  [ "$(output_value rust_version)" = "" ]
  [ "$(output_value binaries_json | jq -r '.[].name')" = tool ]
}

@test "selects every member of a virtual workspace, with or without workspace" {
  export MOCK_VIRTUAL=true INPUT_BINARIES=true
  run_action

  [ "$status" -eq 0 ]
  [ "$(output_value rust_version)" = "" ]
  [ "$(build_call)" = "$default_build --workspace" ]
  grep -q '| Packages | Workspace: lib-a, tool |' "$GITHUB_STEP_SUMMARY"

  rm -rf "$MOCK_CARGO_LOG" "$GITHUB_STEP_SUMMARY" "$project/dist"
  export INPUT_WORKSPACE=false
  run_action

  [ "$status" -eq 0 ]
  [ "$(build_call)" = "$default_build" ]
  grep -q '| Packages | lib-a, tool |' "$GITHUB_STEP_SUMMARY"
}

@test "needs Cargo 1.71 metadata only for workspace false" {
  printf '%s\n' 'del(.workspace_default_members)' > "$workdir/filter.jq"
  export MOCK_METADATA_FILTER_FILE="$workdir/filter.jq" INPUT_WORKSPACE=false
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"workspace 'false' needs Cargo 1.71 or later; set workspace to 'true' or name the packages"* ]]
  [ -z "$(build_call)" ]

  export INPUT_WORKSPACE=true
  run_action
  [ "$status" -eq 0 ]
  [ "$(build_call)" = "$default_build --workspace" ]

  rm -f "$MOCK_CARGO_LOG"
  export INPUT_WORKSPACE=false INPUT_PACKAGES=app
  run_action
  [ "$status" -eq 0 ]
  [ "$(build_call)" = "$default_build --package=app" ]
}

@test "passes cargo_args word by word, never through a shell" {
  touch "$project/glob-match"
  export INPUT_CARGO_ARGS=$'--config \'x=1\'\t-v * $(touch${IFS}pwned) --jobs=2 -vj2 -Zunstable-options -Cpre'
  run_action

  [ "$status" -eq 0 ]
  [ "$(build_call)" = "$default_build --workspace --config 'x=1' -v * \$(touch\${IFS}pwned) --jobs=2 -vj2 -Zunstable-options -Cpre" ]
  [ ! -e "$project/pwned" ]
}

@test "applies the profile input" {
  export INPUT_PROFILE=dist-lto
  run_action

  [ "$status" -eq 0 ]
  [ "$(build_call)" = "${default_build/release/dist-lto} --workspace" ]
  [ "$(output_value profile)" = dist-lto ]
}

### Target ###

@test "adds a non-host target to the resolved toolchain and builds for it" {
  export INPUT_TARGET=aarch64-unknown-linux-musl
  run_action

  [ "$status" -eq 0 ]
  [ "$(sed -n 2p "$MOCK_RUSTUP_LOG")" \
    = "target add --toolchain stable-x86_64-unknown-linux-gnu aarch64-unknown-linux-musl" ]
  [ "$(build_call)" = "$base_build --target=aarch64-unknown-linux-musl --workspace" ]
  [ "$(output_value target)" = aarch64-unknown-linux-musl ]
  [ "$(output_value artefact_name)" = rust-build-aarch64-unknown-linux-musl ]
}

@test "names the host target explicitly, so Cargo configuration cannot move it" {
  export INPUT_CARGO_ARGS='--config build.target="wasm32-unknown-unknown"'
  run_action

  [ "$status" -eq 0 ]
  [ "$(build_call)" = "$default_build --workspace --config build.target=\"wasm32-unknown-unknown\"" ]
  [ "$(output_value target)" = x86_64-unknown-linux-gnu ]
}

@test "builds with --target but adds nothing when the target is the host" {
  export INPUT_TARGET=x86_64-unknown-linux-gnu
  run_action

  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_RUSTUP_LOG")" = "show active-toolchain --verbose" ]
  [ "$(build_call)" = "$default_build --workspace" ]
}

@test "fails at 'Add target' when rustup cannot add the target" {
  export INPUT_TARGET=thumbv8m.main-none-eabi MOCK_FAIL=target
  run_action

  [ "$status" -eq 1 ]
  [ -z "$(build_call)" ]
  grep -q 'Failed at Add target' "$GITHUB_STEP_SUMMARY"
}

@test "warns that a path or rustup-less toolchain needs the target installed" {
  export INPUT_TARGET=wasm32-unknown-unknown MOCK_TOOLCHAIN=/opt/rust
  run_action

  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_RUSTUP_LOG")" = "show active-toolchain --verbose" ]
  [[ "$output" == *"rustup cannot add target wasm32-unknown-unknown to a path toolchain"* ]]
  [ "$(build_call)" = "$base_build --target=wasm32-unknown-unknown --workspace" ]
}

@test "an explicit artefact_name replaces the default" {
  export INPUT_ARTEFACT_NAME=my-build_1.0
  run_action

  [ "$status" -eq 0 ]
  [ "$(output_value artefact_name)" = my-build_1.0 ]
}

### Binaries ###

@test "collects the selected package's binaries with a SHA256SUMS file" {
  export INPUT_BINARIES=true INPUT_TARGET=aarch64-unknown-linux-gnu \
    MOCK_SKIP_BINS=app-extra INPUT_WORKSPACE=false
  run_action

  [ "$status" -eq 0 ]
  [ "$(ls -A "$project/dist" | tr '\n' ' ')" = "SHA256SUMS app " ]
  [ "$(cat "$project/dist/app")" = "binary app" ]
  local digest
  digest="$(sha256_text $'binary app\n')"
  [ "$(cat "$project/dist/SHA256SUMS")" = "$digest  app" ]
  [ "$(output_value binaries_json)" \
    = "[{\"name\":\"app\",\"path\":\"app\",\"sha256\":\"$digest\"}]" ]
  [ "$(output_value upload)" = true ]
  [[ "$output" == *"::warning title=rust-build::binary app-extra of package app was not built"* ]]
  grep -Fq "| <code>my project/dist/app</code> | 11 B | <code>$digest</code> |" \
    "$GITHUB_STEP_SUMMARY"
}

@test "SHA256SUMS verifies with the standard tools" {
  export INPUT_BINARIES=true INPUT_WORKSPACE=true
  run_action

  [ "$status" -eq 0 ]
  cd "$project/dist"
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum -c SHA256SUMS
  else
    shasum -a 256 -c SHA256SUMS
  fi
  [ "$(cut -d' ' -f3 SHA256SUMS | tr '\n' ' ')" = "app app-extra tool " ]
  [ "$(output_value binaries_json | jq -r 'map(.name) | join(" ")')" = "app app-extra tool" ]
}

@test "ignores build scripts, test harnesses and unselected packages" {
  printf '%s\n' "{\"reason\":\"compiler-artifact\",\"package_id\":\"path+file://$project/crates/tool#tool@0.0.1\",\"target\":{\"name\":\"tool\",\"kind\":[\"bin\"]},\"profile\":{\"test\":false},\"executable\":\"$project/target/release/tool\"}" \
    > "$workdir/extra.jsonl"
  mkdir -p "$project/target/release"
  printf 'tool' > "$project/target/release/tool"
  export INPUT_BINARIES=true INPUT_PACKAGES=app MOCK_EXTRA_MESSAGES="$workdir/extra.jsonl"
  run_action

  [ "$status" -eq 0 ]
  [ "$(ls -A "$project/dist" | tr '\n' ' ')" = "SHA256SUMS app app-extra " ]
}

@test "finds binaries wherever Cargo put them" {
  export INPUT_BINARIES=true INPUT_PROFILE=dev MOCK_TARGET_DIR="$workdir/elsewhere"
  run_action

  [ "$status" -eq 0 ]
  [ "$(cat "$project/dist/app")" = "binary app" ]
}

@test "collects binaries from a target directory with a backslash or tab" {
  export INPUT_BINARIES=true MOCK_TARGET_DIR="$workdir/back\\slash"$'\ttab'
  run_action

  [ "$status" -eq 0 ]
  [ -f "$MOCK_TARGET_DIR/x86_64-unknown-linux-gnu/release/app" ]
  [ "$(cat "$project/dist/app")" = "binary app" ]
}

@test "warns for an unbuilt bin even when another package built that name" {
  printf '%s\n' "{\"reason\":\"compiler-artifact\",\"package_id\":\"path+file://$project/crates/tool#tool@0.0.1\",\"target\":{\"name\":\"app-extra\",\"kind\":[\"bin\"]},\"profile\":{\"test\":false},\"executable\":\"$project/target/release/other/app-extra\"}" \
    > "$workdir/extra.jsonl"
  mkdir -p "$project/target/release/other"
  printf 'tool app-extra' > "$project/target/release/other/app-extra"
  export INPUT_BINARIES=true MOCK_SKIP_BINS=app-extra \
    MOCK_EXTRA_MESSAGES="$workdir/extra.jsonl"
  run_action

  [ "$status" -eq 0 ]
  [ "$(cat "$project/dist/app-extra")" = "tool app-extra" ]
  [[ "$output" == *"::warning title=rust-build::binary app-extra of package app was not built"* ]]
  [[ "$output" != *"of package tool was not built"* ]]
}

@test "warns and uploads nothing when no binaries were built" {
  export INPUT_BINARIES=true INPUT_PACKAGES=lib-a
  run_action

  [ "$status" -eq 0 ]
  [[ "$output" == *"binaries is 'true', but the build produced no binaries"* ]]
  [ "$(output_value binaries_json)" = "[]" ]
  [ "$(output_value upload)" = false ]
  [ ! -e "$project/dist/SHA256SUMS" ]
}

@test "refuses two binaries with one file name" {
  printf '%s\n' "{\"reason\":\"compiler-artifact\",\"package_id\":\"path+file://$project/crates/tool#tool@0.0.1\",\"target\":{\"name\":\"app\",\"kind\":[\"bin\"]},\"profile\":{\"test\":false},\"executable\":\"$project/target/release/other/app\"}" \
    > "$workdir/extra.jsonl"
  mkdir -p "$project/target/release/other"
  printf 'other' > "$project/target/release/other/app"
  export INPUT_BINARIES=true INPUT_WORKSPACE=true MOCK_EXTRA_MESSAGES="$workdir/extra.jsonl"
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"two selected packages build a binary named app"* ]]
}

@test "refuses binary names and files Cargo should never report" {
  local name target
  for target in 'x:bad|name' 'x:.hidden' 'bad name:x'; do
    name="${target#*:}"
    printf '%s\n' "{\"reason\":\"compiler-artifact\",\"package_id\":\"path+file://$project#app@1.2.3\",\"target\":{\"name\":\"${target%%:*}\",\"kind\":[\"bin\"]},\"profile\":{\"test\":false},\"executable\":\"$project/target/$name\"}" \
      > "$workdir/extra.jsonl"
    export INPUT_BINARIES=true MOCK_EXTRA_MESSAGES="$workdir/extra.jsonl"
    rm -rf "$project/dist"
    run_action
    [ "$status" -eq 1 ]
    [[ "$output" == *"cargo reported an unexpected binary name"* ]]
  done

  printf '%s\n' "{\"reason\":\"compiler-artifact\",\"package_id\":\"path+file://$project#app@1.2.3\",\"target\":{\"name\":\"ghost\",\"kind\":[\"bin\"]},\"profile\":{\"test\":false},\"executable\":\"$project/target/ghost\"}" \
    > "$workdir/extra.jsonl"
  rm -rf "$project/dist"
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"cargo reported binary ghost, but its file is missing"* ]]
}

@test "refuses a binary named like the artefact's own files" {
  local name crates
  for name in SHA256SUMS crates sha256sums Crates; do
    for crates in false true; do
      mkdir -p "$project/target/release/other"
      printf 'bin %s' "$name" > "$project/target/release/other/$name"
      printf '%s\n' "{\"reason\":\"compiler-artifact\",\"package_id\":\"path+file://$project#app@1.2.3\",\"target\":{\"name\":\"$name\",\"kind\":[\"bin\"]},\"profile\":{\"test\":false},\"executable\":\"$project/target/release/other/$name\"}" \
        > "$workdir/extra.jsonl"
      export INPUT_BINARIES=true INPUT_PACKAGE_CRATES="$crates" \
        MOCK_EXTRA_MESSAGES="$workdir/extra.jsonl" MOCK_ARTEFACT_DIR="$project/dist"
      rm -rf "$project/dist"
      run_action
      [ "$status" -eq 1 ]
      [[ "$output" == *"binary $name would collide with the artefact's"* ]]
      [ "$(output_value upload)" = "" ]
    done
  done
}

@test "binaries false leaves artefact_path alone" {
  run_action

  [ "$status" -eq 0 ]
  [ ! -e "$project/dist" ]
  grep -q '| Binaries | ➖ Not requested |' "$GITHUB_STEP_SUMMARY"
}

### package_crates ###

@test "packages the selected crate and writes crates.json" {
  export INPUT_PACKAGE_CRATES=true MOCK_ARTEFACT_DIR="$project/dist" \
    INPUT_WORKSPACE=false
  run_action

  [ "$status" -eq 0 ]
  [ "$(package_call)" = "package --locked --manifest-path @ROOT/Cargo.toml --target=x86_64-unknown-linux-gnu --package=app" ]
  [ "$(cat "$project/dist/crates/app-1.2.3.crate")" = "crate app-1.2.3.crate" ]
  local digest
  digest="$(sha256_text $'crate app-1.2.3.crate\n')"
  local expected="[{\"name\":\"app\",\"version\":\"1.2.3\",\"file\":\"crates/app-1.2.3.crate\",\"sha256\":\"$digest\"}]"
  [ "$(output_value crates_json)" = "$expected" ]
  [ "$(jq -c . "$project/dist/crates.json")" = "$expected" ]
  [ "$(output_value upload)" = true ]
}

@test "packages a workspace, excluding unpublishable and excluded members" {
  export INPUT_PACKAGE_CRATES=true INPUT_WORKSPACE=true INPUT_EXCLUDE=lib-a \
    INPUT_FEATURES=fast INPUT_TARGET=aarch64-unknown-linux-gnu
  run_action

  [ "$status" -eq 0 ]
  [ "$(package_call)" = "package --locked --manifest-path @ROOT/Cargo.toml --target=aarch64-unknown-linux-gnu --workspace --exclude=lib-a --exclude=tool --features=fast" ]
  [ "$(output_value crates_json | jq -r 'map(.file) | join(" ")')" = "crates/app-1.2.3.crate" ]
  [[ "$output" == *"Not packaging tool: publish = false"* ]]
}

@test "packages named packages but skips publish = false ones" {
  export INPUT_PACKAGE_CRATES=true INPUT_PACKAGES="tool lib-a app"
  run_action

  [ "$status" -eq 0 ]
  [ "$(package_call)" = "package --locked --manifest-path @ROOT/Cargo.toml --target=x86_64-unknown-linux-gnu --package=app --package=lib-a" ]
  [ "$(output_value crates_json | jq -r 'map(.file) | join(" ")')" \
    = "crates/app-1.2.3.crate crates/lib-a-0.4.0.crate" ]
}

# Make 'app' depend through a path on package $1, of kind $2 (JSON),
# with version requirement $3.
app_depends_on() {
  printf '.packages |= map(if .name == "app" then .dependencies = [{name: "%s", kind: %s, req: "%s", path: "/r/%s"}] else . end)\n' \
    "$1" "$2" "$3" "$1" > "$workdir/filter.jq"
  export MOCK_METADATA_FILTER_FILE="$workdir/filter.jq"
}

@test "fails before building when Cargo < 1.90 would package dependent crates" {
  export INPUT_PACKAGE_CRATES=true MOCK_CARGO_VERSION=1.89.0
  local selection kind
  for selection in workspace packages; do
    for kind in null '"build"' '"dev"'; do
      if [ "$selection" = packages ]; then
        export INPUT_PACKAGES="lib-a app"
      fi
      app_depends_on lib-a "$kind" '^0.4.0'
      run_action
      [ "$status" -eq 1 ]
      [[ "$output" == *"package_crates needs Cargo 1.90 or later to package crates that depend on one another (app depends on lib-a)"* ]]
      [ -z "$(build_call)" ]
      grep -q 'Failed at Check packaging' "$GITHUB_STEP_SUMMARY"
      grep -q '| Crates | ❌ Needs Cargo 1.90 |' "$GITHUB_STEP_SUMMARY"
      : > "$MOCK_CARGO_LOG"
      : > "$GITHUB_STEP_SUMMARY"
    done
  done

  export MOCK_CARGO_VERSION=1.90.0
  run_action
  [ "$status" -eq 0 ]
  [ "$(package_call)" = "package --locked --manifest-path @ROOT/Cargo.toml --target=x86_64-unknown-linux-gnu --package=app --package=lib-a" ]
}

@test "packages several crates on Cargo < 1.90 when none needs another" {
  export INPUT_PACKAGE_CRATES=true MOCK_CARGO_VERSION=1.89.0
  # Independent crates, from the whole workspace.
  run_action
  [ "$status" -eq 0 ]
  [ "$(package_call)" = "package --locked --manifest-path @ROOT/Cargo.toml --target=x86_64-unknown-linux-gnu --workspace --exclude=tool" ]

  # Cargo drops a path dev-dependency without a version.
  : > "$MOCK_CARGO_LOG"
  rm -r "$project/dist"
  app_depends_on lib-a '"dev"' '*'
  run_action
  [ "$status" -eq 0 ]
  [ -n "$(package_call)" ]

  # The dependency is not packaged in the same run.
  : > "$MOCK_CARGO_LOG"
  rm -r "$project/dist"
  app_depends_on lib-a null '^0.4.0'
  export INPUT_PACKAGES=app
  run_action
  [ "$status" -eq 0 ]
  [ "$(package_call)" = "package --locked --manifest-path @ROOT/Cargo.toml --target=x86_64-unknown-linux-gnu --package=app" ]

  # A crate's dependency on itself fails on every Cargo release alike.
  : > "$MOCK_CARGO_LOG"
  rm -r "$project/dist"
  app_depends_on app '"dev"' '^1.2.3'
  export INPUT_PACKAGES="app lib-a"
  run_action
  [ "$status" -eq 0 ]
  [ -n "$(package_call)" ]

  # Nothing to package.
  : > "$MOCK_CARGO_LOG"
  rm -r "$project/dist"
  export INPUT_PACKAGE_CRATES=false INPUT_PACKAGES=""
  run_action
  [ "$status" -eq 0 ]
  [ -n "$(build_call)" ]
}

@test "explains a cargo package failure the Cargo < 1.90 check cannot foresee" {
  # Metadata shows version = "*" like a missing version; Cargo keeps it.
  export INPUT_PACKAGE_CRATES=true MOCK_CARGO_VERSION=1.89.0 MOCK_FAIL=package
  app_depends_on lib-a '"dev"' '*'
  local hint='Cargo 1.89.0 cannot package a crate together with another selected crate it depends on'
  run_action
  [ "$status" -eq 42 ]
  [ -n "$(build_call)" ]
  [[ "$output" == *"::warning title=rust-build::$hint"* ]]
  grep -q 'Failed at Package crates' "$GITHUB_STEP_SUMMARY"

  # No hint for a single crate, or on Cargo 1.90.
  export INPUT_PACKAGES=app
  run_action
  [ "$status" -eq 42 ]
  [[ "$output" != *"cannot package a crate together"* ]]

  export INPUT_PACKAGES="" MOCK_CARGO_VERSION=1.90.0
  run_action
  [ "$status" -eq 42 ]
  [[ "$output" != *"cannot package a crate together"* ]]
}

@test "packages before writing anything into artefact_path" {
  export INPUT_PACKAGE_CRATES=true INPUT_BINARIES=true \
    MOCK_ARTEFACT_DIR="$project/dist"
  run_action

  [ "$status" -eq 0 ]
  run ! grep -q 'package saw files' "$MOCK_CARGO_LOG"
  [ "$(ls -A "$project/dist" | tr '\n' ' ')" = "SHA256SUMS app app-extra crates crates.json tool " ]
}

@test "warns when no selected package is publishable" {
  export INPUT_PACKAGE_CRATES=true INPUT_PACKAGES=tool
  run_action

  [ "$status" -eq 0 ]
  [ -z "$(package_call)" ]
  [[ "$output" == *"package_crates is 'true', but no selected package is publishable"* ]]
  [ "$(output_value crates_json)" = "[]" ]
  [ "$(output_value upload)" = false ]
}

@test "fails when cargo package fails or leaves a crate out" {
  export INPUT_PACKAGE_CRATES=true MOCK_FAIL=package
  run_action
  [ "$status" -eq 42 ]
  grep -q 'Failed at Package crates' "$GITHUB_STEP_SUMMARY"

  export MOCK_FAIL="" MOCK_MISSING_CRATES=app-1.2.3.crate
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"cargo package did not produce app-1.2.3.crate"* ]]
}

@test "refuses unexpected package names and versions from cargo metadata" {
  printf '%s\n' '.packages[0].version = "1.0.0\nx"' > "$workdir/filter.jq"
  export MOCK_METADATA_FILTER_FILE="$workdir/filter.jq"
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"cargo metadata reported an unexpected package name or version"* ]]

  printf '%s\n' '.packages[0].name = "-x"' > "$workdir/filter.jq"
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"cargo metadata reported an unexpected package name or version"* ]]

  printf '%s\n' '.packages[0].targets |= map(if .kind == ["bin"] then .name = "-x" else . end)' \
    > "$workdir/filter.jq"
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"cargo metadata reported an unexpected package name or version"* ]]

  printf '%s\n' '.packages[0].rust_version = "1.80|x"' > "$workdir/filter.jq"
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"cargo metadata reported an unexpected rust-version"* ]]
  [ -z "$(build_call)" ]
}

### Upload decision ###

@test "artefact_upload false keeps the files but skips the upload" {
  export INPUT_BINARIES=true INPUT_ARTEFACT_UPLOAD=false
  run_action

  [ "$status" -eq 0 ]
  [ "$(output_value upload)" = false ]
  [ -f "$project/dist/app" ]
  grep -q 'Upload disabled' "$GITHUB_STEP_SUMMARY"
}

### Summary ###

@test "writes an org-style summary on success" {
  export INPUT_BINARIES=true MOCK_SKIP_BINS=app-extra
  run_action

  [ "$status" -eq 0 ]
  grep -q '^## 🦀 Rust Build$' "$GITHUB_STEP_SUMMARY"
  grep -q '^### ✅ Build passed$' "$GITHUB_STEP_SUMMARY"
  grep -q '^| Check | Result |$' "$GITHUB_STEP_SUMMARY"
  grep -Fq '| Target | <code>x86_64-unknown-linux-gnu</code> (host) |' "$GITHUB_STEP_SUMMARY"
  grep -Fq '| Artefact | 📦 <code>rust-build-x86_64-unknown-linux-gnu</code> from <code>my project/dist</code> |' \
    "$GITHUB_STEP_SUMMARY"
  grep -q '^### Warnings$' "$GITHUB_STEP_SUMMARY"
  grep -q '^- binary app-extra of package app was not built' "$GITHUB_STEP_SUMMARY"
}

@test "names the failed stage and the reason in the summary" {
  export MOCK_FAIL=build
  run_action

  [ "$status" -eq 42 ]
  grep -q '^### ❌ Failed at Build$' "$GITHUB_STEP_SUMMARY"
  grep -q 'Build failed with exit status 42' "$GITHUB_STEP_SUMMARY"
  grep -q '| Build | ❌ Failed |' "$GITHUB_STEP_SUMMARY"
  grep -q '| Binaries | ➖ Not requested |' "$GITHUB_STEP_SUMMARY"
}

@test "summarises a validation failure without echoing the value" {
  export INPUT_TARGET='<script>|x'
  run_action

  [ "$status" -eq 1 ]
  grep -q 'Failed at Check inputs' "$GITHUB_STEP_SUMMARY"
  run ! grep -q 'script' "$GITHUB_STEP_SUMMARY"
}

@test "summary false writes no summary" {
  export INPUT_SUMMARY=false
  run_action

  [ "$status" -eq 0 ]
  [ ! -s "$GITHUB_STEP_SUMMARY" ]
}

@test "a summary that cannot be written does not fail the build" {
  export GITHUB_STEP_SUMMARY="$workdir"
  run_action

  [ "$status" -eq 0 ]
  [[ "$output" == *"Could not write the Rust build job summary"* ]]
}

@test "escapes Markdown and HTML in summary cells" {
  run bash -c 'source "$1"; md_escape "$2"' _ "$repo_dir/scripts/summary.sh" \
    $'a|b<c>&d`e\\f\ng'
  [ "$output" = 'a&#124;b&lt;c&gt;&amp;d&#96;e&#92;f g' ]
}

@test "formats sizes for people" {
  run bash -c 'source "$1"; readable_size 512; echo; readable_size 4096;
    echo; readable_size 12897484' _ "$repo_dir/scripts/summary.sh"
  [ "$output" = $'512 B\n4.0 KiB\n12.3 MiB' ]
}

### Auditable ###

@test "builds binaries with cargo auditable, scrubbed and pinned" {
  export CARGO_REGISTRY_TOKEN=secret-1 ACTIONS_ID_TOKEN_REQUEST_TOKEN=secret-2 \
    CARGO_REGISTRIES_PRIVATE_TOKEN=secret-3 GITHUB_ENV="$workdir/env file"
  export INPUT_BINARIES=true INPUT_AUDITABLE=true MOCK_TOOLCHAIN=1.85.0
  run_action

  [ "$status" -eq 0 ]
  grep -qx 'auditable --version' "$MOCK_CARGO_LOG"
  [ "$(grep '^auditable build ' "$MOCK_CARGO_LOG")" \
    = "auditable $default_build --workspace" ]
  [ -z "$(build_call)" ]
  [ "$(env_field 4)" = "" ]
  [ "$(grep '^auditable|' "$MOCK_CARGO_ENV" | cut -d'|' -f3 | sort -u)" = 1.85.0 ]
  [ "$(output_value binaries_json | jq length)" -eq 3 ]
  grep -Fq '| Auditable | ✅ cargo-auditable 0.7.7 |' "$GITHUB_STEP_SUMMARY"

  export INPUT_CARGO_AUDITABLE_VERSION=0.6.9-rc.1 INPUT_ARTEFACT_PATH=dist2
  run_action
  [ "$status" -eq 0 ]
  grep -Fq '| Auditable | ✅ cargo-auditable 0.6.9-rc.1 |' "$GITHUB_STEP_SUMMARY"
}

@test "warns that auditable has no effect without binaries" {
  export INPUT_AUDITABLE=true INPUT_PACKAGE_CRATES=true
  run_action

  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning title=rust-build::auditable has no effect with binaries set to 'false'"* ]]
  [ "$(build_call)" = "$default_build --workspace" ]
  run ! grep -q '^auditable' "$MOCK_CARGO_LOG"
  grep -Fq '| Auditable | ⚠️ No effect without binaries |' "$GITHUB_STEP_SUMMARY"
}

@test "leaves the build and summary alone when auditable is 'false'" {
  export INPUT_BINARIES=true
  run_action

  [ "$status" -eq 0 ]
  [ "$(build_call)" = "$default_build --workspace" ]
  run ! grep -q '^auditable' "$MOCK_CARGO_LOG"
  run ! grep -q '| Auditable |' "$GITHUB_STEP_SUMMARY"
}

@test "rejects invalid auditable and cargo_auditable_version without echoing them" {
  local bad
  for bad in True yes 1 ''; do
    export INPUT_AUDITABLE="$bad"
    run_action
    [ "$status" -eq 1 ]
    [[ "$output" == *"auditable must be 'true' or 'false'"* ]]
  done
  export INPUT_AUDITABLE=true INPUT_BINARIES=true
  for bad in latest 1.2 v0.7.7 '0.7.7,cargo-binstall' '0.7.7 x' '0.7.7@1' \
    '0.7.7::warning' ''; do
    export INPUT_CARGO_AUDITABLE_VERSION="$bad"
    run_action
    [ "$status" -eq 1 ]
    [[ "$output" == *"cargo_auditable_version must be a release version such as 0.7.7"* ]]
    [ -z "$bad" ] || [[ "$output" != *"$bad"* ]]
  done
  assert_no_cargo
}

@test "fails at 'Check cargo-auditable' when it is not installed" {
  export INPUT_BINARIES=true INPUT_AUDITABLE=true INSTALL_OUTCOME=failure
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"taiki-e/install-action could not install cargo-auditable 0.7.7"* ]]
  grep -q 'Failed at Check cargo-auditable' "$GITHUB_STEP_SUMMARY"
  grep -Fq '| Auditable | ❌ Not installed |' "$GITHUB_STEP_SUMMARY"
  run ! grep -Eq '^(auditable )?build' "$MOCK_CARGO_LOG"

  export INSTALL_OUTCOME=success MOCK_NO_AUDITABLE=true
  : > "$MOCK_CARGO_LOG"
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"Cargo cannot find cargo-auditable; it must be on PATH"* ]]
  grep -q 'Failed at Check cargo-auditable' "$GITHUB_STEP_SUMMARY"
  run ! grep -Eq '^(auditable )?build' "$MOCK_CARGO_LOG"
}

@test "select-tools.sh names cargo-auditable only for an auditable binary build" {
  local selector="$repo_dir/scripts/select-tools.sh" case expected
  while IFS='|' read -r case expected; do
    read -r INPUT_AUDITABLE INPUT_BINARIES INPUT_CARGO_AUDITABLE_VERSION <<< "$case"
    export INPUT_AUDITABLE INPUT_BINARIES INPUT_CARGO_AUDITABLE_VERSION
    : > "$GITHUB_OUTPUT"
    run "$BASH" "$selector"
    [ "$status" -eq 0 ]
    [ "$(cat "$GITHUB_OUTPUT")" = "tools=$expected" ]
  done <<'EOF'
true true 0.7.7|cargo-auditable@0.7.7
true true 0.6.9-rc.1|cargo-auditable@0.6.9-rc.1
true false 0.7.7|
false true 0.7.7|
True true 0.7.7|
true TRUE 0.7.7|
true true latest|
true true 0.7.7,cargo-binstall|
EOF
}

@test "select-tools.sh and rust-build.sh accept the same versions" {
  local version selected
  export INPUT_AUDITABLE=true INPUT_BINARIES=true
  for version in 0.7.7 10.20.30 0.7.7-rc.1 0.7.7+b.2 0.7 0.7.7. v0.7.7 \
    0.7.7-rc_1 0.7.7@x '0.7.7 ' latest; do
    export INPUT_CARGO_AUDITABLE_VERSION="$version"
    : > "$GITHUB_OUTPUT"
    "$BASH" "$repo_dir/scripts/select-tools.sh"
    selected="$(cat "$GITHUB_OUTPUT")"
    run_action
    if [ "$selected" = "tools=" ]; then
      [[ "$output" == *"cargo_auditable_version must be"* ]]
    else
      [[ "$output" != *"cargo_auditable_version must be"* ]]
    fi
  done
}

### Names ending in a newline ###

# Command substitution strips trailing newlines, which would turn each
# of these into the name of an existing sibling.

@test "runs a setup_script whose name ends in a newline, not its sibling" {
  printf '%s\n' 'echo right > "$MOCK_ROOT/ran"' > "$project/setup.sh"$'\n'
  printf '%s\n' 'echo wrong > "$MOCK_ROOT/ran"' > "$project/setup.sh"
  export INPUT_SETUP_SCRIPT=$'setup.sh\n'
  run_action

  [ "$status" -eq 0 ]
  [ "$(cat "$project/ran")" = right ]
}

@test "resolves a directory whose name ends in a newline, not its sibling" {
  mkdir "$project/sub"$'\n' "$project/sub"
  printf '%s\n' 'echo right > "$MOCK_ROOT/ran"' > "$project/sub"$'\n/setup.sh'
  printf '%s\n' 'echo wrong > "$MOCK_ROOT/ran"' > "$project/sub/setup.sh"
  export INPUT_SETUP_SCRIPT=$'sub\n/setup.sh'
  run_action

  [ "$status" -eq 0 ]
  [ "$(cat "$project/ran")" = right ]
}

@test "refuses a manifest_path or path_prefix that ends in a newline" {
  cp "$project/Cargo.toml" "$project/Cargo.toml"$'\n'
  export INPUT_MANIFEST_PATH=$'Cargo.toml\n'
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"manifest_path must name a Cargo.toml file"* ]]

  unset INPUT_MANIFEST_PATH
  export INPUT_PATH_PREFIX=$'my project\n'
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"path_prefix is not a directory"* ]]
  assert_no_cargo
}

@test "refuses an artefact_path that ends in a newline" {
  export INPUT_BINARIES=true INPUT_ARTEFACT_PATH=$'dist\n'
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"artefact_path must resolve to a path without glob syntax"* ]]
  [ ! -e "$project/dist" ]
  assert_no_cargo
}

@test "fails the build when cargo_args stops Cargo before it builds" {
  local flag
  for flag in --help -h; do
    export INPUT_BINARIES=true INPUT_CARGO_ARGS="$flag"
    run_action
    [ "$status" -eq 1 ]
    [[ "$output" == *"Cargo exited without finishing a build; check cargo_args"* ]]
    grep -q 'Failed at Build' "$GITHUB_STEP_SUMMARY"
    grep -Fq '| Build | ❌ Failed |' "$GITHUB_STEP_SUMMARY"
    [ "$(output_value binaries_json)" = "" ]
  done
}

### action.yaml wiring ###

@test "action.yaml passes every input to the script through env" {
  local input upper
  while IFS= read -r input; do
    upper="$(printf '%s' "$input" | tr '[:lower:]' '[:upper:]')"
    grep -Fq "INPUT_$upper: \${{ inputs.$input }}" "$action_file"
    grep -q "INPUT_$upper" "$script"
  done < <(awk '/^inputs:/ { on = 1; next } /^outputs:/ { on = 0 }
    on && /^  [a-z_]+:$/ { sub(/:$/, ""); sub(/^  /, ""); print }' "$action_file")
  # No expression reaches a shell directly.
  run ! grep -E '^[[:space:]]+run:.*\$\{\{' "$action_file"
}

@test "action.yaml exposes exactly the outputs the script writes" {
  local name
  while IFS= read -r name; do
    grep -Fq "value: \${{ steps.build.outputs.$name }}" "$action_file"
    grep -Eq "set_output $name " "$script"
  done < <(awk '/^outputs:/ { on = 1; next } /^runs:/ { on = 0 }
    on && /^  [a-z_]+:$/ { sub(/:$/, ""); sub(/^  /, ""); print }' "$action_file")
}
