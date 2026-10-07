#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Stand-in for 'rustc -vV', reporting MOCK_RUSTC_VERSION and MOCK_HOST.
# Each call logs its environment.

set -euo pipefail

# shellcheck source=SCRIPTDIR/record-env.sh
source "$MOCK_FIXTURES/record-env.sh"
record_env "rustc"

[ "$*" = "-vV" ] || exit 90
printf '%s\n' "rustc ${MOCK_RUSTC_VERSION:-1.99.0} (mock 2026-01-01)" \
  "binary: rustc" "host: ${MOCK_HOST:-x86_64-unknown-linux-gnu}" \
  "release: ${MOCK_RUSTC_VERSION:-1.99.0}"
