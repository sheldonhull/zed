#!/usr/bin/env bash
# Fetch zed-industries/zed and fast-forward local `main` to it. Never forces.
# Does NOT check out `main` — stays on whatever branch is currently active
# (the custom-work branch), since `main` is a separate ref we can update
# directly via fetch as long as it isn't the currently-checked-out branch.
#
# `main` may be checked out in a *different* worktree of this same repo (git
# shares refs across worktrees, but refuses to let `git fetch <src>:main`
# write to a ref that's HEAD elsewhere — it fails with a non-obvious error,
# not a clear "checked out elsewhere" message). Detect that case via
# `git worktree list` and fast-forward it in place there with `merge --ff-only`
# instead, so this script is unattended-safe regardless of worktree layout.
#
# Usage: sync-main.sh
# Prints one JSON object to stdout. `ok:false` means STOP.

set -euo pipefail

errors=()

current_branch="$(git rev-parse --abbrev-ref HEAD)"
if [ "$current_branch" = "main" ]; then
  jq -n --arg e "main is the currently checked-out branch; switch to the work branch first" \
    '{ok: false, errors: [$e]}'
  exit 1
fi

git fetch upstream main --no-tags --quiet

old_main_sha="$(git rev-parse main)"
new_upstream_sha="$(git rev-parse upstream/main)"

up_to_date=false
ff_ok=false
if [ "$old_main_sha" = "$new_upstream_sha" ]; then
  up_to_date=true
  ff_ok=true
else
  if git merge-base --is-ancestor main upstream/main; then
    ff_ok=true
  else
    errors+=("local main ($old_main_sha) is not an ancestor of upstream/main ($new_upstream_sha); main has diverged, refusing to force")
  fi
fi

ok=true
if [ "$ff_ok" = false ]; then
  ok=false
fi

# Is `main` checked out as HEAD in some other worktree of this repo?
main_worktree_path=""
if [ "$ok" = true ] && [ "$up_to_date" = false ]; then
  main_worktree_path="$(git worktree list --porcelain | awk '
    /^worktree / { path=$2 }
    /^branch refs\/heads\/main$/ { print path }
  ')"
fi

if [ "$ok" = true ] && [ "$up_to_date" = false ]; then
  if [ -n "$main_worktree_path" ]; then
    # Update ref + working tree together in the worktree that owns it —
    # a raw `fetch ...:main` from here would be rejected since that ref is
    # checked out elsewhere.
    if ! git -C "$main_worktree_path" merge --ff-only upstream/main --quiet; then
      ok=false
      errors+=("fast-forward of main in worktree $main_worktree_path failed (dirty tree there? check manually)")
    fi
  else
    # Not checked out anywhere: a direct ref update via fetch enforces
    # fast-forward-only semantics (fails loudly on non-ff instead of
    # silently rewriting).
    if ! git fetch upstream main:main --no-tags --quiet; then
      ok=false
      errors+=("fast-forward update of local main failed unexpectedly after is-ancestor check passed")
    fi
  fi
fi

errors_json="$(printf '%s\n' "${errors[@]:-}" | jq -Rn '[inputs | select(length > 0)]')"

jq -n \
  --argjson ok "$ok" \
  --arg old_main_sha "$old_main_sha" \
  --arg new_upstream_sha "$new_upstream_sha" \
  --argjson up_to_date "$up_to_date" \
  --argjson errors "$errors_json" \
  '{
    ok: $ok,
    old_main_sha: $old_main_sha,
    new_upstream_sha: $new_upstream_sha,
    up_to_date: $up_to_date,
    note: "local main updated only; push to origin main is left to the user",
    errors: $errors
  }'

[ "$ok" = true ]
