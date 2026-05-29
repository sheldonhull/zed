# zed-cli-agent-status

CUSTOM (fork) tooling. Reports Claude Code session status to the Zed agent
sidebar so terminal thread rows tint by live agent state.

## How it works

```
Claude Code hook  ->  report-status.sh  ->  status file  ->  Zed sidebar poll  ->  row tint
```

1. Claude Code lifecycle hooks (see `plugins/zed-cli-agent/hooks/hooks.json`) run
   `report-status.sh` with a status word.
2. The script reads `ZED_TERMINAL_ID` (injected by Zed into the terminal's env
   and inherited by the agent and its hooks) and writes one JSON file per
   terminal to
   `${XDG_STATE_HOME:-$HOME/.local/state}/zed/cli-agent-status/<ZED_TERMINAL_ID>.json`.
3. The Zed agent sidebar polls that directory once per second (off the UI
   thread) and matches each terminal thread row by its id, then tints the row
   and shows a status icon. This is exact even with several agents in one
   directory, because each terminal has a distinct injected id.

If `ZED_TERMINAL_ID` is not set (terminal not launched by Zed's agent panel, or
an older Zed without the injection), the script writes nothing.

## Status mapping

| Hook event                      | Status word    | Sidebar row                         |
| ------------------------------- | -------------- | ----------------------------------- |
| SessionStart                    | `idle`         | idle agent (gray bell-off), no tint |
| UserPromptSubmit                | `running`      | spinner, blue tint                  |
| PreToolUse / PostToolUse        | `running`      | spinner, blue tint                  |
| Notification                    | `needs_input`  | bell, orange tint                   |
| Stop                            | `done`         | idle agent (gray bell-off), no tint |
| SessionEnd                      | (file removed) | plain terminal icon                 |

`error` is also supported (red triangle) if a hook reports it.

Icon legend in the sidebar rail:

- spinner (blue) = running
- bell (orange) = needs input
- check-circle (gray) = AI session, idle/done
- terminal glyph = plain terminal, no agent
- red triangle = error

## Install

The marketplace lives at the repo root (`/.claude-plugin/marketplace.json`,
marketplace name `zed-fork-tools`); Claude Code only recognizes marketplaces at
the repo root. This plugin lives under `tooling/` and is referenced from there.

Substitute `<owner>/<repo>` (this fork's GitHub repo) and `<ref>` (the fork
branch, tag, or commit) below.

### Option A — remote, pinned to a fork ref (recommended)

```sh
claude plugin marketplace add <owner>/<repo>@<ref>
claude plugin install zed-cli-agent@zed-fork-tools
```

### Option B — user settings (`~/.claude/settings.json`), pinned to a ref

Use this if you prefer declarative config or the CLI ref form is unavailable:

```json
{
  "extraKnownMarketplaces": {
    "zed-fork-tools": {
      "source": { "source": "github", "repo": "<owner>/<repo>", "ref": "<ref>" },
      "autoUpdate": false
    }
  },
  "enabledPlugins": {
    "zed-cli-agent@zed-fork-tools": true
  }
}
```

### Option C — local checkout (dev, uses the working tree, no ref)

```sh
claude plugin marketplace add /abs/path/to/<repo>
claude plugin install zed-cli-agent@zed-fork-tools
```

Note: `claude plugin install` cannot pin a ref; the ref is fixed when the
marketplace is added (Option A) or in settings (Option B).

## Status file schema

```json
{ "terminal_id": "uuid", "status": "running", "ts": 1700000000, "cwd": "/abs/project", "session_id": "..." }
```

`terminal_id` (the inherited `ZED_TERMINAL_ID`) is the match key. `cwd` and
`session_id` are for debugging only.

## Limitations (v1)

- Requires a Zed that injects `ZED_TERMINAL_ID` into agent-panel terminals
  (this fork). Without it, the script writes nothing.
- Stale files (older than 6h) are ignored by the reader.
- A status file is removed on SessionEnd. A crashed session (no SessionEnd)
  leaves a file that ages out after 6h.
