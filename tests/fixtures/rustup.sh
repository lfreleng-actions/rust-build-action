#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Stand-in for rustup: 'show active-toolchain --verbose' names
# MOCK_TOOLCHAIN (a channel or an absolute path) the way rustup 1.28+
# does, or with MOCK_RUSTUP_LEGACY=true the way older releases did,
# giving MOCK_TOOLCHAIN_REASON (the text rustup puts in parentheses)
# as the reason; 'target add' succeeds unless MOCK_FAIL is 'target'.
# 'which --toolchain <name> rustc' reports every toolchain installed
# except those MOCK_MISSING lists, and refuses to answer unless
# RUSTUP_AUTO_INSTALL is 0; 'toolchain install' succeeds unless
# MOCK_FAIL is 'install'.
# Each call logs its arguments and environment.

set -euo pipefail

printf '%s\n' "$*" >> "$MOCK_RUSTUP_LOG"
# shellcheck source=SCRIPTDIR/record-env.sh
source "$MOCK_FIXTURES/record-env.sh"
record_env "${1:-}"

case "$*" in
  "show active-toolchain --verbose")
    if [ "${MOCK_FAIL:-}" = "show" ]; then
      echo "error: no active toolchain" >&2
      exit 1
    fi
    name="${MOCK_TOOLCHAIN:-stable-x86_64-unknown-linux-gnu}"
    reason="overridden by '/w (x)/rust-toolchain.toml'"
    reason="${MOCK_TOOLCHAIN_REASON:-$reason}"
    if [ "${MOCK_RUSTUP_LEGACY:-false}" = "true" ]; then
      printf '%s (%s)\n%s\n' "$name" "$reason" "/opt/rustup/toolchains/x"
    else
      printf '%s\n' "$name" \
        "active because: $reason" \
        "compiler: rustc 1.99.0 (mock 2026-01-01)" \
        "path: /opt/rustup/toolchains/x"
    fi
    ;;
  "target add --toolchain "*)
    if [ "${MOCK_FAIL:-}" = "target" ]; then
      echo "error: toolchain does not support target" >&2
      exit 1
    fi
    ;;
  "which --toolchain "*" rustc")
    if [ "${RUSTUP_AUTO_INSTALL-}" != "0" ]; then
      echo "mock rustup: this call could auto-install a toolchain" >&2
      exit 92
    fi
    if [[ " ${MOCK_MISSING:-} " == *" $3 "* ]]; then
      echo "error: toolchain '$3' is not installed" >&2
      exit 1
    fi
    echo "/opt/rustup/toolchains/$3/bin/rustc"
    ;;
  "toolchain install "*)
    if [ "${MOCK_FAIL:-}" = "install" ]; then
      echo "error: component 'x' is unavailable for download" >&2
      exit 1
    fi
    ;;
  *)
    echo "mock rustup: unexpected arguments" >&2
    exit 90
    ;;
esac
