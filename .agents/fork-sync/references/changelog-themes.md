# Changelog digest: pitch, not changelog

Goal: tell the fork owner what upstream did that could plausibly touch their
own sidebar/agent-status customizations — nothing else. This is a pitch (a
few sentences), not a themed changelog. Most upstream commits, even ones
mentioning "agent" or "git", are irrelevant here and get screened out
entirely, not summarized into a section.

## Signal: file overlap, not keyword match

`changelog-range.sh` path/keyword-filters the range first (broad net: any
commit touching `crates/agent*`, `crates/assistant*`, `crates/language_model*`,
`crates/project*`, `crates/git*`, `crates/terminal*`, or mentioning those words
in its subject), then flags each filtered commit `touches_fork_files` by
intersecting its changed paths against the fork's own `CUSTOM (fork)` marker
file list (passed in as the marker-census JSON from `preflight.sh`).

That overlap — not the keyword match — is what actually matters. A commit
that touches `crates/agent_ui/src/agent_panel.rs` or `crates/sidebar/src/sidebar.rs`
sits near code the fork changed and is worth a sentence. A commit that adds a
new model provider or tweaks unrelated assistant chat UI is background noise,
even though it matched the keyword filter.

## What the digest agent writes

- A short prose "pitch": 2-6 sentences/fragments, caveman-lite style, about
  the fork-file-touching commits only — what changed, why it might matter,
  PR number inline.
- If nothing in the highlights is actually interesting, say so in one line
  instead of padding it out.
- One trailing clause with a count of how many other upstream commits landed
  in the broader area and were screened out — not a list of them.
- The written file (`.changes/upstream-digest-<date>.md`) stays just the
  pitch. It is not meant to grow into an archive; `.changes/last-sync.json`
  is what makes each run's range correct, not the digest file's history.

## Dedup rules (within the highlight set only)

- Collapse a revert+redo pair (same subject, "Revert" prefix then a
  near-identical re-landed commit) into one line noting the net effect.
- Collapse a PR and its own immediate follow-up fix commits into one bullet,
  referencing the original PR number.
