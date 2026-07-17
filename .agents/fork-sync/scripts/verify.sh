#!/usr/bin/env bash
# Post-rebase verification: per-file CUSTOM(fork) marker census must match
# preflight's (a moved/lost marker can hide behind an unchanged global count),
# then mise check + the sidebar/ui crate tests. Always runs through
# `mise exec`/`mise run` — host cargo can have a broken libgit2.
#
# Usage: verify.sh '<preflight-marker-census-json>'
#   arg1: the marker_census object from preflight.sh's output, verbatim.
# Prints one JSON object; ok:false means STOP before changelog/build.

set -uo pipefail

before_census="${1:?usage: verify.sh '<preflight-marker-census-json>'}"

if ! echo "$before_census" | jq -e . >/dev/null 2>&1; then
  jq -n '{ok: false, errors: ["arg1 is not valid JSON"]}'
  exit 1
fi

census_lines="$(git grep -c 'CUSTOM (fork)' -- . 2>/dev/null || true)"
after_census="{}"
if [ -n "$census_lines" ]; then
  after_census="$(echo "$census_lines" | jq -Rn '
    [inputs | select(length > 0) | split(":") | {key: (.[0:-1] | join(":")), value: (.[-1] | tonumber)}]
    | from_entries
  ')"
fi

marker_diff="$(jq -n --argjson before "$before_census" --argjson after "$after_census" '
  ($before | keys) as $before_keys
  | ($after | keys) as $after_keys
  | {
      unchanged: [ $before_keys[] | select(. as $k | $after[$k] == $before[$k]) ],
      changed: [ $before_keys[] | select(. as $k | ($after[$k] // 0) != $before[$k]) | {file: ., before: $before[.], after: ($after[.] // 0)} ],
      new_files: [ $after_keys[] | select(. as $k | ($before[$k] // null) == null) ]
    }
')"

markers_ok=true
if [ "$(echo "$marker_diff" | jq '.changed | length')" != "0" ]; then
  markers_ok=false
fi

check_ok=true
check_log=""
if ! check_log="$(mise run check 2>&1)"; then
  check_ok=false
fi

sidebar_ok=true
sidebar_log=""
if ! sidebar_log="$(mise run test-sidebar 2>&1)"; then
  sidebar_ok=false
fi

ui_ok=true
ui_log=""
if ! ui_log="$(mise run test-ui 2>&1)"; then
  ui_ok=false
fi

ok=true
[ "$markers_ok" = true ] && [ "$check_ok" = true ] && [ "$sidebar_ok" = true ] && [ "$ui_ok" = true ] || ok=false

jq -n \
  --argjson ok "$ok" \
  --argjson markers_ok "$markers_ok" \
  --argjson marker_diff "$marker_diff" \
  --argjson check_ok "$check_ok" \
  --arg check_log_tail "$(echo "$check_log" | tail -c 4000)" \
  --argjson sidebar_ok "$sidebar_ok" \
  --arg sidebar_log_tail "$(echo "$sidebar_log" | tail -c 4000)" \
  --argjson ui_ok "$ui_ok" \
  --arg ui_log_tail "$(echo "$ui_log" | tail -c 4000)" \
  '{
    ok: $ok,
    markers_ok: $markers_ok,
    marker_diff: $marker_diff,
    check_ok: $check_ok,
    check_log_tail: $check_log_tail,
    sidebar_ok: $sidebar_ok,
    sidebar_log_tail: $sidebar_log_tail,
    ui_ok: $ui_ok,
    ui_log_tail: $ui_log_tail
  }'

[ "$ok" = true ]
