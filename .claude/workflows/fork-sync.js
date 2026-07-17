export const meta = {
  name: 'fork-sync',
  description: 'Sync fork main with upstream zed-industries/zed, rebase the fork-custom commits, verify, digest the changelog, and build.',
  whenToUse: 'Run periodically to pull fresh upstream Zed into this fork: fast-forwards main, replays the ~dozen fork-custom commits via rebase --onto with rerere-assisted conflict resolution, verifies CUSTOM(fork) markers + tests survive, writes a themed changelog digest, and kicks off the release build. Pass {timestamp: "YYYYMMDD-HHMMSS"} as args (scripts cannot call Date.now()).',
  phases: [
    { title: 'Preflight' },
    { title: 'Sync main' },
    { title: 'Rebase' },
    { title: 'Resolve conflicts' },
    { title: 'Verify' },
    { title: 'Changelog' },
    { title: 'Build' },
  ],
}

const SCRIPTS = '.agents/fork-sync/scripts'
const NOTES = '.changes/implementation-notes.md'
const PLAYBOOK = '.agents/fork-sync/references/conflict-playbook.md'
const THEMES = '.agents/fork-sync/references/changelog-themes.md'

const PREFLIGHT_SCHEMA = {
  type: 'object',
  properties: {
    ok: { type: 'boolean' },
    clean_tree: { type: 'boolean' },
    rebase_in_progress: { type: 'boolean' },
    is_shallow: { type: 'boolean' },
    current_branch: { type: 'string' },
    upstream_remote_ok: { type: 'boolean' },
    backup_tag: { type: ['string', 'null'] },
    marker_census: { type: 'object' },
    last_sync_base: {},
    errors: { type: 'array', items: { type: 'string' } },
  },
  required: ['ok', 'errors'],
}

const SYNC_MAIN_SCHEMA = {
  type: 'object',
  properties: {
    ok: { type: 'boolean' },
    old_main_sha: { type: 'string' },
    new_upstream_sha: { type: 'string' },
    up_to_date: { type: 'boolean' },
    errors: { type: 'array', items: { type: 'string' } },
  },
  required: ['ok', 'errors'],
}

const REBASE_SCHEMA = {
  type: 'object',
  properties: {
    status: { type: 'string', enum: ['clean', 'conflict', 'error'] },
    base_sha: { type: 'string' },
    replayed_count: { type: 'number' },
    expected_custom_count: { type: 'number' },
    count_mismatch: { type: 'boolean' },
    conflicted_files: { type: 'array', items: { type: 'string' } },
    current_commit_subject: { type: 'string' },
    errors: { type: 'array', items: { type: 'string' } },
  },
  required: ['status'],
}

const RESOLVE_SCHEMA = {
  type: 'object',
  properties: {
    status: { type: 'string', enum: ['clean', 'conflict', 'stuck', 'error'] },
    replayed_count: { type: 'number' },
    conflicted_files: { type: 'array', items: { type: 'string' } },
    current_commit_subject: { type: 'string' },
    reason: { type: 'string' },
    anchor_rot_notes: { type: 'string' },
  },
  required: ['status'],
}

const ABORT_SCHEMA = {
  type: 'object',
  properties: {
    ok: { type: 'boolean' },
    head_sha: { type: 'string' },
    backup_sha: { type: 'string' },
  },
  required: ['ok'],
}

const VERIFY_SCHEMA = {
  type: 'object',
  properties: {
    ok: { type: 'boolean' },
    markers_ok: { type: 'boolean' },
    marker_diff: { type: 'object' },
    check_ok: { type: 'boolean' },
    check_log_tail: { type: 'string' },
    sidebar_ok: { type: 'boolean' },
    sidebar_log_tail: { type: 'string' },
    ui_ok: { type: 'boolean' },
    ui_log_tail: { type: 'string' },
  },
  required: ['ok'],
}

const RAW_RANGE_SCHEMA = {
  type: 'object',
  properties: {
    total_commits_in_range: { type: 'number' },
    filtered_commits: { type: 'array' },
  },
  required: ['total_commits_in_range', 'filtered_commits'],
}

const DIGEST_SCHEMA = {
  type: 'object',
  properties: {
    pitch: { type: 'string' },
    digest_path: { type: 'string' },
    highlight_count: { type: 'number' },
    other_count: { type: 'number' },
    record_sync_output: { type: 'object' },
  },
  required: ['pitch', 'digest_path'],
}

const BUILD_SCHEMA = {
  type: 'object',
  properties: {
    ok: { type: 'boolean' },
    bundle_path: { type: 'string' },
    log_tail: { type: 'string' },
  },
  required: ['ok'],
}

// --- Preflight ---
phase('Preflight')
const timestamp = args && args.timestamp
if (!timestamp) {
  return { ok: false, stage: 'args', errors: ['args.timestamp is required, e.g. Workflow({name:"fork-sync", args:{timestamp:"20260715-1400"}})'] }
}

const preflight = await agent(
  `Run \`bash ${SCRIPTS}/preflight.sh ${timestamp}\` from the repo root. ` +
  `The script is fully deterministic — just execute it and return its JSON stdout verbatim as your structured result. Do not modify anything yourself, do not reinterpret the output.`,
  { schema: PREFLIGHT_SCHEMA, label: 'preflight' }
)
if (!preflight || !preflight.ok) {
  log(`Preflight failed: ${preflight ? preflight.errors.join('; ') : 'agent returned null'}`)
  return { ok: false, stage: 'preflight', preflight }
}
log(`Preflight OK on branch ${preflight.current_branch}; backup tag ${preflight.backup_tag}`)

// --- Sync main ---
phase('Sync main')
const syncMain = await agent(
  `Run \`bash ${SCRIPTS}/sync-main.sh\` from the repo root. Deterministic script — return its JSON stdout verbatim.`,
  { schema: SYNC_MAIN_SCHEMA, label: 'sync-main' }
)
if (!syncMain || !syncMain.ok) {
  log(`Sync main failed: ${syncMain ? syncMain.errors.join('; ') : 'agent returned null'}`)
  return { ok: false, stage: 'sync-main', preflight, syncMain }
}
log(syncMain.up_to_date ? 'main already up to date with upstream' : `main fast-forwarded ${syncMain.old_main_sha.slice(0, 8)} -> ${syncMain.new_upstream_sha.slice(0, 8)}`)

// --- Rebase ---
phase('Rebase')
let rebaseResult = await agent(
  `Run \`bash ${SCRIPTS}/rebase-custom.sh\` from the repo root. Deterministic script — return its JSON stdout verbatim.`,
  { schema: REBASE_SCHEMA, label: 'rebase-start' }
)

// --- Resolve conflicts (bounded loop; each iteration is genuine agent judgment) ---
const MAX_ATTEMPTS = 20
let attempts = 0
const conflictLog = []
while (rebaseResult && rebaseResult.status === 'conflict' && attempts < MAX_ATTEMPTS) {
  attempts++
  phase('Resolve conflicts')
  log(`Conflict on commit "${rebaseResult.current_commit_subject}" (attempt ${attempts}): ${rebaseResult.conflicted_files.join(', ')}`)
  const resolution = await agent(
    `A git rebase is paused with conflicts in these files: ${JSON.stringify(rebaseResult.conflicted_files)}. ` +
    `The commit being replayed is "${rebaseResult.current_commit_subject}".\n\n` +
    `Steps:\n` +
    `1. Read ${NOTES} (the "Rebase gotchas" section) and ${PLAYBOOK} to find the matching pattern for each conflicted file.\n` +
    `2. For each conflicted file: inspect conflict markers (grep -n '<<<<<<<\\|=======\\|>>>>>>>' <path>), read the original custom commit's intent (git show REBASE_HEAD -- <path>), and resolve so upstream's new code still carries that intent. Never pull in unrelated upstream changes near the conflict region.\n` +
    `3. Run \`mise exec -- cargo check -p <crate>\` for each touched crate to confirm it compiles.\n` +
    `4. git add the resolved files.\n` +
    `5. Run \`bash ${SCRIPTS}/rebase-continue.sh\` and return its JSON stdout verbatim as your result.\n\n` +
    `If the correct resolution is genuinely unclear (upstream restructured beyond recognition), do NOT guess — do not run rebase-continue.sh, and instead return {"status": "stuck", "reason": "<why>"}. If you had to resolve past renamed/moved anchors that ${NOTES} references, include a one-line "anchor_rot_notes" describing what should be updated in that doc.`,
    { schema: RESOLVE_SCHEMA, phase: 'Resolve conflicts', label: `resolve-${attempts}`, effort: 'high' }
  )
  conflictLog.push({ attempt: attempts, files: rebaseResult.conflicted_files, commit: rebaseResult.current_commit_subject, resolution })
  if (!resolution || resolution.status === 'stuck' || resolution.status === 'error') {
    log(`Resolution ${attempts} did not succeed (${resolution ? resolution.status : 'null'}); aborting rebase and restoring backup.`)
    const abort = await agent(
      `Run \`bash ${SCRIPTS}/rebase-abort.sh ${preflight.backup_tag}\` from the repo root. Return its JSON stdout verbatim.`,
      { schema: ABORT_SCHEMA, label: 'abort' }
    )
    return { ok: false, stage: 'rebase-stuck', preflight, syncMain, conflictLog, abort }
  }
  rebaseResult = resolution
}

if (!rebaseResult || rebaseResult.status !== 'clean') {
  log(`Rebase did not converge after ${attempts} attempt(s); aborting and restoring backup.`)
  const abort = await agent(
    `Run \`bash ${SCRIPTS}/rebase-abort.sh ${preflight.backup_tag}\` from the repo root. Return its JSON stdout verbatim.`,
    { schema: ABORT_SCHEMA, label: 'abort-exhausted' }
  )
  return { ok: false, stage: 'rebase-exhausted', preflight, syncMain, conflictLog, abort }
}

if (rebaseResult.count_mismatch) {
  log(`WARNING: replayed commit count (${rebaseResult.replayed_count}) != pre-rebase custom count (${rebaseResult.expected_custom_count}). A commit likely failed to auto-drop as an upstream duplicate. Proceeding to verify, but flag this for manual review before trusting the result.`)
}

// --- Verify ---
phase('Verify')
const verify = await agent(
  `Run \`bash ${SCRIPTS}/verify.sh '${JSON.stringify(preflight.marker_census)}'\` from the repo root (single-quote the JSON argument exactly as shown). Deterministic script — return its JSON stdout verbatim.`,
  { schema: VERIFY_SCHEMA, label: 'verify' }
)
if (!verify || !verify.ok) {
  log('Verify failed: marker census drifted or mise check/test-sidebar/test-ui failed. NOT aborting automatically — the rebase is complete and inspectable; fix forward or abort manually.')
  return { ok: false, stage: 'verify-failed', preflight, syncMain, rebaseResult, conflictLog, verify }
}
log('Verify passed: markers intact, mise check + test-sidebar + test-ui green.')

// --- Changelog (parallel with Build; independent once verify passes) ---
const baseForChangelog = (preflight.last_sync_base && preflight.last_sync_base !== null)
  ? preflight.last_sync_base
  : syncMain.old_main_sha

const [changelog, build] = await parallel([
  async () => {
    const raw = await agent(
      `Run \`bash ${SCRIPTS}/changelog-range.sh ${baseForChangelog} ${syncMain.new_upstream_sha} '${JSON.stringify(preflight.marker_census)}'\` from the repo root (single-quote the JSON third argument exactly as shown). Deterministic script — return its JSON stdout verbatim.`,
      { schema: RAW_RANGE_SCHEMA, phase: 'Changelog', label: 'changelog-range' }
    )
    if (!raw) return null
    const highlights = raw.filtered_commits.filter(c => c.touches_fork_files)
    const others = raw.filtered_commits.filter(c => !c.touches_fork_files)
    const digest = await agent(
      `You're writing a short PITCH, not a changelog. Audience: the fork owner who built the agent-sidebar status/tint work in this repo (rail icons, live status tint, thread/terminal rows, draft-close behavior). They care about upstream changes that touch THEIR code or could affect it — everything else is noise to them.\n\n` +
      `Commits that touch one of the fork's customized files (from the range ${baseForChangelog}..${syncMain.new_upstream_sha}): ${JSON.stringify(highlights)}\n\n` +
      `Everything else in the fork-relevant path/keyword filter but NOT touching those files (${others.length} commits, background context only, do not enumerate individually): ${JSON.stringify(others.map(c => c.subject))}\n\n` +
      `Read ${THEMES} for the full dedup rules (collapse revert+redo pairs, collapse a PR with its own follow-up fixes). Write "pitch": 2-6 short sentences/fragments, caveman-lite style (terse, active voice, no filler) — call out only the highlights above that plausibly matter (new behavior near the rail/tint/status/draft code, a refactor that could conflict with the rebase, a relevant bug fix). Reference PR numbers inline like (#12345). If NONE of the highlights are actually interesting (e.g. a one-line unrelated rename in a shared file), say so briefly instead of padding — don't manufacture significance. End the pitch with one clause noting how many other upstream commits landed in the broader agent/git/terminal/project area that were screened out as not relevant (a count, not a list).\n\n` +
      `Then write a short markdown file to .changes/upstream-digest-${timestamp}.md containing just the pitch prose (a "## Highlights" heading + the pitch text is enough — do not add themed sections or a full commit list; this is meant to stay short forever, not grow into a changelog archive).\n\n` +
      `Then run \`bash ${SCRIPTS}/record-sync.sh ${syncMain.new_upstream_sha} .changes/upstream-digest-${timestamp}.md ${timestamp}\` and return its JSON stdout under "record_sync_output", plus pitch, digest_path, highlight_count (${highlights.length}), and other_count (${others.length}).`,
      { schema: DIGEST_SCHEMA, phase: 'Changelog', label: 'changelog-digest' }
    )
    return digest
  },
  () => agent(
    `Run \`mise run build:prod\` from the repo root and wait for it to finish (release build; can take several minutes). This is background-safe and does NOT copy anything to /Applications or touch a running Zed Custom — do not run publish or publish:install, those require the user to quit their running app first and are handled outside this workflow. Report the bundle path it records and whether it succeeded.`,
    { schema: BUILD_SCHEMA, phase: 'Build', label: 'build-prod' }
  ),
])

// Reporting order for whoever consumes this result: brief rebase/verify
// status, then build.bundle_path, then changelog.pitch near-verbatim
// (fork-relevant highlights only — not a full changelog), then LAST the
// install prompt — so "here's what's new that matters to you" lands right
// before "quit Zed Custom and reinstall to see it."
return {
  ok: true,
  backup_tag: preflight.backup_tag,
  old_main_sha: syncMain.old_main_sha,
  new_upstream_sha: syncMain.new_upstream_sha,
  replayed_count: rebaseResult.replayed_count,
  count_mismatch: rebaseResult.count_mismatch,
  conflict_attempts: attempts,
  verify,
  changelog,
  build,
  install_pending: true,
  install_note: 'Ask the user to confirm before mise run publish:install — it requires quitting their running Zed Custom. After install, tell them to relaunch Zed Custom to see it.',
  report_order: [
    'rebase/verify status + replayed_count',
    'build.bundle_path',
    'changelog.pitch verbatim (fork-relevant highlights only)',
    'install prompt last (see install_note)',
  ],
}
