#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Stand-in for cargo, driven by MOCK_* variables from the bats suite.
#
# It logs every call (arguments, with the project root shown as @ROOT)
# and the environment the call saw, then imitates the parts of Cargo
# that rust-build.sh relies on. The workspace it describes lives at
# MOCK_ROOT:
#
#   app     1.2.3  Cargo.toml             lib, bins app + app-extra
#   lib-a   0.4.0  crates/lib-a/Cargo.toml  lib
#   tool    0.0.1  crates/tool/Cargo.toml   bin tool, publish = false
#
# MOCK_VIRTUAL=true drops 'app', leaving a virtual workspace.
#
# 'cargo auditable <args>' runs as 'cargo <args>', as the real
# subcommand does, unless MOCK_NO_AUDITABLE is 'true'.

set -euo pipefail

root="$MOCK_ROOT"
log_args="$*"
log_args="${log_args//"$root"/@ROOT}"
printf '%s\n' "$log_args" >> "$MOCK_CARGO_LOG"
# shellcheck source=SCRIPTDIR/record-env.sh
source "$MOCK_FIXTURES/record-env.sh"
record_env "${1:-}"

if [ "${1:-}" = "auditable" ]; then
  if [ "${MOCK_NO_AUDITABLE:-false}" = "true" ]; then
    echo "error: no such command: \`auditable\`" >&2
    exit 101
  fi
  shift
fi

if [ "${MOCK_FAIL:-}" = "${1:-}" ]; then
  echo "error: mock cargo ${1:-} failed" >&2
  exit 42
fi

target_dir="${MOCK_TARGET_DIR:-$root/target}"

# Full 'cargo metadata --no-deps' document for the manifest given.
metadata() {
  local manifest="$1"
  jq -n --arg root "$root" --arg manifest "$manifest" \
    --arg target_dir "$target_dir" \
    --arg ws_root "${MOCK_WORKSPACE_ROOT:-$root}" \
    --arg msrv "${MOCK_MSRV-1.80}" \
    --arg virtual "${MOCK_VIRTUAL:-false}" '
    def pkg($name; $version; $dir; $publish; $targets):
      { id: "path+file://\($root)\($dir)#\($name)@\($version)",
        name: $name, version: $version, publish: $publish,
        rust_version: null, dependencies: [],
        manifest_path: "\($root)\($dir)/Cargo.toml", targets: $targets };
    def target($name; $kind): { name: $name, kind: [$kind] };
    ( [ pkg("lib-a"; "0.4.0"; "/crates/lib-a"; null; [target("lib_a"; "lib")]),
        pkg("tool"; "0.0.1"; "/crates/tool"; []; [target("tool"; "bin")]) ]
      | if $virtual == "true" then . else
          [ pkg("app"; "1.2.3"; ""; null;
              [target("app"; "lib"), target("app"; "bin"),
               target("app-extra"; "bin"), target("it"; "test")])
            | .rust_version = (if $msrv == "" then null else $msrv end) ]
          + . end ) as $packages
    | { packages: $packages,
        workspace_members: [$packages[].id],
        workspace_default_members:
          ( [$packages[] | select(.manifest_path == $manifest) | .id]
            | if length > 0 then . else [$packages[].id] end ),
        target_directory: $target_dir,
        workspace_root: $ws_root,
        version: 1 }'
}

# Tests that need altered metadata name a jq filter file, applied to
# the document above.
metadata_document() {
  if [ -n "${MOCK_METADATA_FILTER_FILE:-}" ]; then
    metadata "$1" | jq -f "$MOCK_METADATA_FILTER_FILE"
  else
    metadata "$1"
  fi
}

# Option values from the argument list: '--name=value' forms only, as
# rust-build.sh passes them.
values_of() {
  local option="$1" argument
  shift
  for argument in "$@"; do
    case "$argument" in
      "$option="*) printf '%s\n' "${argument#"$option"=}" ;;
    esac
  done
}

has_flag() {
  local flag="$1" argument
  shift
  for argument in "$@"; do
    [ "$argument" = "$flag" ] && return 0
  done
  return 1
}

manifest_of() {
  local previous=""
  for argument in "$@"; do
    if [ "$previous" = "--manifest-path" ]; then
      printf '%s' "$argument"
      return
    fi
    previous="$argument"
  done
  printf '%s/Cargo.toml' "$root"
}

# The packages a build or package call selects, one JSON object each.
selected_packages() {
  local manifest named excluded doc
  manifest="$(manifest_of "$@")"
  named="$(values_of --package "$@" | jq -R . | jq -sc .)"
  excluded="$(values_of --exclude "$@" | jq -R . | jq -sc .)"
  doc="$(metadata_document "$manifest")"
  if has_flag --workspace "$@"; then
    jq -c --argjson ex "$excluded" \
      '.packages[] | select(.name | IN($ex[]) | not)' <<< "$doc"
  elif [ "$named" != "[]" ]; then
    jq -c --argjson n "$named" '.packages[] | select(.name | IN($n[]))' <<< "$doc"
  else
    jq -c '.workspace_default_members as $d
      | .packages[] | select(.id | IN($d[]))' <<< "$doc"
  fi
}

case "${1:-}" in
  --version)
    echo "cargo ${MOCK_CARGO_VERSION:-1.99.0} (mock 2026-01-01)"
    ;;
  metadata)
    metadata_document "$(manifest_of "$@")"
    ;;
  generate-lockfile)
    if [ "${MOCK_NO_LOCKFILE_WRITE:-false}" != "true" ]; then
      : > "$root/Cargo.lock"
    fi
    ;;
  build)
    profile="$(values_of --profile "$@")"
    triple="$(values_of --target "$@")"
    case "$profile" in
      dev | test) profile_dir=debug ;;
      bench) profile_dir=release ;;
      *) profile_dir="$profile" ;;
    esac
    out_dir="$target_dir/${triple:+$triple/}$profile_dir"
    mkdir -p "$out_dir/deps" "$out_dir/build"
    echo "this line is not JSON"
    while IFS= read -r package; do
      jq -c --arg out "$out_dir" --arg skip " ${MOCK_SKIP_BINS:-} " '
        . as $p | .targets[] | .name as $n
        | { reason: "compiler-artifact", package_id: $p.id,
            target: { name, kind },
            profile: { test: false },
            executable: (if .kind == ["bin"] and ($skip | contains(" \($n) ") | not)
                         then "\($out)/\($n)" else null end) }
        | select(.target.kind != ["test"])' <<< "$package"
      name="$(jq -r .name <<< "$package")"
      id="$(jq -r .id <<< "$package")"
      # A build script and a test harness both have executables; neither
      # is a binary target.
      jq -nc --arg id "$id" --arg out "$out_dir" --arg n "$name" '
        { reason: "compiler-artifact", package_id: $id,
          target: { name: "build-script-build", kind: ["custom-build"] },
          profile: { test: false },
          executable: "\($out)/build/\($n)-build-script" },
        { reason: "compiler-artifact", package_id: $id,
          target: { name: $n, kind: ["bin"] }, profile: { test: true },
          executable: "\($out)/deps/\($n)-0123456789abcdef" }'
    done < <(selected_packages "$@") \
      | while IFS= read -r line; do
        printf '%s\n' "$line"
        executable="$(jq -r '.executable // empty' <<< "$line" 2> /dev/null || true)"
        if [ -n "$executable" ]; then
          mkdir -p "$(dirname "$executable")"
          printf 'binary %s\n' "${executable##*/}" > "$executable"
        fi
      done
    if [ -n "${MOCK_EXTRA_MESSAGES:-}" ]; then
      cat "$MOCK_EXTRA_MESSAGES"
    fi
    echo '{"reason":"build-finished","success":true}'
    ;;
  package)
    # Record whether artefact_path already held anything: Cargo would
    # see untracked files there.
    if [ -n "${MOCK_ARTEFACT_DIR:-}" ] && [ -e "$MOCK_ARTEFACT_DIR" ] \
      && [ -n "$(ls -A "$MOCK_ARTEFACT_DIR")" ]; then
      echo "package saw files in artefact_path" >> "$MOCK_CARGO_LOG"
    fi
    # Like Cargo, package whatever is selected, publish = false or not.
    mkdir -p "$target_dir/package"
    while IFS= read -r package; do
      file="$(jq -r '"\(.name)-\(.version).crate"' <<< "$package")"
      if [[ " ${MOCK_MISSING_CRATES:-} " != *" $file "* ]]; then
        printf 'crate %s\n' "$file" > "$target_dir/package/$file"
      fi
    done < <(selected_packages "$@")
    ;;
  *)
    echo "mock cargo: unexpected command ${1:-}" >&2
    exit 90
    ;;
esac
