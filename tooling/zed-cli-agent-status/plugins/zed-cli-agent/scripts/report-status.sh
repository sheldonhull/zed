#!/usr/bin/env sh
# CUSTOM (fork): report Claude Code session status to the Zed agent sidebar.
#
# Zed's agent sidebar polls a status directory and tints each terminal thread row
# by the reported state. Invoked by Claude Code lifecycle hooks (see
# ../hooks/hooks.json); writes one status file per terminal, keyed by the
# ZED_TERMINAL_ID the agent inherits from its terminal env.
#
# Usage: report-status.sh <running|needs_input|idle|done|error> [--remove]
set -eu

status="${1:-idle}"
remove=""
[ "${2:-}" = "--remove" ] && remove=1

# Claude Code sets CLAUDE_PROJECT_DIR for plugin hooks; fall back to the shell cwd.
cwd="${CLAUDE_PROJECT_DIR:-$PWD}"

# Match key: the per-terminal id Zed injects into the terminal environment. The
# agent and its (detached) hooks inherit it. pid/pgid/tty are NOT usable here --
# hooks run detached, with a fresh process group and no controlling tty.
key="${ZED_TERMINAL_ID:-}"
if [ -z "$key" ]; then
  # Not launched from a Zed agent terminal (or older Zed without injection):
  # nothing to match, so do not write a stray status file.
  exit 0
fi

state_base="${XDG_STATE_HOME:-$HOME/.local/state}"
dir="$state_base/zed/cli-agent-status"
mkdir -p "$dir"

file="$dir/$key.json"

if [ -n "$remove" ]; then
  rm -f "$file"
  exit 0
fi

ts=$(date +%s)

# Best-effort fields from the hook's stdin JSON, without depending on jq.
session=""
message=""
if [ ! -t 0 ]; then
  payload=$(cat 2>/dev/null || true)
  session=$(printf '%s' "$payload" \
    | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n1)
  message=$(printf '%s' "$payload" \
    | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n1)
fi

# The Notification hook fires for two different reasons:
#   - a real permission/confirmation prompt ("Claude needs your permission …")
#   - a "Claude is waiting for your input" idle nudge after ~60s of inactivity.
# The idle nudge also fires while a `/loop` or ralph-loop session sleeps between
# iterations, where no input is actually required — so only the permission case
# warrants the orange "waiting for confirmation" tint. Downgrade the idle nudge
# to plain idle so an autonomous loop is not flagged as blocked. A missing
# message (older Claude, or a non-Notification caller) keeps the requested
# status, so this only narrows the Notification path.
if [ "$status" = needs_input ] && [ -n "$message" ]; then
  case "$message" in
    *permission*|*Permission*|*approve*|*Approve*|*confirm*|*Confirm*) ;;
    *) status=idle ;;
  esac
fi

# Escape backslashes and double-quotes for safe JSON string values.
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Atomic write so Zed never reads a half-written file. `terminal_id` is the match
# key (the injected ZED_TERMINAL_ID); cwd/session_id are for debugging.
tmp="$file.tmp.$$"
printf '{"terminal_id":"%s","status":"%s","ts":%s,"cwd":"%s","session_id":"%s"}\n' \
  "$key" "$status" "$ts" "$(json_escape "$cwd")" "$(json_escape "$session")" >"$tmp"
mv -f "$tmp" "$file"
