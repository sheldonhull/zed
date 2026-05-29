# Zed fork — Claude Code marketplace

`marketplace.json` here registers the `zed-fork-tools` marketplace and the
`zed-cli-agent` plugin (source: `tooling/zed-cli-agent-status/plugins/zed-cli-agent`).
Marketplaces must live at the repo root, so this file stays here while the plugin
lives under `tooling/`.

Plugin docs: `tooling/zed-cli-agent-status/README.md`.

## Install (pinned to the fork ref)

### CLI

```sh
claude plugin marketplace add sheldonhull/zed@feat/threads-sidebar-improvements
claude plugin install zed-cli-agent@zed-fork-tools
```

### Or user settings (`~/.claude/settings.json`)

Use this if you prefer declarative config. `claude plugin install` cannot pin a
ref — the ref is fixed here (or at `marketplace add` time).

```json
{
  "extraKnownMarketplaces": {
    "zed-fork-tools": {
      "source": { "source": "github", "repo": "sheldonhull/zed", "ref": "feat/threads-sidebar-improvements" },
      "autoUpdate": false
    }
  },
  "enabledPlugins": {
    "zed-cli-agent@zed-fork-tools": true
  }
}
```

### Local checkout (dev; uses the working tree, no ref)

```sh
claude plugin marketplace add /abs/path/to/zed-worktree
claude plugin install zed-cli-agent@zed-fork-tools
```
