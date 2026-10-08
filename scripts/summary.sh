#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Job summary helpers for rust-build.sh, which sources this file.
#
# The summary has an outcome line, a '| Check | Result |' table, an
# optional table of produced files and a list of warnings. Rows are
# queued while the build runs and written once, at exit.

summary_checks=()
summary_files=()
summary_warnings=()

# Make text safe inside one Markdown table cell. Replacement strings
# are quoted so that '&' stays literal under bash 5.2's
# patsub_replacement option.
md_escape() {
  local text="$1"
  text="${text//&/"&amp;"}"
  text="${text//</"&lt;"}"
  text="${text//>/"&gt;"}"
  text="${text//|/"&#124;"}"
  text="${text//\`/"&#96;"}"
  text="${text//\\/"&#92;"}"
  text="${text//[$'\r\n']/" "}"
  printf '%s' "$text"
}

# Inline code for an untrusted value. A <code> element still renders
# after escaping, where a backtick span would not.
md_code() {
  printf '<code>%s</code>' "$(md_escape "$1")"
}

# Byte count for people: 512 B, 4.0 KiB, 12.3 MiB.
readable_size() {
  awk -v n="$1" 'BEGIN {
    u = "B"
    if (n >= 1024) { n /= 1024; u = "KiB" }
    if (n >= 1024) { n /= 1024; u = "MiB" }
    if (n >= 1024) { n /= 1024; u = "GiB" }
    if (u == "B") printf "%d %s", n, u; else printf "%.1f %s", n, u
  }'
}

# Queue a row of the check table. The result must already be escaped.
add_check() {
  summary_checks+=("| $1 | $2 |")
}

# Queue a row of the file table: path, byte count, SHA-256.
add_file() {
  summary_files+=("| $(md_code "$1") | $(readable_size "$2") | $(md_code "$3") |")
}

# Queue a warning; escaped here.
add_warning() {
  summary_warnings+=("- $(md_escape "$1")")
}

# Print the whole summary. Arguments: the outcome line, already
# escaped, and an optional plain-text detail line.
render_summary_text() {
  local line
  printf '## 🦀 Rust Build\n\n%s\n\n' "$1"
  if [ -n "${2:-}" ]; then
    printf '%s\n\n' "$(md_escape "$2")"
  fi
  printf '| Check | Result |\n| --- | --- |\n'
  for line in ${summary_checks[@]+"${summary_checks[@]}"}; do
    printf '%s\n' "$line"
  done
  if [ "${#summary_files[@]}" -gt 0 ]; then
    printf '\n| File | Size | SHA-256 |\n| --- | --- | --- |\n'
    printf '%s\n' "${summary_files[@]}"
  fi
  if [ "${#summary_warnings[@]}" -gt 0 ]; then
    printf '\n### Warnings\n\n'
    printf '%s\n' "${summary_warnings[@]}"
  fi
}

# Append the summary to $GITHUB_STEP_SUMMARY. Failing to write it
# never changes the step's result. The output is captured first, so
# the redirection below is a simple command whose failure 'if' sees.
write_summary() {
  local text
  if [ -z "${GITHUB_STEP_SUMMARY:-}" ]; then
    return 0
  fi
  text="$(render_summary_text "$@")"
  if ! printf '\n%s\n' "$text" 2> /dev/null >> "$GITHUB_STEP_SUMMARY"; then
    echo "::warning::Could not write the Rust build job summary" >&2
  fi
}
