#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Build a Rust project with Cargo, then optionally gather its binaries
# and package its crates into one artefact directory.
#
# Inputs arrive as INPUT_* environment variables (see action.yaml).
# The stages run in this order, and the first failure ends the run:
#
#   Check inputs -> Resolve toolchain -> Install toolchain
#   -> Run setup script -> Inspect toolchain -> Add target -> Read metadata
#   -> Check lockfile -> Build -> Package crates -> Collect artefacts
#
# Cargo, rustc, rustup and the setup script all run from path_prefix
# with registry tokens and the GitHub OIDC and artefact service
# variables removed from their environment, pinned to the toolchain
# resolved once at the start. Every step output is a validated,
# single-line value.

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=summary.sh
source "$script_dir/summary.sh"

path_prefix="${INPUT_PATH_PREFIX-.}"
manifest_path="${INPUT_MANIFEST_PATH-Cargo.toml}"
workspace_flag="${INPUT_WORKSPACE-true}"
packages_input="${INPUT_PACKAGES-}"
exclude_input="${INPUT_EXCLUDE-}"
features_input="${INPUT_FEATURES-}"
all_features="${INPUT_ALL_FEATURES-false}"
no_default_features="${INPUT_NO_DEFAULT_FEATURES-false}"
toolchain_input="${INPUT_TOOLCHAIN-}"
components_input="${INPUT_TOOLCHAIN_COMPONENTS-}"
targets_input="${INPUT_TOOLCHAIN_TARGETS-}"
lockfile_required="${INPUT_LOCKFILE_REQUIRED-false}"
setup_script="${INPUT_SETUP_SCRIPT-}"
target_input="${INPUT_TARGET-}"
profile="${INPUT_PROFILE-release}"
cargo_args="${INPUT_CARGO_ARGS-}"
binaries="${INPUT_BINARIES-false}"
package_crates="${INPUT_PACKAGE_CRATES-false}"
artefact_upload="${INPUT_ARTEFACT_UPLOAD-true}"
artefact_name="${INPUT_ARTEFACT_NAME-}"
artefact_path="${INPUT_ARTEFACT_PATH-dist}"
summary="${INPUT_SUMMARY-true}"

readonly name_pattern='^[A-Za-z0-9_][A-Za-z0-9_-]*$'
readonly feature_pattern='^([A-Za-z0-9_][A-Za-z0-9_-]*/)?[A-Za-z0-9_][A-Za-z0-9_+.-]*$'
readonly channel_pattern='^[A-Za-z0-9][A-Za-z0-9._+-]*$'
readonly rustup_name_pattern='^[A-Za-z0-9][A-Za-z0-9_.-]*$'
readonly triple_pattern='^[a-z0-9_.]+(-[a-z0-9_.]+){1,4}$'
readonly profile_pattern='^[A-Za-z][A-Za-z0-9_-]{0,63}$'
readonly artefact_name_pattern='^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$'
readonly version_pattern='^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?$'
readonly msrv_pattern='^[0-9]+(\.[0-9]+){0,2}$'
readonly sha256_pattern='^[0-9a-f]{64}$'
# Every reason rustup appends to a toolchain name, before 1.28 and
# since; the toolchain file or override directory is quoted.
readonly legacy_reason_pattern="^ \\((default|environment override by RUSTUP_TOOLCHAIN|overridden by (environment variable RUSTUP_TOOLCHAIN|\\+toolchain on the command line|'.*')|directory override for '.*')\\)\$"

stage="Check inputs"
failure_reason=""
work_dir=""
toolchain=""
toolchain_kind=""
toolchain_pin=""
cargo_version=""
rustc_version=""
resolved_target=""
manifest_display=""
# Set only when toolchain_components or toolchain_targets name any.
install_cell=""
selection_cell="⏸️ Not reached"
lockfile_cell="⏸️ Not reached"
build_cell="⏸️ Not reached"
if [ "$binaries" = "true" ]; then
  binaries_cell="⏸️ Not reached"
else
  binaries_cell="➖ Not requested"
fi
if [ "$package_crates" = "true" ]; then
  crates_cell="⏸️ Not reached"
else
  crates_cell="➖ Not requested"
fi
artefact_cell="⏸️ Not reached"

### Helpers ###

# Messages carry only fixed text and validated values, so they cannot
# break out of a workflow command.
fail() {
  failure_reason="$*"
  echo "::error title=rust-build::$*"
  exit 1
}

warn() {
  add_warning "$*"
  echo "::warning title=rust-build::$*"
}

# Record one step output, refusing anything that is not a single line.
# finish writes them all once the script ends, whatever its status.
emitted_outputs=()
set_output() {
  case "$2" in
    *[$'\r\n']*) fail "refusing to write a multi-line value for output $1" ;;
  esac
  emitted_outputs+=("$1=$2")
}

# Code that runs as this user can find the output file without the
# variable, and the runner applies the last value written for a key.
# Replacing the step's file, on success and failure alike, discards
# anything a child appended: forged keys, keys this run never reached
# and unterminated multi-line values. This is defence in depth, not a
# boundary: a process a child leaves running can write after this.
write_outputs() {
  if [ -z "${GITHUB_OUTPUT:-}" ]; then
    return 0
  fi
  if [ "${#emitted_outputs[@]}" -gt 0 ]; then
    printf '%s\n' "${emitted_outputs[@]}" > "$GITHUB_OUTPUT"
  else
    : > "$GITHUB_OUTPUT"
  fi
}

require_boolean() {
  case "$2" in
    true | false) ;;
    *) fail "$1 must be 'true' or 'false'" ;;
  esac
}

# Split a list input on whitespace (newlines included, for YAML block
# scalars) and, when the third argument is 'commas', on commas too.
# The words land in the global array 'words'.
split_words() {
  local text="${1//[$'\r\n\t']/ }"
  if [ "${2:-}" = "commas" ]; then
    text="${text//,/ }"
  fi
  words=()
  read -r -a words <<< "$text" || true
}

resolve_against() {
  case "$2" in
    /*) printf '%s' "$2" ;;
    *) printf '%s/%s' "$1" "$2" ;;
  esac
}

# True when a canonical path is the workspace or lies below it.
in_workspace() {
  [ "$1" = "$workspace_real" ] || [[ "$1" == "$workspace_real"/* ]]
}

# Resolve a file input against path_prefix: it must exist as a regular
# file, must not itself be a symlink, and its canonical location must
# lie inside the workspace. Sets 'resolved' to the canonical path; it
# runs in this shell, not a subshell, so that 'fail' ends the run.
resolve_file() {
  local input="$1" value="$2" file dir
  file="$(resolve_against "$project_dir" "$value")"
  if [ -L "$file" ]; then
    fail "$input must not be a symlink"
  fi
  if [ ! -f "$file" ]; then
    fail "$input does not name a file below path_prefix"
  fi
  if ! dir="$(cd -- "$(dirname -- "$file")" 2> /dev/null && pwd -P)"; then
    fail "$input does not name a file below path_prefix"
  fi
  if ! in_workspace "$dir"; then
    fail "$input must resolve inside the workspace"
  fi
  resolved="$dir/$(basename -- "$file")"
}

# Resolve artefact_path, which need not exist yet. The deepest part
# that exists is canonicalised, so symlinks are followed before the
# containment check; the rest may hold only plain names, which mkdir
# later creates as real directories.
resolve_artefact_dir() {
  local candidate rest="" part existing
  candidate="$(resolve_against "$project_dir" "$artefact_path")"
  while [[ "$candidate" == */ ]]; do
    candidate="${candidate%/}"
  done
  while [ ! -e "$candidate" ] && [ ! -L "$candidate" ]; do
    part="${candidate##*/}"
    case "$part" in
      "" | . | ..)
        fail "artefact_path may not use '.', '..' or '//' below a" \
          "directory that does not exist yet"
        ;;
    esac
    rest="$part${rest:+/$rest}"
    candidate="${candidate%/*}"
  done
  if ! existing="$(cd -- "$candidate" 2> /dev/null && pwd -P)"; then
    fail "artefact_path must name a directory"
  fi
  artefact_dir="$existing${rest:+/$rest}"
  # Below the workspace, and not path_prefix or above it: that also
  # rules out the workspace itself.
  if ! in_workspace "$artefact_dir"; then
    fail "artefact_path must resolve to a directory below the workspace"
  fi
  if [ "$project_dir" = "$artefact_dir" ] \
    || [[ "$project_dir" == "$artefact_dir"/* ]]; then
    fail "artefact_path must not contain path_prefix"
  fi
}

# Run cargo, rustc, rustup or setup_script from path_prefix with the
# resolved toolchain pinned, and without:
# - registry tokens: CARGO_REGISTRY_TOKEN and every
#   CARGO_REGISTRIES_<NAME>_TOKEN, one per registry, crates.io included;
#   other CARGO_REGISTRIES_<NAME>_* settings, such as _INDEX, stay;
# - the GitHub OIDC and runtime tokens;
# - the runner's command files, so that repository code cannot forge
#   this step's outputs or summary, or set the environment, PATH or
#   state of later steps.
# This is defence in depth, not a boundary: code running as the same
# user can still read an ancestor's environment, and find the command
# files at their predictable paths.
in_project() {
  local -a pin=() unset_args=()
  local name
  if [ -n "$toolchain_pin" ]; then
    pin=("RUSTUP_TOOLCHAIN=$toolchain_pin")
  fi
  for name in CARGO_REGISTRY_TOKEN ACTIONS_ID_TOKEN_REQUEST_TOKEN \
    ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_RUNTIME_TOKEN GITHUB_OUTPUT \
    GITHUB_ENV GITHUB_PATH GITHUB_STATE GITHUB_STEP_SUMMARY; do
    unset_args+=(-u "$name")
  done
  while IFS= read -r name; do
    if [[ "$name" =~ ^CARGO_REGISTRIES_.+_TOKEN$ ]]; then
      unset_args+=(-u "$name")
    fi
  done < <(compgen -e)
  (
    cd -- "$project_dir"
    exec env "${unset_args[@]}" ${pin[@]+"${pin[@]}"} "$@"
  )
}

# Set 'digest' and 'bytes' for a file.
measure_file() {
  if command -v sha256sum > /dev/null 2>&1; then
    digest="$(sha256sum < "$1")"
  else
    digest="$(shasum -a 256 < "$1")"
  fi
  digest="${digest%% *}"
  if [[ ! "$digest" =~ $sha256_pattern ]]; then
    fail "could not compute a SHA-256 digest"
  fi
  bytes="$(wc -c < "$1")"
  bytes="${bytes//[[:space:]]/}"
}

json_strings() {
  jq -nc '$ARGS.positional' --args "$@"
}

# Name the option a cargo_args word sets when this action owns it.
# Cargo accepts clustered short flags ('-vr' is '-v -r'), so a
# single-dash word is read letter by letter up to the first flag that
# takes the rest of the word as its value.
owned_option() {
  local rest letter
  case "$1" in
    -[!-]*)
      rest="${1#-}"
      while [ -n "$rest" ]; do
        letter="${rest:0:1}"
        rest="${rest:1}"
        case "$letter" in
          r) echo "--profile/--release (use profile)" ;;
          p) echo "--package (use packages)" ;;
          F) echo "--features (use features)" ;;
          C | Z) return 1 ;;
          *) continue ;;
        esac
        return 0
      done
      return 1
      ;;
    --message-format | --message-format=*) echo "--message-format" ;;
    --manifest-path | --manifest-path=*) echo "--manifest-path (use manifest_path)" ;;
    --target | --target=*) echo "--target (use target)" ;;
    --profile | --profile=* | --release) echo "--profile/--release (use profile)" ;;
    --package | --package=*) echo "--package (use packages)" ;;
    --workspace | --all) echo "--workspace (use workspace)" ;;
    --exclude | --exclude=*) echo "--exclude (use exclude)" ;;
    --features | --features=*) echo "--features (use features)" ;;
    --all-features) echo "--all-features (use all_features)" ;;
    --no-default-features) echo "--no-default-features (use no_default_features)" ;;
    *) return 1 ;;
  esac
}

finish() {
  local status=$? outcome
  trap - EXIT
  if ! write_outputs; then
    echo "::error title=rust-build::could not write the step outputs"
    if [ "$status" -eq 0 ]; then
      status=1
      failure_reason="could not write the step outputs"
    fi
  fi
  if [ "$status" -ne 0 ] && [ -z "$failure_reason" ]; then
    failure_reason="$stage failed with exit status $status; the step log holds the details."
  fi
  if [ "$summary" = "true" ]; then
    if [ "$status" -eq 0 ]; then
      outcome="### ✅ Build passed"
    else
      outcome="### ❌ Failed at $(md_escape "$stage")"
    fi
    if [ -n "$manifest_display" ]; then
      add_check "Manifest" "$(md_code "$manifest_display")"
    fi
    case "$toolchain_kind" in
      channel) add_check "Toolchain" \
        "$(md_code "$toolchain") (cargo $(md_escape "${cargo_version:-?}"), rustc $(md_escape "${rustc_version:-?}"))" ;;
      path) add_check "Toolchain" \
        "⚠️ Path toolchain $(md_code "$toolchain") (cargo $(md_escape "${cargo_version:-?}"))" ;;
      none) add_check "Toolchain" \
        "cargo $(md_escape "${cargo_version:-?}") on PATH, no rustup" ;;
    esac
    if [ -n "$install_cell" ]; then
      add_check "Components and targets" "$install_cell"
    fi
    if [ -n "$resolved_target" ]; then
      if [ -n "$target_input" ]; then
        add_check "Target" "$(md_code "$resolved_target")"
      else
        add_check "Target" "$(md_code "$resolved_target") (host)"
      fi
    fi
    add_check "Profile" "$(md_code "$profile")"
    add_check "Packages" "$selection_cell"
    add_check "Lockfile" "$lockfile_cell"
    add_check "Build" "$build_cell"
    add_check "Binaries" "$binaries_cell"
    add_check "Crates" "$crates_cell"
    add_check "Artefact" "$artefact_cell"
    write_summary "$outcome" "$failure_reason"
  fi
  if [ -n "$work_dir" ] && [ -d "$work_dir" ]; then
    rm -rf -- "$work_dir"
  fi
  exit "$status"
}
trap finish EXIT

### Check inputs ###

# The containment checks and Cargo's executable paths assume POSIX
# paths, which Windows runners do not report.
if [ "${RUNNER_OS:-}" = "Windows" ]; then
  fail "Windows runners are not supported; use a Linux runner"
fi

# Error messages name the input, never its value: an unvalidated value
# could carry text that the runner reads as a workflow command.
for pair in "workspace:$workspace_flag" "all_features:$all_features" \
  "no_default_features:$no_default_features" \
  "lockfile_required:$lockfile_required" "binaries:$binaries" \
  "package_crates:$package_crates" "artefact_upload:$artefact_upload" \
  "summary:$summary"; do
  require_boolean "${pair%%:*}" "${pair#*:}"
done

if [ -n "$toolchain_input" ] && [[ ! "$toolchain_input" =~ $channel_pattern ]]; then
  fail "toolchain must be a rustup channel name (A-Z a-z 0-9 . _ + -)"
fi
if [ -n "$target_input" ] && [[ ! "$target_input" =~ $triple_pattern ]]; then
  fail "target must be a target triple such as x86_64-unknown-linux-gnu"
fi
if [[ ! "$profile" =~ $profile_pattern ]]; then
  fail "profile must be dev, release or a custom profile name"
fi
if [ -n "$artefact_name" ] && [[ ! "$artefact_name" =~ $artefact_name_pattern ]]; then
  fail "artefact_name may contain only A-Z a-z 0-9 . _ - and must start" \
    "with a letter or digit"
fi

split_words "$packages_input"
packages=(${words[@]+"${words[@]}"})
split_words "$exclude_input"
excludes=(${words[@]+"${words[@]}"})
split_words "$features_input" commas
features=(${words[@]+"${words[@]}"})
for word in ${packages[@]+"${packages[@]}"}; do
  [[ "$word" =~ $name_pattern ]] || fail "packages must list crate names"
done
for word in ${excludes[@]+"${excludes[@]}"}; do
  [[ "$word" =~ $name_pattern ]] || fail "exclude must list crate names"
done
for word in ${features[@]+"${features[@]}"}; do
  [[ "$word" =~ $feature_pattern ]] || fail "features must list feature names"
done
split_words "$components_input" commas
components=(${words[@]+"${words[@]}"})
split_words "$targets_input" commas
toolchain_targets=(${words[@]+"${words[@]}"})
for word in ${components[@]+"${components[@]}"}; do
  [[ "$word" =~ $rustup_name_pattern ]] \
    || fail "toolchain_components must list rustup component names"
done
for word in ${toolchain_targets[@]+"${toolchain_targets[@]}"}; do
  [[ "$word" =~ $rustup_name_pattern ]] \
    || fail "toolchain_targets must list target triples"
done
# A non-empty packages replaces --workspace, which would otherwise make
# Cargo ignore every --package; exclude only applies to --workspace.
if [ "${#excludes[@]}" -gt 0 ] && [ "${#packages[@]}" -gt 0 ]; then
  fail "exclude cannot be combined with packages"
fi
if [ "${#excludes[@]}" -gt 0 ] && [ "$workspace_flag" != "true" ]; then
  fail "exclude needs workspace set to 'true'"
fi

case "$cargo_args" in
  *[$'\r\n']*) fail "cargo_args must be a single line" ;;
esac
extra_args=()
read -r -a extra_args <<< "$cargo_args" || true
for word in ${extra_args[@]+"${extra_args[@]}"}; do
  if option="$(owned_option "$word")"; then
    fail "cargo_args must not set $option; this action sets it"
  fi
done

for tool in cargo jq mktemp wc awk; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    fail "required tool not found on PATH: $tool"
  fi
done
if ! command -v sha256sum > /dev/null 2>&1 \
  && ! command -v shasum > /dev/null 2>&1; then
  fail "required tool not found on PATH: sha256sum or shasum"
fi

if ! workspace_real="$(cd -- "${GITHUB_WORKSPACE:-$PWD}" 2> /dev/null && pwd -P)"; then
  fail "GITHUB_WORKSPACE is not a directory"
fi
if ! project_dir="$(cd -- "$(resolve_against "$workspace_real" "$path_prefix")" \
  2> /dev/null && pwd -P)"; then
  fail "path_prefix is not a directory"
fi
in_workspace "$project_dir" || fail "path_prefix must resolve inside the workspace"

if [ "$(basename -- "$manifest_path")" != "Cargo.toml" ]; then
  fail "manifest_path must name a Cargo.toml file"
fi
resolve_file manifest_path "$manifest_path"
manifest_abs="$resolved"
manifest_display="${manifest_abs#"$workspace_real"/}"

setup_abs=""
if [ -n "$setup_script" ]; then
  resolve_file setup_script "$setup_script"
  setup_abs="$resolved"
fi

resolve_artefact_dir
artefact_display="${artefact_dir#"$workspace_real"/}"
# upload-artifact reads its path as a glob pattern: wildcards and
# escapes anywhere, a leading negation, comment or home directory, and
# trimmed whitespace would all upload something else.
if [[ "$artefact_display" == *[][*?\\]* ]] \
  || [[ "$artefact_display" == [\!#~]* ]] \
  || [[ "$artefact_display" =~ ^[[:space:]]|[[:space:]]$ ]]; then
  fail "artefact_path must resolve to a path without glob syntax:" \
    "no * ? [ ] or backslash, no leading ! # or ~, no outer spaces"
fi
if [ "$binaries" = "true" ] || [ "$package_crates" = "true" ]; then
  if [ -e "$artefact_dir" ] && [ -n "$(ls -A -- "$artefact_dir")" ]; then
    fail "artefact_path must be empty or absent, so that the artefact" \
      "holds only this build's output"
  fi
fi
set_output artefact_path "$artefact_display"

if ! work_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/rust-build.XXXXXX")"; then
  work_dir=""
  fail "could not create a temporary directory"
fi

### Resolve toolchain ###

# 'rustup show active-toolchain' names the toolchain path_prefix
# selects (rust-toolchain.toml, override or default) without running
# it. A channel is pinned for every later call. A path toolchain is a
# directory of binaries the repository chose; it runs unpinned, so the
# same selection applies, with a warning.
stage="Resolve toolchain"
if command -v rustup > /dev/null 2>&1; then
  if [ -n "$toolchain_input" ]; then
    toolchain="$toolchain_input"
  else
    # rustup 1.28 and later print the bare name on the first line and
    # the reason on the next; older releases append " (<reason>)".
    # A path toolchain, and the path a reason quotes, may hold " (" and
    # reason text, so strip the last " (" that starts a whole reason
    # and leaves a channel name or, as rustup names only a path
    # toolchain that exists, a directory.
    if ! toolchain="$(in_project rustup show active-toolchain --verbose)"; then
      fail "rustup could not name the active toolchain for path_prefix"
    fi
    first_line="${toolchain%%$'\n'*}"
    if [[ "$toolchain" != *$'\n'* ]] \
      || [[ "${toolchain#*$'\n'}" != "active because: "* ]]; then
      name_part="$first_line"
      while [[ "$name_part" == ?*" ("* ]]; do
        name_part="${name_part% (*}"
        if [[ "${first_line:${#name_part}}" =~ $legacy_reason_pattern ]] \
          && { [[ "$name_part" != /* ]] || [ -d "$name_part" ]; }; then
          first_line="$name_part"
          break
        fi
      done
    fi
    toolchain="$first_line"
  fi
  case "$toolchain" in
    /*)
      case "$toolchain" in
        *[[:cntrl:]]*)
          toolchain=""
          fail "rustup reported an unusable toolchain path"
          ;;
      esac
      toolchain_kind="path"
      warn "path_prefix selects a path-based toolchain; it runs unpinned" \
        "from path_prefix"
      ;;
    *)
      if [[ ! "$toolchain" =~ $channel_pattern ]]; then
        toolchain=""
        fail "rustup reported an unexpected toolchain name"
      fi
      toolchain_kind="channel"
      toolchain_pin="$toolchain"
      ;;
  esac
else
  if [ -n "$toolchain_input" ]; then
    fail "toolchain needs rustup on PATH"
  fi
  toolchain_kind="none"
fi
set_output toolchain "$toolchain"
set_output toolchain_kind "$toolchain_kind"

### Install toolchain ###

# A toolchain input makes rustup ignore rust-toolchain.toml, and with
# it the components and targets that file lists; callers pass those
# through toolchain_components and toolchain_targets. One 'rustup
# toolchain install' installs a missing toolchain with the minimal
# profile, or adds them to the installed one, keeping an exact version
# such as 1.90.0 as it is (a moving channel such as stable updates).
# A channel named by the toolchain input alone is installed only when
# missing, rather than left to rustup's auto-install, which installs
# the default profile and which RUSTUP_AUTO_INSTALL=0 turns off. The
# probe leaves an installed channel as it is, and keeps a toolchain
# from 'rustup toolchain link', which install rejects, working.
extras=()
if [ "${#components[@]}" -gt 0 ]; then
  extras+=("components $(md_code "${components[*]}")")
fi
if [ "${#toolchain_targets[@]}" -gt 0 ]; then
  extras+=("targets $(md_code "${toolchain_targets[*]}")")
fi
targets_installed=false
if [ "${#extras[@]}" -gt 0 ]; then
  install_cell="⏸️ Not reached"
fi
stage="Install toolchain"
case "$toolchain_kind" in
  channel)
    install="${#extras[@]}"
    if [ "$install" -eq 0 ] && [ -n "$toolchain_input" ] \
      && ! in_project env RUSTUP_AUTO_INSTALL=0 \
        rustup which --toolchain "$toolchain_pin" rustc > /dev/null 2>&1; then
      install=1
    fi
    if [ "$install" -gt 0 ]; then
      install_args=(toolchain install "$toolchain_pin" --profile minimal
        --no-self-update)
      if [ "${#components[@]}" -gt 0 ]; then
        install_args+=(--component "$(IFS=,; printf '%s' "${components[*]}")")
      fi
      if [ "${#toolchain_targets[@]}" -gt 0 ]; then
        install_args+=(--target "$(IFS=,; printf '%s' "${toolchain_targets[*]}")")
      fi
      echo "Running: rustup ${install_args[*]}"
      if ! in_project rustup "${install_args[@]}"; then
        if [ -n "$install_cell" ]; then
          install_cell="❌ rustup could not install them"
        fi
        fail "rustup could not install toolchain $toolchain_pin with the" \
          "requested toolchain_components and toolchain_targets"
      fi
      if [ "${#extras[@]}" -gt 0 ]; then
        install_cell="✅ ${extras[0]}"
        if [ "${#extras[@]}" -gt 1 ]; then
          install_cell+=", ${extras[1]}"
        fi
        targets_installed=true
      fi
    fi
    ;;
  path)
    if [ "${#extras[@]}" -gt 0 ]; then
      install_cell="⚠️ Ignored for a path toolchain"
      warn "toolchain_components and toolchain_targets are ignored for a" \
        "path toolchain; install them into that toolchain instead"
    fi
    ;;
  none)
    if [ "${#extras[@]}" -gt 0 ]; then
      install_cell="❌ Needs rustup"
      fail "toolchain_components and toolchain_targets need rustup on PATH"
    fi
    ;;
esac

### Run setup script ###

if [ -n "$setup_abs" ]; then
  stage="Run setup script"
  # %q keeps a path holding a newline on one line, so no part of it
  # can start a line the runner would read as a workflow command.
  printf 'Running setup script %q\n' "${setup_abs#"$workspace_real"/}"
  in_project bash "$setup_abs"
fi

### Inspect toolchain ###

stage="Inspect toolchain"
cargo_version="$(in_project cargo --version)"
cargo_version="${cargo_version#cargo }"
cargo_version="${cargo_version%%[[:space:]]*}"
if [[ ! "$cargo_version" =~ $version_pattern ]]; then
  cargo_version=""
  fail "cargo --version reported an unexpected version"
fi
rustc_info="$(in_project rustc -vV)"
rustc_version="$(sed -n 's/^release: //p' <<< "$rustc_info")"
host_triple="$(sed -n 's/^host: //p' <<< "$rustc_info")"
if [[ ! "$rustc_version" =~ $version_pattern ]]; then
  rustc_version=""
  fail "rustc -vV reported an unexpected release"
fi
if [[ ! "$host_triple" =~ $triple_pattern ]]; then
  fail "rustc -vV reported an unexpected host triple"
fi
resolved_target="${target_input:-$host_triple}"
set_output cargo_version "$cargo_version"
set_output rustc_version "$rustc_version"
set_output target "$resolved_target"
set_output profile "$profile"
echo "Toolchain: ${toolchain:-cargo on PATH} (cargo $cargo_version," \
  "rustc $rustc_version, host $host_triple)"

artefact_name="${artefact_name:-rust-build-$resolved_target}"
set_output artefact_name "$artefact_name"

### Add target ###

if [ -n "$target_input" ] && [ "$target_input" != "$host_triple" ]; then
  stage="Add target"
  if [ "$targets_installed" = "true" ] \
    && [[ " ${toolchain_targets[*]} " == *" $target_input "* ]]; then
    echo "Target $target_input came with toolchain_targets"
  elif [ "$toolchain_kind" = "channel" ]; then
    in_project rustup target add --toolchain "$toolchain_pin" "$target_input"
  else
    warn "rustup cannot add target $target_input to a $toolchain_kind" \
      "toolchain; it must already be installed"
  fi
fi

### Read metadata ###

stage="Read metadata"
metadata="$work_dir/metadata.json"
in_project cargo metadata --no-deps --format-version 1 --locked \
  --manifest-path "$manifest_abs" > "$metadata"

workspace_root="$(jq -er '.workspace_root | strings' "$metadata")"
if ! workspace_root="$(cd -- "$workspace_root" 2> /dev/null && pwd -P)" \
  || ! in_workspace "$workspace_root"; then
  fail "the Cargo workspace root must lie inside the workspace"
fi
target_directory="$(jq -er '.target_directory | strings' "$metadata")"

rust_version="$(jq -r --arg m "$manifest_abs" \
  '[.packages[] | select(.manifest_path == $m)][0].rust_version // ""' \
  "$metadata")"
if [ -n "$rust_version" ] && [[ ! "$rust_version" =~ $msrv_pattern ]]; then
  rust_version=""
  fail "cargo metadata reported an unexpected rust-version"
fi
set_output rust_version "$rust_version"

# The packages this build selects, as Cargo itself would: the named
# ones, every member less exclusions, or the default members (the
# manifest's own package, else workspace.default-members, else all).
if [ "${#packages[@]}" -gt 0 ]; then
  mode="packages"
elif [ "$workspace_flag" = "true" ]; then
  mode="workspace"
else
  mode="default"
fi
# Cargo 1.71 added workspace_default_members to its metadata; older
# releases leave no record of default-members to select from.
if [ "$mode" = "default" ] \
  && ! jq -e 'has("workspace_default_members")' "$metadata" > /dev/null; then
  fail "workspace 'false' needs Cargo 1.71 or later; set workspace to" \
    "'true' or name the packages"
fi
selected="$work_dir/selected.json"
jq -c --arg mode "$mode" \
  --argjson named "$(json_strings ${packages[@]+"${packages[@]}"})" \
  --argjson excluded "$(json_strings ${excludes[@]+"${excludes[@]}"})" '
  .workspace_default_members as $defaults
  | [.packages[]
     | select(
         if $mode == "packages" then .name | IN($named[])
         elif $mode == "workspace" then (.name | IN($excluded[])) | not
         else .id | IN($defaults[]) end)
     | {id, name, version,
        publishable: (.publish != []),
        deps: [.dependencies[]
               | select(.path != null and (.kind != "dev" or .req != "*"))
               | .name],
        bins: [.targets[] | select(any(.kind[]; . == "bin")) | .name]}]
  ' "$metadata" > "$selected"

for word in ${packages[@]+"${packages[@]}"}; do
  if ! jq -e --arg n "$word" 'any(.[]; .name == $n)' "$selected" > /dev/null; then
    fail "packages names $word, which is not a member of this workspace"
  fi
done
if ! jq -e --arg re "$name_pattern" 'all(.[]; (.name | test($re))
  and (.version | test("^[0-9A-Za-z.+-]+$"))
  and all(.bins[]; test($re)))' "$selected" > /dev/null; then
  fail "cargo metadata reported an unexpected package name or version"
fi
selected_names="$(jq -r 'map(.name) | join(", ")' "$selected")"
selected_count="$(jq -r 'length' "$selected")"
if [ "$selected_count" -eq 0 ]; then
  fail "the package selection matches no workspace member"
fi
case "$mode" in
  workspace) selection_cell="Workspace: $(md_escape "$selected_names")" ;;
  *) selection_cell="$(md_escape "$selected_names")" ;;
esac
echo "Packages: $selected_names"

# Cargo 1.90 stabilised packaging crates together with others they
# depend on. Before it, Cargo verifies each crate against the registry
# alone, so a crate that depends on another crate packaged in the same
# run fails, once the build has run. Path dev-dependencies without a
# version do not count: Cargo drops them from the package. Metadata
# shows an explicit version "*" the same way, and Cargo keeps that
# one, so the packaging stage explains the failure it causes.
old_cargo_package=false
if [ "$package_crates" = "true" ]; then
  IFS=. read -r cargo_major cargo_minor _ <<< "$cargo_version"
  if [ "$cargo_major" -eq 1 ] && [ "$cargo_minor" -lt 90 ]; then
    old_cargo_package=true
    stage="Check packaging"
    dependent="$(jq -r '
      [.[] | select(.publishable) | .name] as $set
      | [.[] | select(.publishable) | .name as $n
         | .deps[] | select(. != $n and IN($set[]))
         | "\($n) depends on \(.)"]
      | .[0] // empty' "$selected")"
    if [ -n "$dependent" ]; then
      crates_cell="❌ Needs Cargo 1.90"
      fail "package_crates needs Cargo 1.90 or later to package crates" \
        "that depend on one another ($dependent); select fewer" \
        "packages or use a newer toolchain"
    fi
  fi
fi

### Check lockfile ###

stage="Check lockfile"
if [ -f "$workspace_root/Cargo.lock" ]; then
  lockfile_cell="✅ Present"
elif [ "$lockfile_required" = "true" ]; then
  lockfile_cell="❌ Missing"
  fail "Cargo.lock is missing and lockfile_required is 'true'; commit" \
    "the lockfile"
else
  warn "Cargo.lock is missing; generated one for this build. Commit" \
    "Cargo.lock for reproducible builds."
  in_project cargo generate-lockfile --manifest-path "$manifest_abs"
  if [ ! -f "$workspace_root/Cargo.lock" ]; then
    fail "cargo generate-lockfile did not create Cargo.lock"
  fi
  lockfile_cell="⚠️ Generated for this build"
fi

### Build ###

feature_args=()
if [ "${#features[@]}" -gt 0 ]; then
  joined="$(IFS=,; printf '%s' "${features[*]}")"
  feature_args+=("--features=$joined")
fi
if [ "$all_features" = "true" ]; then
  feature_args+=(--all-features)
fi
if [ "$no_default_features" = "true" ]; then
  feature_args+=(--no-default-features)
fi
# Always explicit, the host included: otherwise build.target from Cargo
# configuration or cargo_args could build something the outputs and
# artefact name do not describe.
target_args=("--target=$resolved_target")
selection_args=()
case "$mode" in
  packages)
    for word in "${packages[@]}"; do
      selection_args+=("--package=$word")
    done
    ;;
  workspace)
    selection_args+=(--workspace)
    for word in ${excludes[@]+"${excludes[@]}"}; do
      selection_args+=("--exclude=$word")
    done
    ;;
esac

# Cargo renders diagnostics to stderr for the log and writes JSON
# messages to stdout, which name every executable it produced.
stage="Build"
build_log="$work_dir/build.jsonl"
build_cell="❌ Failed"
in_project cargo build --locked --message-format=json-render-diagnostics \
  --manifest-path "$manifest_abs" "--profile=$profile" \
  "${target_args[@]}" \
  ${selection_args[@]+"${selection_args[@]}"} \
  ${feature_args[@]+"${feature_args[@]}"} \
  ${extra_args[@]+"${extra_args[@]}"} > "$build_log"
build_cell="✅ Built $(md_escape "$selected_count") package(s)"

### Package crates ###

# Before anything lands in artefact_path: Cargo refuses to package a
# tree holding files that git does not know about.
crate_list="$work_dir/crates.tsv"
: > "$crate_list"
if [ "$package_crates" = "true" ]; then
  stage="Package crates"
  jq -r '.[] | select(.publishable) | [.name, .version] | @tsv' \
    "$selected" > "$crate_list"
  while IFS= read -r word; do
    echo "Not packaging $word: publish = false"
  done < <(jq -r '.[] | select(.publishable | not) | .name' "$selected")
  if [ ! -s "$crate_list" ]; then
    crates_cell="➖ No publishable packages selected"
    warn "package_crates is 'true', but no selected package is publishable"
  else
    package_args=()
    if [ "$mode" = "workspace" ]; then
      package_args=(--workspace)
      for word in ${excludes[@]+"${excludes[@]}"}; do
        package_args+=("--exclude=$word")
      done
      while IFS= read -r word; do
        package_args+=("--exclude=$word")
      done < <(jq -r '.[] | select(.publishable | not) | .name' "$selected")
    else
      while IFS=$'\t' read -r word _; do
        package_args+=("--package=$word")
      done < "$crate_list"
    fi
    crates_cell="❌ Failed"
    package_status=0
    in_project cargo package --locked --manifest-path "$manifest_abs" \
      "${target_args[@]}" "${package_args[@]}" \
      ${feature_args[@]+"${feature_args[@]}"} || package_status=$?
    if [ "$package_status" -ne 0 ]; then
      if [ "$old_cargo_package" = "true" ] \
        && [ "$(grep -c '' "$crate_list")" -gt 1 ]; then
        warn "Cargo $cargo_version cannot package a crate together with" \
          "another selected crate it depends on, including through a" \
          "path dev-dependency with version \"*\"; Cargo 1.90 can"
      fi
      exit "$package_status"
    fi
  fi
fi

### Collect artefacts ###

stage="Collect artefacts"
binaries_json="[]"
crates_json="[]"
produced=0

# The setup script, the build and cargo_args (--target-dir, say) may
# have written into artefact_path since it was found empty; the first
# call checks again so that the artefact holds only what this collects.
artefact_dir_ready=false
make_artefact_dir() {
  if ! mkdir -p -- "$artefact_dir" \
    || [ "$(cd -- "$artefact_dir" && pwd -P)" != "$artefact_dir" ]; then
    fail "could not create artefact_path inside the workspace"
  fi
  if [ "$artefact_dir_ready" = "false" ] \
    && [ -n "$(ls -A -- "$artefact_dir")" ]; then
    fail "artefact_path gained files before collection; keep the build" \
      "and setup_script from writing there"
  fi
  artefact_dir_ready=true
}

if [ "$binaries" = "true" ]; then
  # Executables of bin targets in the selected packages; test harnesses
  # (profile.test) and build scripts (kind custom-build) are not bins.
  # Records stay JSON, and paths travel NUL-delimited, so any byte a
  # path may hold survives the trip.
  built="$work_dir/built.jsonl"
  jq -R -c --slurpfile sel "$selected" '
    fromjson? | select(.reason == "compiler-artifact")
    | select(.profile.test == false and any(.target.kind[]; . == "bin")
             and (.executable | type == "string"))
    | select(.package_id as $id | any($sel[0][]; .id == $id))
    | {id: .package_id, name: .target.name, executable}' \
    "$build_log" > "$built"
  make_artefact_dir
  sums="$work_dir/SHA256SUMS"
  : > "$sums"
  entries=()
  while IFS= read -r -d '' bin_name && IFS= read -r -d '' executable; do
    file_name="${executable##*/}"
    if [[ ! "$bin_name" =~ $name_pattern ]] \
      || [[ ! "$file_name" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; then
      fail "cargo reported an unexpected binary name"
    fi
    if [ ! -f "$executable" ]; then
      fail "cargo reported binary $bin_name, but its file is missing"
    fi
    # The artefact's own files; case-insensitive file systems (macOS)
    # would also merge names that differ only in case.
    case "$(tr '[:upper:]' '[:lower:]' <<< "$file_name")" in
      sha256sums | crates | crates.json)
        fail "binary $file_name would collide with the artefact's" \
          "SHA256SUMS, crates or crates.json; rename the bin target"
        ;;
    esac
    if [ -e "$artefact_dir/$file_name" ]; then
      fail "two selected packages build a binary named $file_name"
    fi
    cp -- "$executable" "$artefact_dir/$file_name"
    measure_file "$artefact_dir/$file_name"
    printf '%s  %s\n' "$digest" "$file_name" >> "$sums"
    entries+=("$(jq -nc --arg name "$bin_name" --arg path "$file_name" \
      --arg sha256 "$digest" '{name: $name, path: $path, sha256: $sha256}')")
    add_file "$artefact_display/$file_name" "$bytes" "$digest"
    echo "Binary: $file_name ($bytes bytes, SHA-256 $digest)"
  done < <(jq -j '.name, "\u0000", .executable, "\u0000"' "$built")
  # A bin counts as built only for its own package: another package's
  # bin of the same name must not hide one that required-features held
  # back.
  while IFS=$'\t' read -r package_name bin_name; do
    warn "binary $bin_name of package $package_name was not built;" \
      "check its required-features"
  done < <(jq -r --slurpfile built "$built" '
    .[] | . as $p | .bins[]
    | select(. as $b | any($built[]; .id == $p.id and .name == $b) | not)
    | [$p.name, .] | @tsv' "$selected")
  if [ "${#entries[@]}" -eq 0 ]; then
    binaries_cell="➖ No binary targets built"
    warn "binaries is 'true', but the build produced no binaries"
  else
    LC_ALL=C sort -k2 "$sums" > "$artefact_dir/SHA256SUMS"
    binaries_json="$(printf '%s\n' "${entries[@]}" | jq -sc 'sort_by(.path)')"
    produced=$((produced + ${#entries[@]}))
    binaries_cell="✅ ${#entries[@]} binary file(s) with SHA256SUMS"
  fi
fi

if [ -s "$crate_list" ]; then
  make_artefact_dir
  mkdir -p -- "$artefact_dir/crates"
  entries=()
  while IFS=$'\t' read -r crate_name crate_version; do
    file_name="$crate_name-$crate_version.crate"
    source_file="$target_directory/package/$file_name"
    if [ ! -f "$source_file" ]; then
      fail "cargo package did not produce $file_name"
    fi
    cp -- "$source_file" "$artefact_dir/crates/$file_name"
    measure_file "$artefact_dir/crates/$file_name"
    entries+=("$(jq -nc --arg name "$crate_name" --arg version "$crate_version" \
      --arg file "crates/$file_name" --arg sha256 "$digest" \
      '{name: $name, version: $version, file: $file, sha256: $sha256}')")
    add_file "$artefact_display/crates/$file_name" "$bytes" "$digest"
    echo "Crate: $file_name ($bytes bytes, SHA-256 $digest)"
  done < "$crate_list"
  crates_json="$(printf '%s\n' "${entries[@]}" | jq -sc 'sort_by(.file)')"
  printf '%s\n' "$crates_json" | jq . > "$artefact_dir/crates.json"
  produced=$((produced + ${#entries[@]}))
  crates_cell="✅ ${#entries[@]} crate(s) with crates.json"
fi

set_output binaries_json "$binaries_json"
set_output crates_json "$crates_json"

if [ "$produced" -eq 0 ]; then
  set_output upload false
  artefact_cell="➖ Nothing to upload"
elif [ "$artefact_upload" = "true" ]; then
  set_output upload true
  artefact_cell="📦 $(md_code "$artefact_name") from $(md_code "$artefact_display")"
else
  set_output upload false
  artefact_cell="➖ Upload disabled; files in $(md_code "$artefact_display")"
fi
echo "Rust build complete ✅"
