#!/usr/bin/env bash
# Rebase the fork-custom commits onto the freshly-fetched upstream/main.
# Enables rerere (repo-local config only) so conflict resolutions are
# recorded and auto-replayed on a future run with the same conflict.
# rr-cache lives under the git-common-dir, so it is already shared across any
# `wt`/worktree checkouts of this repo on this machine — no export/import
# needed. Deliberately NOT committed to the repo: it churns every sync with
# opaque hash-named blobs, and autoupdate blind-trusts a hash match, which is
# riskier to replay in a different context (fresh clone) than it saves.
# `.changes/implementation-notes.md` is the portable, human-readable ledger.
#
# Usage: rebase-custom.sh
# Prints one JSON object to stdout describing the outcome:
#   status: "clean" | "conflict" | "error"
# On "conflict", the caller must resolve, `git add` the files, then run
# rebase-continue.sh — never guess a resolution and never edit unrelated code.

set -uo pipefail  # no -e: a conflicting rebase exits non-zero by design

errors=()

git config rerere.enabled true
git config rerere.autoupdate true

if ! git remote get-url upstream >/dev/null 2>&1; then
  jq -n '{status: "error", errors: ["remote upstream is not configured; run preflight.sh first"]}'
  exit 1
fi

base_sha="$(git merge-base HEAD upstream/main)"
expected_custom_count="$(git rev-list --count HEAD --not upstream/main)"
merge_count="$(git rev-list --count --merges "${base_sha}..HEAD")"

if [ "$merge_count" != "0" ]; then
  jq -n --arg base "$base_sha" --argjson merges "$merge_count" \
    '{status: "error", errors: ["\($merges) merge commit(s) found in \($base)..HEAD; rebase --onto assumes linear history — resolve manually"]}'
  exit 1
fi

# No third <branch> arg: passing `HEAD` explicitly there detaches HEAD
# instead of rebasing the current branch in place, leaving the branch ref
# stale after a clean rebase.
git rebase --onto upstream/main "$base_sha" >/tmp/rebase-custom.log 2>&1
rebase_exit=$?

git_dir="$(git rev-parse --git-dir)"

if [ "$rebase_exit" -eq 0 ]; then
  replayed_count="$(git rev-list --count upstream/main..HEAD)"
  count_mismatch=false
  if [ "$replayed_count" != "$expected_custom_count" ]; then
    count_mismatch=true
    errors+=("replayed commit count ($replayed_count) != pre-rebase custom-commit count ($expected_custom_count); a commit likely failed to auto-drop as an upstream duplicate (squashed/reworded upstream PR) — inspect before trusting this run")
  fi
  errors_json="$(printf '%s\n' "${errors[@]:-}" | jq -Rn '[inputs | select(length > 0)]')"
  jq -n \
    --arg base_sha "$base_sha" \
    --argjson replayed_count "$replayed_count" \
    --argjson expected_custom_count "$expected_custom_count" \
    --argjson count_mismatch "$count_mismatch" \
    --argjson errors "$errors_json" \
    '{
      status: "clean",
      base_sha: $base_sha,
      replayed_count: $replayed_count,
      expected_custom_count: $expected_custom_count,
      count_mismatch: $count_mismatch,
      errors: $errors
    }'
  exit 0
fi

if [ -f "$git_dir/rebase-merge/interactive" ] || [ -d "$git_dir/rebase-merge" ] || [ -d "$git_dir/rebase-apply" ]; then
  conflicted_files="$(git diff --name-only --diff-filter=U | jq -Rn '[inputs | select(length > 0)]')"
  current_commit_subject="$(git log -1 --format=%s REBASE_HEAD 2>/dev/null || echo "unknown")"
  jq -n \
    --arg base_sha "$base_sha" \
    --argjson expected_custom_count "$expected_custom_count" \
    --argjson conflicted_files "$conflicted_files" \
    --arg current_commit_subject "$current_commit_subject" \
    '{
      status: "conflict",
      base_sha: $base_sha,
      expected_custom_count: $expected_custom_count,
      conflicted_files: $conflicted_files,
      current_commit_subject: $current_commit_subject,
      log_tail: "/tmp/rebase-custom.log",
      instructions: "resolve conflicted_files per .changes/implementation-notes.md and .agents/fork-sync/references/conflict-playbook.md, git add them, then run rebase-continue.sh. Do not pull in unrelated changes from upstream."
    }'
  exit 0
fi

jq -n --arg log "$(tail -c 2000 /tmp/rebase-custom.log)" \
  '{status: "error", errors: ["rebase failed with no conflict markers detected; raw log: \($log)"]}'
exit 1
