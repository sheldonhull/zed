#!/usr/bin/env bash
# Continue an in-progress rebase after the caller has resolved conflicts and
# `git add`-ed the resolved files. Non-interactive (GIT_EDITOR=true) so it
# never hangs waiting for a commit-message editor.
#
# Usage: rebase-continue.sh
# Prints one JSON object shaped like rebase-custom.sh's output
# (status: clean | conflict | error).

set -uo pipefail

git_dir="$(git rev-parse --git-dir)"

if [ ! -d "$git_dir/rebase-merge" ] && [ ! -d "$git_dir/rebase-apply" ]; then
  jq -n '{status: "error", errors: ["no rebase in progress"]}'
  exit 1
fi

if [ -n "$(git diff --name-only --diff-filter=U)" ]; then
  jq -n '{status: "error", errors: ["unresolved conflict markers remain (git diff --diff-filter=U is non-empty); git add the resolved files before continuing"]}'
  exit 1
fi

GIT_EDITOR=true git rebase --continue >/tmp/rebase-custom.log 2>&1
rebase_exit=$?

if [ "$rebase_exit" -eq 0 ] && [ ! -d "$git_dir/rebase-merge" ] && [ ! -d "$git_dir/rebase-apply" ]; then
  replayed_count="$(git rev-list --count upstream/main..HEAD 2>/dev/null || echo 0)"
  jq -n --argjson replayed_count "$replayed_count" \
    '{status: "clean", replayed_count: $replayed_count}'
  exit 0
fi

if [ -d "$git_dir/rebase-merge" ] || [ -d "$git_dir/rebase-apply" ]; then
  conflicted_files="$(git diff --name-only --diff-filter=U | jq -Rn '[inputs | select(length > 0)]')"
  current_commit_subject="$(git log -1 --format=%s REBASE_HEAD 2>/dev/null || echo "unknown")"
  jq -n \
    --argjson conflicted_files "$conflicted_files" \
    --arg current_commit_subject "$current_commit_subject" \
    '{
      status: "conflict",
      conflicted_files: $conflicted_files,
      current_commit_subject: $current_commit_subject,
      log_tail: "/tmp/rebase-custom.log",
      instructions: "resolve, git add, run rebase-continue.sh again"
    }'
  exit 0
fi

jq -n --arg log "$(tail -c 2000 /tmp/rebase-custom.log)" \
  '{status: "error", errors: ["rebase --continue failed unexpectedly; raw log: \($log)"]}'
exit 1
