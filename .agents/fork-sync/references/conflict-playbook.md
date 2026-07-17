# Conflict resolution playbook

When `rebase-custom.sh` (or `rebase-continue.sh`) reports `status: "conflict"`,
match each conflicted file against these before resolving from scratch. The
canonical source is `.changes/implementation-notes.md` — this file is a quick
index into it, not a replacement.

## Known recurring patterns (see `.changes/implementation-notes.md` → "Rebase gotchas")

- **`crates/ui/src/components/ai/thread_item.rs` — rail icon size.** The
  `Completed`-status fallback renders `agent_icon`. It must be built as an
  `Icon` at `rail_icon_size` (2.5rem), not `IconSize::Small` — otherwise idle
  rows show a tiny icon while the spinner stays large. `rail_icon_size` must
  be defined before `agent_icon` uses it.
- **`crates/sidebar/src/sidebar.rs` — terminal rail icon.** Never feed
  `icon_char` to terminal `ThreadItem`s. Upstream's `split_leading_icon_char`
  pulls the title's leading glyph into `icon_char`; the rail then renders that
  as a tiny `Label` instead of the full-size Terminal icon. Keep the split's
  stripped title, drop the `.icon_char(..)` call in `render_terminal`.
- **`crates/agent_ui/src/agent_panel.rs` — empty default draft.** Upstream
  blanks the timestamp for `DraftKind::Empty` (one-line row, no action). The
  fork always formats the timestamp (two-line row) and offers the discard
  (`Close`) button for empty drafts too. Also: `activate_draft` returns early
  when `!focus && draft_thread.is_none()` so panel-internal calls (all pass
  `focus=false`) don't fabricate a fresh draft when none exists.
- **`crates/ui/src/components/ai/thread_item.rs` — layout conflict.** Keep the
  fork's title row (`h_6`, a content sub-flex holding only `title_label`, and
  the `action_slot` overlay built from `row_hover_bg`). Shared post-conflict
  code references the fork-only `overlay`/`row_hover_bg` — take the fork side.

## General resolution rules

1. Read the original custom commit's diff for the file: `git show REBASE_HEAD -- <path>`.
   That is ground truth for intent — not what "looks reasonable" against the new upstream code.
2. Reproduce that intent against upstream's current structure. Do not import
   unrelated upstream changes just because they sit near the conflict region.
3. Every resolved file should still carry its `// CUSTOM (fork)` marker(s)
   unless the custom code was intentionally removed by this same commit.
4. If upstream renamed/moved the function or struct the custom code hooks
   into, treat it as an anchor-rot case: resolve conservatively, and flag it
   in the result so `.changes/implementation-notes.md` gets an anchor update
   afterward (not automatic — surface it, a human confirms the doc edit).
5. If the right resolution is genuinely unclear (upstream restructured the
   surrounding code beyond recognition), report `status: "stuck"` rather than
   guessing. A wrong resolution that compiles is worse than an honest stop —
   `git rebase --abort` restores the pre-sync backup tag cleanly.
6. Compile-check the affected crate(s) before continuing:
   `mise exec -- cargo check -p <crate>`.
