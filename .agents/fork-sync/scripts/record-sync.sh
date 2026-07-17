#!/usr/bin/env bash
# Record a completed sync: write .changes/last-sync.json (the tracked,
# portable pointer the NEXT run's changelog range and rebase base cross-check
# read from) and advance the refs/tags/fork/last-sync-base tag as a fast
# local cross-check.
#
# Usage: record-sync.sh <new-upstream-sha> <digest-path> <timestamp>
# Prints the written last-sync.json content.

set -euo pipefail

new_upstream_sha="${1:?usage: record-sync.sh <new-upstream-sha> <digest-path> <timestamp>}"
digest_path="${2:?usage: record-sync.sh <new-upstream-sha> <digest-path> <timestamp>}"
ts="${3:?usage: record-sync.sh <new-upstream-sha> <digest-path> <timestamp>}"

replayed_shas="$(git rev-list upstream/main..HEAD | jq -Rn '[inputs | select(length > 0)]')"

mkdir -p .changes
jq -n \
  --arg upstream_sha "$new_upstream_sha" \
  --arg synced_at "$ts" \
  --arg digest_path "$digest_path" \
  --argjson custom_commit_shas "$replayed_shas" \
  '{
    upstream_sha: $upstream_sha,
    synced_at: $synced_at,
    digest_path: $digest_path,
    custom_commit_shas: $custom_commit_shas
  }' > .changes/last-sync.json

git tag -f "fork/last-sync-base" "$new_upstream_sha"

cat .changes/last-sync.json
