#!/usr/bin/env bash
# Emit raw commit material for the upstream changelog digest, filtered to
# fork-relevant paths/keywords. Deterministic extraction only — clustering,
# dedup, and prose belong to the agent consuming this output.
#
# Range MUST be <recorded fork base>..<new upstream sha>, never main..HEAD —
# `main` is chronically stale relative to the custom-work branch and would
# re-list hundreds of already-seen commits (see .changes/last-sync.json).
#
# Usage: changelog-range.sh <base-sha> <new-upstream-sha> [fork-marker-census-json]
#   fork-marker-census-json: the marker_census object from preflight.sh
#   (file -> CUSTOM(fork) count). When given, each commit is flagged
#   touches_fork_files/fork_files_touched by intersecting its changed paths
#   against that file list — this is the signal for "actually matters to my
#   sidebar/agent-status customizations", not just "mentions agent/git/terminal".
# Prints one JSON object: {total_commits_in_range, filtered_commits: [...]}.

set -euo pipefail

base_sha="${1:?usage: changelog-range.sh <base-sha> <new-upstream-sha> [fork-marker-census-json]}"
new_upstream_sha="${2:?usage: changelog-range.sh <base-sha> <new-upstream-sha> [fork-marker-census-json]}"
fork_files_json="${3:-{}}"
fork_files="$(echo "$fork_files_json" | jq -r 'keys[]' 2>/dev/null | sort -u || true)"

range="${base_sha}..${new_upstream_sha}"

total_commits_in_range="$(git rev-list --count "$range")"

# Fork-relevant path filters (see references/changelog-themes.md).
path_filtered_shas="$(git log --pretty=format:'%H' "$range" -- \
  'crates/agent*' 'crates/assistant*' 'crates/language_model*' \
  'crates/project*' 'crates/git*' 'crates/terminal*' 2>/dev/null || true)"

# Keyword filter over the full-range subjects, for commits relevant by title
# but not touching the exact path filters above (e.g. cross-cutting renames).
keyword_filtered_shas="$(git log --pretty=format:'%H%x09%s' "$range" 2>/dev/null \
  | grep -iE $'\t.*(agent|assistant|language model|copilot|mcp|\\bgit\\b|terminal|project panel)' \
  | cut -f1 || true)"

all_shas="$(printf '%s\n%s\n' "$path_filtered_shas" "$keyword_filtered_shas" | grep -v '^$' | sort -u)"

if [ -z "$all_shas" ]; then
  jq -n --argjson total "$total_commits_in_range" \
    '{total_commits_in_range: $total, filtered_commits: []}'
  exit 0
fi

filtered_commits="$(
  for sha in $all_shas; do
    subject="$(git log -1 --pretty=format:%s "$sha")"
    committer_date="$(git log -1 --pretty=format:%cI "$sha")"
    pr_number="$(echo "$subject" | grep -oE '#[0-9]+\)?$' | tr -d '#)' || true)"

    touches_fork_files=false
    fork_files_touched_json="[]"
    if [ -n "$fork_files" ]; then
      changed_files="$(git show --name-only --pretty=format: "$sha" 2>/dev/null | grep -v '^$' | sort -u || true)"
      matched="$(comm -12 <(echo "$changed_files") <(echo "$fork_files") || true)"
      if [ -n "$matched" ]; then
        touches_fork_files=true
        fork_files_touched_json="$(echo "$matched" | jq -Rn '[inputs | select(length > 0)]')"
      fi
    fi

    jq -n --arg sha "$sha" --arg short_sha "${sha:0:8}" --arg subject "$subject" \
      --arg date "$committer_date" --arg pr "${pr_number:-}" \
      --argjson touches_fork_files "$touches_fork_files" \
      --argjson fork_files_touched "$fork_files_touched_json" \
      '{sha: $sha, short_sha: $short_sha, subject: $subject, date: $date,
        pr_number: (if $pr == "" then null else ($pr | tonumber) end),
        touches_fork_files: $touches_fork_files, fork_files_touched: $fork_files_touched}'
  done | jq -s 'sort_by(.date)'
)"

jq -n --argjson total "$total_commits_in_range" --argjson commits "$filtered_commits" \
  '{total_commits_in_range: $total, filtered_commits: $commits}'
