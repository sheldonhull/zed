#!/usr/bin/env bash
# Preflight checks before rebasing fork-custom commits onto fresh upstream.
# Deterministic, read-mostly except: may `git remote add upstream`, may create
# a backup tag. Never touches the working tree or history.
#
# Usage: preflight.sh <backup-tag-timestamp>
#   <backup-tag-timestamp>: caller-supplied timestamp string (workflow scripts
#   cannot call Date.now()), used to name the backup tag uniquely.
#
# Prints one JSON object to stdout. `ok:false` means STOP — do not proceed to
# sync-main.sh. Exit code mirrors `ok` (0 = true, 1 = false) so a caller can
# gate on exit status alone if it doesn't want to parse JSON.

set -euo pipefail

UPSTREAM_URL_PATTERN='zed-industries/zed'
TS="${1:?usage: preflight.sh <backup-tag-timestamp>}"

errors=()
git_dir="$(git rev-parse --git-dir)"

# --- clean tree, no rewrite in progress ---
clean_tree=true
if [ -n "$(git status --porcelain)" ]; then
  clean_tree=false
  errors+=("working tree is not clean; commit or stash before syncing")
fi

rebase_in_progress=false
for marker in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD; do
  if [ -e "$git_dir/$marker" ]; then
    rebase_in_progress=true
    errors+=("git operation already in progress: $marker present in $git_dir")
  fi
done

# --- not shallow (patch-id dedup + merge-base need full history) ---
is_shallow=false
if [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
  is_shallow=true
  errors+=("repository is shallow; full history is required for merge-base and patch-id dedup")
fi

current_branch="$(git rev-parse --abbrev-ref HEAD)"

# --- upstream remote: add if absent, never repoint if present ---
upstream_remote_ok=false
if git remote get-url upstream >/dev/null 2>&1; then
  upstream_url="$(git remote get-url upstream)"
  if [[ "$upstream_url" == *"$UPSTREAM_URL_PATTERN"* ]]; then
    upstream_remote_ok=true
  else
    errors+=("remote 'upstream' exists but does not point at $UPSTREAM_URL_PATTERN: $upstream_url")
  fi
else
  git remote add upstream "https://github.com/${UPSTREAM_URL_PATTERN}.git"
  upstream_remote_ok=true
fi

# --- origin must not be the upstream itself ---
origin_url="$(git remote get-url origin 2>/dev/null || echo "")"
origin_ok=true
if [[ "$origin_url" == *"$UPSTREAM_URL_PATTERN"* ]]; then
  origin_ok=false
  errors+=("origin points at $UPSTREAM_URL_PATTERN; refusing to run (this looks like the upstream repo, not a fork)")
fi

# --- backup tag (only if we're otherwise clean; a bad backup is worse than none) ---
backup_tag=""
if [ "$clean_tree" = true ] && [ "$rebase_in_progress" = false ]; then
  backup_tag="fork-backup/pre-sync-${TS}"
  if git rev-parse -q --verify "refs/tags/${backup_tag}" >/dev/null; then
    errors+=("backup tag ${backup_tag} already exists; pass a different timestamp")
    backup_tag=""
  else
    git tag "$backup_tag" HEAD
  fi
fi

# --- per-file CUSTOM (fork) marker census ---
marker_json="{}"
census_lines="$(git grep -c 'CUSTOM (fork)' -- . 2>/dev/null || true)"
if [ -n "$census_lines" ]; then
  marker_json="$(echo "$census_lines" | jq -Rn '
    [inputs | select(length > 0) | split(":") | {key: (.[0:-1] | join(":")), value: (.[-1] | tonumber)}]
    | from_entries
  ')"
fi

# --- last recorded sync base, if any ---
last_sync_base="null"
if [ -f ".changes/last-sync.json" ]; then
  last_sync_base="$(jq '.upstream_sha // null' .changes/last-sync.json)"
fi

ok=true
if [ "$clean_tree" = false ] || [ "$rebase_in_progress" = true ] || [ "$is_shallow" = true ] || \
   [ "$upstream_remote_ok" = false ] || [ "$origin_ok" = false ]; then
  ok=false
fi

errors_json="$(printf '%s\n' "${errors[@]:-}" | jq -Rn '[inputs | select(length > 0)]')"

jq -n \
  --argjson ok "$ok" \
  --argjson clean_tree "$clean_tree" \
  --argjson rebase_in_progress "$rebase_in_progress" \
  --argjson is_shallow "$is_shallow" \
  --arg current_branch "$current_branch" \
  --argjson upstream_remote_ok "$upstream_remote_ok" \
  --arg backup_tag "$backup_tag" \
  --argjson marker_census "$marker_json" \
  --argjson last_sync_base "$last_sync_base" \
  --argjson errors "$errors_json" \
  '{
    ok: $ok,
    clean_tree: $clean_tree,
    rebase_in_progress: $rebase_in_progress,
    is_shallow: $is_shallow,
    current_branch: $current_branch,
    upstream_remote_ok: $upstream_remote_ok,
    backup_tag: (if $backup_tag == "" then null else $backup_tag end),
    marker_census: $marker_census,
    last_sync_base: $last_sync_base,
    errors: $errors
  }'

[ "$ok" = true ]
