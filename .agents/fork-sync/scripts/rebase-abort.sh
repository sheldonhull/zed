#!/usr/bin/env bash
# Abort an in-progress rebase and hard-reset to the preflight backup tag as a
# belt-and-suspenders restore (rebase --abort alone already restores the
# pre-rebase state, but this confirms it against the tag).
#
# Usage: rebase-abort.sh <backup-tag>
# Prints one JSON object; ok:true means the tree is back to the backup tag.

set -uo pipefail

backup_tag="${1:?usage: rebase-abort.sh <backup-tag>}"

git_dir="$(git rev-parse --git-dir)"
if [ -d "$git_dir/rebase-merge" ] || [ -d "$git_dir/rebase-apply" ]; then
  git rebase --abort
fi

if ! git rev-parse -q --verify "refs/tags/${backup_tag}" >/dev/null; then
  jq -n --arg tag "$backup_tag" '{ok: false, errors: ["backup tag \($tag) not found; cannot confirm restore"]}'
  exit 1
fi

backup_sha="$(git rev-parse "refs/tags/${backup_tag}")"
head_sha="$(git rev-parse HEAD)"

if [ "$backup_sha" != "$head_sha" ]; then
  git reset --hard "refs/tags/${backup_tag}"
  head_sha="$(git rev-parse HEAD)"
fi

ok=true
[ "$backup_sha" = "$head_sha" ] || ok=false

jq -n --argjson ok "$ok" --arg head_sha "$head_sha" --arg backup_sha "$backup_sha" \
  '{ok: $ok, head_sha: $head_sha, backup_sha: $backup_sha, note: "aborted; branch restored to pre-sync state"}'

[ "$ok" = true ]
