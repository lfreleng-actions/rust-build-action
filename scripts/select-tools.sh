#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Name the cargo tools for taiki-e/install-action to install, as the
# step output 'tools': cargo-auditable@<version> when the inputs ask
# for an auditable binary build, and nothing otherwise.
#
# This step never fails. It names a tool only for input values that
# rust-build.sh accepts, and leaves every invalid value to that script,
# which rejects it and reports the problem in the job summary. Runner
# expressions compare strings without regard to case, so the step
# checks the booleans here rather than in an 'if:'.

set -euo pipefail

# Keep in step with version_pattern in rust-build.sh.
readonly version_pattern='^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?$'

tools=""
if [ "${INPUT_AUDITABLE-}" = "true" ] && [ "${INPUT_BINARIES-}" = "true" ] \
  && [[ "${INPUT_CARGO_AUDITABLE_VERSION-}" =~ $version_pattern ]]; then
  tools="cargo-auditable@$INPUT_CARGO_AUDITABLE_VERSION"
fi
echo "tools=$tools" >> "${GITHUB_OUTPUT:-/dev/stdout}"
