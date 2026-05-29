# Fork Implementation Notes

Replayable migration log for fork-local customizations on top of upstream Zed.
Use this to reapply the changes after pulling a fresh upstream, and to resolve
rebase conflicts. Every fork edit in code is marked `// CUSTOM (fork)`.

## Goal

Agent sidebar terminal/thread rows show live agent run-state at a glance:

- A full-height left rail with a large status icon.
- The whole row tinted by status (idle stays untinted).
- CLI-agent (Claude Code) terminals report status via a companion plugin; an
  idle agent is visually distinct from a plain terminal.

Status → look:

- Running → blue tint, spinner (`LoadCircle`)
- WaitingForConfirmation (needs input) → orange tint, `Bell`
- Error → red tint, `Triangle`
- Completed + agent idle/done → no tint, gray `CheckCircle`
- Completed + plain terminal → no tint, terminal icon

## Replay guide (reapply on fresh upstream)

Ordered; each step is independent unless noted. Anchors are functions/symbols,
not line numbers (line numbers drift).

### 1. Tooling / repo

- `.gitignore`: add `.artifacts/` and `.cache/`.
- `mise.toml` (root, `# CUSTOM` header): pin `rust = "stable"`; tasks build/run/
  clippy/fmt/test-ui/test-sidebar/check + `plugin-status-test`. Host `cargo` may
  have a broken `libgit2`/`llhttp`; always build via `mise exec -- cargo ...`.
- `.claude-plugin/marketplace.json` (REPO ROOT — required; Claude Code only finds
  marketplaces at root): marketplace `zed-fork-tools`, one plugin `zed-cli-agent`
  with `source: "./tooling/zed-cli-agent-status/plugins/zed-cli-agent"`.
- `tooling/zed-cli-agent-status/` (plugin + README): `plugins/zed-cli-agent/`
  with `.claude-plugin/plugin.json`, `hooks/hooks.json`, `scripts/report-status.sh`.
- `.claude/settings.json` (project): same hooks as the plugin, for local testing
  without installing. Calls `report-status.sh` via `$CLAUDE_PROJECT_DIR`.
- `hk.pkl` (root, `CUSTOM`): pre-commit hooks via hk — `Builtins.cargo_fmt`,
  `Builtins.cargo_clippy`, `Builtins.gitleaks` (uses `gitleaks dir`, worktree-safe),
  and a custom `trufflehog filesystem {{files}}` step. Pin the `amends`/`import`
  package version to the installed hk (mise pins `hk = "1.45.0"`). Enable with
  `mise exec -- hk install --mise` (git 2.54+ uses native `hook.*.command`, so
  `.git/hooks/` stays untouched). Tools come from mise: hk, pkl, gitleaks, trufflehog.
- `script/zed-custom-publish.sh` + mise tasks `cert:create` / `publish` /
  `publish:diag`: build a release "Zed Custom" .app and install it to /Applications
  for native launch, coexisting with official Zed and the `cargo run` dev instance.
  Replicates `script/bundle-mac`'s build + cargo-bundle + git/cli helpers but skips
  dmg/npm/notarize. Signs with a STABLE self-signed cert (no hardened runtime —
  self-signed can't) so the designated requirement pins to the cert leaf, not the
  cdhash, and macOS TCC grants survive rebuilds (ad-hoc signing re-prompts every
  build). Keep the bundle id constant (`dev.zed.zed-custom`).

### 2. `crates/icons/src/icons.rs`

- Add `CheckCircle,` to the `IconName` enum (after `Check`). The `strum`
  `serialize_all = "snake_case"` derive auto-maps it to the existing
  `assets/icons/check_circle.svg`; `path()` needs no change.

### 3. `crates/ui/src/components/ai/thread_item.rs` (`ThreadItem`)

- Add field `agent_idle: bool` (+ default false, + `agent_idle(bool)` setter).
- In `render`:
  - Compute `status_tint: Option<Hsla>` from `cx.theme().status()`:
    Running=`info`, WaitingForConfirmation=`warning`, Error=`error`,
    Completed=`None`. Constants `ROW_TINT_OPACITY=0.15`,
    `ROW_TINT_HOVER_OPACITY=0.5`. Blend into `base_bg`/`row_hover_bg`.
  - Build a `status_rail` (`h_flex().h_full().w(rail_width=44px)`, icon
    `IconSize::Custom(rems(2.5))`). Match `self.status` for the rail icon:
    Running=`LoadCircle`(spin)/`Info`, WaitingForConfirmation=`Bell`/`Warning`,
    Error=`Triangle`/`Error`, Completed+notified=`Bell`/`Accent`,
    Completed+`agent_idle`=`CheckCircle`/`Muted`, else `agent_icon`.
  - Change the top-level container from `v_flex` to `h_flex().items_stretch()`;
    first child = `status_rail`, second child = a `v_flex` holding the existing
    title row + the `when(has_metadata, ..)` block. Move `py_1/px_1p5` from the
    outer container to that inner `v_flex` (`pr_1p5`). Remove the inline
    `.child(icon)` from the title row and the `icon_container()` spacer from the
    metadata row. Watch parenthesis balance: close the inner `v_flex` child
    before the row-level `tooltip`/`on_click`.

### 4. `crates/project/src/terminals.rs`

- Add `extra_env: HashMap<String, String>` param to
  `create_terminal_shell_internal`; in the spawn closure add
  `env.extend(extra_env);` right after `env.extend(settings.env);` (before the
  remote/local split, so it reaches both).
- Update the two internal callers (`create_terminal_shell`, `create_local_terminal`)
  to pass `HashMap::default()`.
- Add public `create_terminal_shell_with_env(cwd, extra_env, cx)` forwarding to
  the internal. (Avoids touching the ~18 existing `create_terminal_shell` callers.)

### 5. `crates/agent_ui/src/agent_panel.rs`

- In `spawn_terminal`, build
  `extra_env = HashMap::from_iter([("ZED_TERMINAL_ID", terminal_id.to_string())])`
  and call `project.create_terminal_shell_with_env(working_directory, extra_env, cx)`
  instead of `create_terminal_shell`.

### 6. `crates/sidebar/src/cli_agent_status.rs` (new module)

- Reads `${XDG_STATE_HOME:-~/.local/state}/zed/cli-agent-status/*.json` into a
  `HashMap<String /*terminal_id*/, CliAgentStatus>` on a background executor.
  `CliAgentStatus { Running, NeedsInput, Idle, Done, Error }` with
  `to_thread_status()` (Idle/Done → Completed) and `is_idle()`. Ignores files
  older than 6h. `StatusFile { terminal_id, status, ts }`.

### 7. `crates/sidebar/src/sidebar.rs`

- `mod cli_agent_status;` near `mod thread_switcher;`.
- `Sidebar` gains `cli_agent_statuses: HashMap<String, CliAgentStatus>` and a 1s
  background poll task `_cli_agent_status_poll` that calls `update_entries` only
  when the map changes.
- `TerminalEntry` gains `status: AgentThreadStatus` and `agent_idle: bool`.
- In `make_terminal_entry`: look up by `metadata.terminal_id.to_string()`; set
  `status = to_thread_status`, `agent_idle = is_idle()`.
- In `render_terminal`: `.status(terminal.status).agent_idle(terminal.agent_idle)`.

## Matching design (why env token, not pid/cwd)

- cwd collides when several agents run in one directory.
- CLI-agent hooks run DETACHED: no controlling tty (`tpgid=0`), fresh process
  group per invocation — so pid/pgid/tty never map to a row. Verified by a
  debug dump of a real in-Zed hook.
- Inherited ENV does survive into the detached hook (hook saw `ZED_TERM=true`),
  so injecting `ZED_TERMINAL_ID` is reliable. Use `TerminalId::to_string()`
  (public `Display`) on both sides; `to_key_string()` is `pub(crate)` in agent_ui
  and unreachable from the sidebar crate.

## Gotchas

- `ThreadItem` is shared: the rail/icon change also affects the ctrl-tab thread
  switcher, the archive/history view, and the dev component preview. Accepted.
- Archive view has metadata only (no live status) → tolerates default status.
- Keep idle rows untinted (tint = `None`) so the sidebar is not a wall of color.
- Status poll does blocking IO; it runs on `background_spawn` and rebuilds only on
  change. (Possible future: gate on visibility / fs-watch instead of 1s poll.)
- Build via the mise rust toolchain; host cargo may crash on a broken libgit2.

## Process lessons

- Prove cross-process matching keys with a throwaway debug dump BEFORE a full
  rebuild (~4 min each).
- Several Zed/Warp builds + prod `Zed.app` can run at once; the dev build is the
  one launched from the terminal (`target/debug/zed`). Kill it by EXACT exec path
  (`ps axo pid=,comm= | awk '$2==ABS_BIN'`), never `pkill -f target/debug/zed`.

## Dev tooling (not fork code)

- Built-in `LSP` tool + installed `rust-analyzer` cover Rust LSP; no plugin
  needed. The official anthropics plugins dir has no Rust LSP plugin.
