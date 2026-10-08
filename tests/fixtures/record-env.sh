# shellcheck shell=bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Sourced by the stand-ins and test setup scripts. record_env appends
# one row to MOCK_CARGO_ENV:
#   command|working directory|RUSTUP_TOOLCHAIN|watched variables
# where the last field names, sorted, each variable present from the
# set the action withholds, plus every other CARGO_REGISTRIES_* one,
# so that a setting the action keeps, such as _INDEX, shows up too.
record_env() {
  local watched
  watched="$(compgen -e | grep -E '^(CARGO_REGISTRY_TOKEN|CARGO_REGISTRIES_.+|ACTIONS_ID_TOKEN_REQUEST_(TOKEN|URL)|ACTIONS_RUNTIME_TOKEN|GITHUB_(OUTPUT|ENV|PATH|STATE|STEP_SUMMARY))$' \
    | LC_ALL=C sort | tr '\n' ' ')" || :
  printf '%s|%s|%s|%s\n' "$1" "$(pwd -P)" "${RUSTUP_TOOLCHAIN-unset}" \
    "${watched% }" >> "$MOCK_CARGO_ENV"
}
