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
#   -> Stamp version -> Run setup script -> Inspect toolchain
#   -> Check cargo-auditable
#   -> Add target -> Read metadata
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
auditable="${INPUT_AUDITABLE-false}"
cargo_auditable_version="${INPUT_CARGO_AUDITABLE_VERSION-0.7.7}"
# The outcome of the action's install-action step, when it ran.
install_outcome="${INSTALL_OUTCOME-}"
package_crates="${INPUT_PACKAGE_CRATES-false}"
artefact_upload="${INPUT_ARTEFACT_UPLOAD-true}"
artefact_name="${INPUT_ARTEFACT_NAME-}"
artefact_path="${INPUT_ARTEFACT_PATH-dist}"
summary="${INPUT_SUMMARY-true}"
version_input="${INPUT_VERSION-}"

readonly name_pattern='^[A-Za-z0-9_][A-Za-z0-9_-]*$'
readonly feature_pattern='^([A-Za-z0-9_][A-Za-z0-9_-]*/)?[A-Za-z0-9_][A-Za-z0-9_+.-]*$'
readonly channel_pattern='^[A-Za-z0-9][A-Za-z0-9._+-]*$'
readonly rustup_name_pattern='^[A-Za-z0-9][A-Za-z0-9_.-]*$'
readonly triple_pattern='^[a-z0-9_.]+(-[a-z0-9_.]+){1,4}$'
readonly profile_pattern='^[A-Za-z][A-Za-z0-9_-]{0,63}$'
readonly artefact_name_pattern='^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$'
readonly version_pattern='^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?$'
# The version input: SemVer 2.0 without a leading 'v' (a numeric
# pre-release identifier has no leading zero), exactly as the tag-based
# versioning spec shared with rust-crate-publish-action reads.
readonly semver_pattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
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
# Set only when the version input is set, once it is validated.
version_cell=""
# The files the version rewrite changed.
stamped_files=()
# Every file the version rewrite covered, a Cargo.lock this run
# generated included, each with a copy in the work directory taken
# right after the rewrite (or the generation): packaging accepts these
# files changed, but only to exactly that content, and with the same
# executable bit ('x' or '-' in stamp_kept_exec), which Cargo records
# in the .crate.
stamp_kept=()
stamp_kept_exec=()
# The git work tree holding the workspace, when packaging a stamped
# tree needs --allow-dirty; empty otherwise.
stamp_git_top=""
# Set only when auditable is 'true'.
auditable_cell=""
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

# Set 'against' to the second path, taken relative to the first unless
# absolute. A variable, not output: command substitution would strip a
# trailing newline from the name.
resolve_against() {
  case "$2" in
    /*) against="$2" ;;
    *) against="$1/$2" ;;
  esac
}

# True when a canonical path is the workspace or lies below it.
in_workspace() {
  [ "$1" = "$workspace_real" ] || [[ "$1" == "$workspace_real"/* ]]
}

# Set 'canonical' to the physical path of a directory, or return 1.
# The trailing sentinel keeps a name that ends in a newline intact,
# which command substitution would otherwise strip, turning the path
# into that of a sibling.
canonical_dir() {
  canonical="$(cd -- "$1" 2> /dev/null && pwd -P && echo x)" || return 1
  canonical="${canonical%$'\n'x}"
}

# Resolve a file input against path_prefix: it must exist as a regular
# file, must not itself be a symlink, and its canonical location must
# lie inside the workspace. Sets 'resolved' to the canonical path; it
# runs in this shell, not a subshell, so that 'fail' ends the run.
resolve_file() {
  local input="$1" value="$2" file dir
  resolve_against "$project_dir" "$value"
  file="$against"
  if [ -L "$file" ]; then
    fail "$input must not be a symlink"
  fi
  if [ ! -f "$file" ]; then
    fail "$input does not name a file below path_prefix"
  fi
  if ! canonical_dir "${file%/*}/"; then
    fail "$input does not name a file below path_prefix"
  fi
  dir="$canonical"
  if ! in_workspace "$dir"; then
    fail "$input must resolve inside the workspace"
  fi
  resolved="$dir/${file##*/}"
}

# Resolve artefact_path, which need not exist yet. The deepest part
# that exists is canonicalised, so symlinks are followed before the
# containment check; the rest may hold only plain names, which mkdir
# later creates as real directories.
resolve_artefact_dir() {
  local candidate rest="" part existing
  resolve_against "$project_dir" "$artefact_path"
  candidate="$against"
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
  if ! canonical_dir "$candidate"; then
    fail "artefact_path must name a directory"
  fi
  existing="$canonical"
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

# Tag-based versioning keeps the placeholder 0.0.0 in every manifest;
# these set the version input in its place, as text, byte for byte the
# way rust-crate-publish-action does, so that both package identical
# crates. Each rewrites one file in place, keeping its inode and mode,
# and records it in 'stamped_files' when anything changed.
#
# Both rules read a file as lines and match each line's content without
# its ending, CRLF or LF, so that anchors work on files a Windows
# checkout converted; every line is written back with exactly its own
# ending, and a final line without a newline stays without one. This
# prefix sets 'ending' and strips it from $0. awk numbers that final
# line 'open_nr'; it is 0 when the file ends with a newline.
# shellcheck disable=SC2016 # awk, not shell, expands these
readonly stamp_awk_lines='
{
  ending = "\n"
  if (NR == open_nr) ending = ""
  else if (sub(/\r$/, "")) ending = "\r\n"
}'

# A manifest: every quoted 0.0.0 a 'version' key holds, with an
# optional = ^ or ~ operator; [package], [workspace.package] and
# dependency versions alike. On each line, every match of
#   (^|[[:space:]{,])(version[[:space:]]*=[[:space:]]*"(=|\^|~)?)0\.0\.0"
# becomes \1\2<version>". A leading space stands in for '^', so one
# expression serves every match; it is dropped again on output.
# shellcheck disable=SC2016 # awk, not shell, expands these
readonly stamp_manifest_awk='
{
  rest = " " $0
  out = ""
  while (match(rest, /[[:space:]{,]version[[:space:]]*=[[:space:]]*"[=^~]?0\.0\.0"/)) {
    out = out substr(rest, 1, RSTART + RLENGTH - 7) version "\""
    rest = substr(rest, RSTART + RLENGTH)
  }
  printf "%s%s", substr(out rest, 2), ending
}'

# Cargo.lock: a section starts at each line that begins with '[', and
# only [[package]] sections change, so a trailing [[patch.unused]] or
# [metadata] table cannot pass for a package. In them: the version
# line of each workspace member's own package (its first name line
# names a member, and it has no source line), and on every line each
# "<member> 0.0.0" entry, whether the dependencies array spans lines
# or sits on one. Third-party packages keep their versions, 0.0.0
# included. 'members' lists the members, separated by spaces.
# shellcheck disable=SC2016 # awk, not shell, expands these
readonly stamp_lockfile_awk='
BEGIN {
  count = split(members, list, " ")
  for (i = 1; i <= count; i++) member[list[i]] = 1
}
function entries(line,   i, from, to, out, at) {
  for (i = 1; i <= count; i++) {
    from = "\"" list[i] " 0.0.0\""
    to = "\"" list[i] " " version "\""
    out = ""
    while ((at = index(line, from)) > 0) {
      out = out substr(line, 1, at - 1) to
      line = substr(line, at + length(from))
    }
    line = out line
  }
  return line
}
function flush(   i, own) {
  own = named && (name in member) && !sourced
  for (i = 1; i <= held; i++) {
    if (own && buf[i] == "version = \"0.0.0\"")
      buf[i] = "version = \"" version "\""
    printf "%s%s", buf[i], ends[i]
  }
  held = 0; named = 0; sourced = 0
}
/^\[/ { flush(); is_package = ($0 == "[[package]]") }
{
  line = $0
  if (is_package) {
    if (!named && line ~ /^name = "[^"]*"$/) {
      name = substr(line, 9, length(line) - 9)
      named = 1
    }
    if (substr(line, 1, 9) == "source = ") sourced = 1
    line = entries(line)
  }
  buf[++held] = line
  ends[held] = ending
}
END { flush() }'

# Rewrite FILE with the awk PROGRAM, passing any further arguments to
# awk, in the C locale so that [[:space:]] means the same bytes on
# every runner.
stamp_rewrite() {
  local file="$1" program="$2" open_nr=0
  shift 2
  # Command substitution strips a newline, so this is empty when the
  # file ends with one.
  if [ -n "$(tail -c 1 < "$file")" ]; then
    open_nr=$(($(wc -l < "$file") + 1))
  fi
  if ! LC_ALL=C awk -v version="$version_input" -v open_nr="$open_nr" \
    "$@" "$stamp_awk_lines$program" < "$file" > "$work_dir/stamped"; then
    fail "version is set, but the rewrite of a file failed"
  fi
  replace_if_changed "$file"
}

replace_if_changed() {
  if ! cmp -s "$work_dir/stamped" "$1"; then
    cat "$work_dir/stamped" > "$1"
    stamped_files+=("$1")
  fi
}

# Keep a copy of a file the version rewrite covered, as it stands now.
stamp_keep() {
  if ! cp -- "$1" "$work_dir/stamp-kept.${#stamp_kept[@]}"; then
    fail "could not keep a copy of the version rewrite"
  fi
  stamp_kept+=("$1")
  if [ -x "$1" ]; then
    stamp_kept_exec+=(x)
  else
    stamp_kept_exec+=(-)
  fi
}

# Find the git work tree holding the workspace root, if any, into
# stamp_git_top. Outside one, Cargo checks nothing and packaging needs
# no --allow-dirty.
stamp_find_git() {
  local top
  if ! command -v git > /dev/null 2>&1 \
    || ! top="$(in_project git -c core.fsmonitor=false \
      -C "$stamp_root" rev-parse --show-toplevel 2> /dev/null \
      && echo x)"; then
    echo "Not in a git checkout: packaging without --allow-dirty"
    return 0
  fi
  if ! canonical_dir "${top%$'\n'x}"; then
    fail "git reported a repository root that is not a directory"
  fi
  case "$stamp_root/" in
    "$canonical"/*) stamp_git_top="$canonical" ;;
    *) fail "git reported a repository root outside the Cargo workspace root" ;;
  esac
}

# Fail unless git reports nothing under the workspace root beyond what
# PHASE allows. Before the rewrite ('before'): an untracked Cargo.lock
# alone, so that no file it covers holds an edit of its own. Before
# packaging ('after'): only a change to a file stamp_kept lists, whose
# content stamp_check_kept has already compared with its copy; an
# untracked Cargo.lock passes only that way, so one setup_script
# created, which no copy vouches for, does not.
# Anything else is a change Cargo would refuse to package, which
# --allow-dirty would let through.
stamp_check_tree() {
  local phase="$1" status_file="$work_dir/git-status" entry code path
  local word listed others=0 lock="$stamp_root/Cargo.lock"
  # Whole paths, compared whole: a path may hold a newline.
  local -a allowed=()
  lock="${lock#"$stamp_git_top"/}"
  if [ "$phase" = "after" ]; then
    for word in ${stamp_kept[@]+"${stamp_kept[@]}"}; do
      allowed+=("${word#"$stamp_git_top"/}")
    done
  fi
  if ! in_project git -c core.fsmonitor=false -C "$stamp_root" \
    status --porcelain=v1 -z --untracked-files=all --no-renames \
    -- . > "$status_file"; then
    fail "git status failed in the workspace root"
  fi
  while IFS= read -r -d '' entry; do
    code="${entry:0:2}"
    path="${entry:3}"
    if [ "$phase" = "before" ] && [ "$code" = "??" ] \
      && [ "$path" = "$lock" ]; then
      continue
    fi
    listed=false
    for word in ${allowed[@]+"${allowed[@]}"}; do
      if [ "$word" = "$path" ]; then
        listed=true
      fi
    done
    if [ "$listed" = "true" ]; then
      case "$code" in
        " M" | "M " | "MM" | "??") continue ;;
      esac
    fi
    others=$((others + 1))
    printf 'Uncommitted change besides the version rewrite: %q\n' "$path"
  done < "$status_file"
  if [ "$others" -eq 0 ]; then
    return 0
  fi
  if [ "$phase" = "before" ]; then
    fail "version is set and package_crates is 'true', but $others" \
      "path(s) under the workspace root have uncommitted changes before" \
      "the version rewrite; the step log lists them. Packaging the" \
      "rewrite needs --allow-dirty, which would let them through"
  fi
  crates_cell="❌ Uncommitted changes"
  fail "package_crates needs --allow-dirty to package the version" \
    "rewrite, but $others other path(s) under the workspace root" \
    "have uncommitted changes; the step log lists them"
}

# Fail unless every file stamp_kept lists is still a regular file
# holding the content and executable bit it had right after the
# version rewrite: --allow-dirty would hide an edit the setup script
# or a build made to one.
stamp_check_kept() {
  local i exec_bit
  for i in "${!stamp_kept[@]}"; do
    exec_bit=-
    if [ -x "${stamp_kept[i]}" ]; then
      exec_bit=x
    fi
    if [ -L "${stamp_kept[i]}" ] || [ ! -f "${stamp_kept[i]}" ] \
      || [ "$exec_bit" != "${stamp_kept_exec[i]}" ] \
      || ! cmp -s -- "$work_dir/stamp-kept.$i" "${stamp_kept[i]}"; then
      crates_cell="❌ Changed after the version rewrite"
      fail "$(printf '%q' "${stamp_kept[i]#"$workspace_real"/}") changed" \
        "after the version rewrite"
    fi
  done
}

# Fail when Cargo.lock exists but stamp_kept does not list it: the
# setup script or a build created it, and git may ignore it, so
# neither check above would see an edit to it.
stamp_check_lock() {
  local word
  if [ ! -e "$stamp_root/Cargo.lock" ] && [ ! -L "$stamp_root/Cargo.lock" ]; then
    return 0
  fi
  for word in ${stamp_kept[@]+"${stamp_kept[@]}"}; do
    if [ "$word" = "$stamp_root/Cargo.lock" ]; then
      return 0
    fi
  done
  crates_cell="❌ Changed after the version rewrite"
  fail "Cargo.lock appeared after the version rewrite; packaging it" \
    "needs --allow-dirty, which would let it through unchecked"
}

# Resolve an absolute path the version rewrite may change: a regular
# file, not a symlink, whose canonical location lies inside the
# workspace. Sets 'resolved' to its canonical path.
resolve_stamp_target() {
  if [ ! -f "$1" ] || [ -L "$1" ] || ! canonical_dir "${1%/*}/" \
    || ! in_workspace "$canonical"; then
    fail "version is set, but $2 is not a regular file inside the workspace"
  fi
  resolved="$canonical/${1##*/}"
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
    if [ -n "$version_cell" ]; then
      add_check "Version" "$version_cell"
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
    if [ -n "$auditable_cell" ]; then
      add_check "Auditable" "$auditable_cell"
    fi
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
  "auditable:$auditable" \
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
if [[ ! "$cargo_auditable_version" =~ $version_pattern ]]; then
  fail "cargo_auditable_version must be a release version such as 0.7.7"
fi
if [ -n "$version_input" ]; then
  if [[ ! "$version_input" =~ $semver_pattern ]]; then
    fail "version must be a SemVer 2.0 version without a leading 'v'" \
      "(such as 1.2.3 or 1.2.3-rc.1), or empty"
  fi
  version_cell="⏸️ Not reached"
fi
if [ "$auditable" = "true" ]; then
  if [ "$binaries" = "true" ]; then
    auditable_cell="⏸️ Not reached"
  else
    auditable_cell="⚠️ No effect without binaries"
    warn "auditable has no effect with binaries set to 'false': the build" \
      "runs plain cargo build, and crate archives hold no binaries"
  fi
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
if [ -n "$version_input" ] && ! command -v cmp > /dev/null 2>&1; then
  fail "required tool not found on PATH: cmp"
fi
if ! command -v sha256sum > /dev/null 2>&1 \
  && ! command -v shasum > /dev/null 2>&1; then
  fail "required tool not found on PATH: sha256sum or shasum"
fi

if ! canonical_dir "${GITHUB_WORKSPACE:-$PWD}"; then
  fail "GITHUB_WORKSPACE is not a directory"
fi
workspace_real="$canonical"
resolve_against "$workspace_real" "$path_prefix"
if ! canonical_dir "$against"; then
  fail "path_prefix is not a directory"
fi
project_dir="$canonical"
in_workspace "$project_dir" || fail "path_prefix must resolve inside the workspace"

if [ "${manifest_path##*/}" != "Cargo.toml" ]; then
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
        if [ "${#extras[@]}" -eq 0 ]; then
          fail "rustup could not install toolchain $toolchain_pin"
        fi
        install_cell="❌ rustup could not install them"
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

### Stamp version ###

# Tag-based versioning: every workspace member carries the placeholder
# 0.0.0, and the release version arrives as the version input. It goes
# into the manifests and Cargo.lock before the setup script, lockfile
# generation and every compile, so binaries embed it through
# CARGO_PKG_VERSION and packaged crates carry it. The guard reads
# metadata as the 'Read metadata' stage does; the rewrite itself is
# text processing here, running no cargo and no project code.
if [ -n "$version_input" ]; then
  stage="Stamp version"
  version_cell="❌ Failed"
  stamp_metadata="$work_dir/stamp-metadata.json"
  in_project cargo metadata --no-deps --format-version 1 --locked \
    --manifest-path "$manifest_abs" > "$stamp_metadata"
  stamp_root="$(jq -er '.workspace_root | strings | . + "/"' "$stamp_metadata")"
  if ! canonical_dir "$stamp_root" || ! in_workspace "$canonical"; then
    fail "the Cargo workspace root must lie inside the workspace"
  fi
  stamp_root="$canonical"
  members_doc="$work_dir/stamp-members.json"
  jq -c '.workspace_members as $ids
    | [.packages[] | select(.id | IN($ids[]))
       | {name, version, manifest_path}]' "$stamp_metadata" > "$members_doc"
  if ! jq -e --arg re "$name_pattern" 'length > 0 and all(.[];
      (.name | strings | test($re))
      and (.version | strings | test("^[0-9A-Za-z.+-]+$"))
      and (.manifest_path | strings | startswith("/")))' \
    "$members_doc" > /dev/null; then
    fail "cargo metadata reported an unexpected package name, version or" \
      "manifest path"
  fi
  offender="$(jq -r '[.[] | select(.version != "0.0.0")][0]
    | if . == null then empty else "\(.name) carries \(.version)" end' \
    "$members_doc")"
  if [ -n "$offender" ]; then
    fail "version is set, so every workspace member must carry the" \
      "placeholder version 0.0.0 in Cargo.toml; $offender"
  fi

  # The root manifest and each member's, once each, then Cargo.lock.
  stamp_targets=()
  resolve_stamp_target "$stamp_root/Cargo.toml" "the workspace manifest"
  stamp_targets+=("$resolved")
  while IFS= read -r -d '' word; do
    resolve_stamp_target "$word" "a workspace member's manifest"
    # The dirty-tree checks cover the workspace root alone.
    case "$resolved" in
      "$stamp_root"/*) ;;
      *)
        fail "version is set, but a workspace member's manifest lies" \
          "outside the Cargo workspace root"
        ;;
    esac
    duplicate=false
    for seen in "${stamp_targets[@]}"; do
      if [ "$seen" = "$resolved" ]; then
        duplicate=true
      fi
    done
    if [ "$duplicate" = "false" ]; then
      stamp_targets+=("$resolved")
    fi
  done < <(jq -j '.[] | .manifest_path + "\u0000"' "$members_doc")
  stamp_lock=""
  if [ -e "$stamp_root/Cargo.lock" ] || [ -L "$stamp_root/Cargo.lock" ]; then
    resolve_stamp_target "$stamp_root/Cargo.lock" "Cargo.lock"
    stamp_lock="$resolved"
  fi

  # Packaging the rewrite needs --allow-dirty in a git checkout, so the
  # files it covers must hold no edit of their own beforehand.
  if [ "$package_crates" = "true" ]; then
    stamp_find_git
    if [ -n "$stamp_git_top" ]; then
      stamp_check_tree before
    fi
  fi

  for word in "${stamp_targets[@]}"; do
    stamp_rewrite "$word" "$stamp_manifest_awk"
    stamp_keep "$word"
  done
  if [ -n "$stamp_lock" ]; then
    stamp_rewrite "$stamp_lock" "$stamp_lockfile_awk" \
      -v members="$(jq -r '[.[].name] | join(" ")' "$members_doc")"
    stamp_keep "$stamp_lock"
  fi

  # A rewrite that missed or overreached fails here or at the --locked
  # build, rather than shipping a version nobody asked for.
  in_project cargo metadata --no-deps --format-version 1 --locked \
    --manifest-path "$manifest_abs" > "$stamp_metadata"
  if ! jq -e --arg v "$version_input" '.workspace_members as $ids
      | all(.packages[] | select(.id | IN($ids[])); .version == $v)' \
    "$stamp_metadata" > /dev/null; then
    fail "after the version rewrite, a workspace member does not report" \
      "version $version_input"
  fi
  echo "Set version $version_input in ${#stamped_files[@]} file(s):"
  for word in ${stamped_files[@]+"${stamped_files[@]}"}; do
    printf '  %q\n' "${word#"$workspace_real"/}"
  done
  version_cell="$(md_escape "$version_input") (version input; Cargo.toml holds 0.0.0)"
fi

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

### Check cargo-auditable ###

# The action's install-action step puts cargo-auditable on PATH, where
# Cargo finds it as the 'auditable' subcommand. The tool has no version
# flag of its own ('cargo auditable --version' prints Cargo's), so this
# checks that Cargo finds it, and the summary names the version the
# action asked for.
build_command=(cargo)
if [ "$auditable" = "true" ] && [ "$binaries" = "true" ]; then
  stage="Check cargo-auditable"
  auditable_cell="❌ Not installed"
  if [ "$install_outcome" = "failure" ]; then
    fail "taiki-e/install-action could not install cargo-auditable" \
      "$cargo_auditable_version"
  fi
  if ! in_project cargo auditable --version > /dev/null 2>&1; then
    fail "Cargo cannot find cargo-auditable; it must be on PATH"
  fi
  build_command=(cargo auditable)
  auditable_cell="⏸️ Not reached"
fi

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

# Each path is read with a trailing '/', so that command substitution
# cannot strip a newline that ends it.
workspace_root="$(jq -er '.workspace_root | strings | . + "/"' "$metadata")"
if ! canonical_dir "$workspace_root" || ! in_workspace "$canonical"; then
  fail "the Cargo workspace root must lie inside the workspace"
fi
workspace_root="$canonical"
target_directory="$(jq -er '.target_directory | strings | . + "/"' "$metadata")"
target_directory="${target_directory%/}"

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
  if [ -n "$version_input" ]; then
    stamp_keep "$workspace_root/Cargo.lock"
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
# messages to stdout, which name every executable it produced. With
# auditable, 'cargo auditable build' takes the same arguments and
# embeds the dependency list in each binary's .dep-v0 section.
stage="Build"
build_log="$work_dir/build.jsonl"
build_cell="❌ Failed"
in_project "${build_command[@]}" build --locked \
  --message-format=json-render-diagnostics \
  --manifest-path "$manifest_abs" "--profile=$profile" \
  "${target_args[@]}" \
  ${selection_args[@]+"${selection_args[@]}"} \
  ${feature_args[@]+"${feature_args[@]}"} \
  ${extra_args[@]+"${extra_args[@]}"} > "$build_log"
# Exit status alone is not enough: an option such as --help in
# cargo_args makes Cargo exit 0 without building.
if ! jq -enR '[inputs | fromjson? | objects
    | select(.reason == "build-finished" and .success == true)]
    | length > 0' "$build_log" > /dev/null; then
  fail "Cargo exited without finishing a build; check cargo_args"
fi
build_cell="✅ Built $(md_escape "$selected_count") package(s)"
if [ "${build_command[*]}" = "cargo auditable" ]; then
  auditable_cell="✅ cargo-auditable $(md_escape "$cargo_auditable_version")"
fi

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
    # Cargo refuses to package a tree with uncommitted changes, which
    # the version rewrite makes. --allow-dirty would let any other
    # change through as well, so it is passed only when every file the
    # rewrite covered holds exactly its rewritten content and git
    # reports nothing else under the workspace root. Outside a git
    # checkout Cargo checks nothing, and gets no flag.
    dirty_args=()
    if [ -n "$version_input" ]; then
      stamp_check_kept
      if [ -n "$stamp_git_top" ]; then
        stamp_check_tree after
        stamp_check_lock
        dirty_args=(--allow-dirty)
      fi
    fi
    package_status=0
    in_project cargo package --locked ${dirty_args[@]+"${dirty_args[@]}"} \
      --manifest-path "$manifest_abs" \
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
  if ! mkdir -p -- "$artefact_dir" || ! canonical_dir "$artefact_dir" \
    || [ "$canonical" != "$artefact_dir" ]; then
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
