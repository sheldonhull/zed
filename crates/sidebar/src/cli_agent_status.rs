//! CUSTOM (fork): read CLI-agent (Claude Code) session status from a side-channel
//! status directory and map it to the sidebar's [`AgentThreadStatus`].
//!
//! The companion Claude Code plugin (`tooling/zed-cli-agent-status`) writes one
//! JSON file per terminal, keyed by the `ZED_TERMINAL_ID` the agent inherits from
//! its terminal env. The sidebar polls this directory and matches each terminal
//! row by id, so multiple agents in one directory stay distinct.

use std::{
    collections::HashMap,
    fs,
    path::PathBuf,
    time::{SystemTime, UNIX_EPOCH},
};

use serde::Deserialize;
use ui::AgentThreadStatus;

/// Status files older than this are treated as stale and ignored, so a crashed
/// session that never wrote a terminal state does not pin a row to "running".
const STALE_AFTER_SECS: u64 = 6 * 60 * 60;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum CliAgentStatus {
    Running,
    NeedsInput,
    Idle,
    Done,
    Error,
}

impl CliAgentStatus {
    fn parse(raw: &str) -> Option<Self> {
        Some(match raw {
            "running" => Self::Running,
            "needs_input" => Self::NeedsInput,
            "idle" => Self::Idle,
            "done" => Self::Done,
            "error" => Self::Error,
            _ => return None,
        })
    }

    /// True when the agent is present but not actively working (idle or done).
    /// Used to show a "quiet" icon distinct from a plain terminal.
    pub(crate) fn is_idle(self) -> bool {
        matches!(self, Self::Idle | Self::Done)
    }

    pub(crate) fn to_thread_status(self) -> AgentThreadStatus {
        match self {
            Self::Running => AgentThreadStatus::Running,
            Self::NeedsInput => AgentThreadStatus::WaitingForConfirmation,
            Self::Error => AgentThreadStatus::Error,
            // Idle and Done leave the row untinted (mirrors an idle native thread).
            Self::Idle | Self::Done => AgentThreadStatus::Completed,
        }
    }
}

#[derive(Deserialize)]
struct StatusFile {
    /// The `ZED_TERMINAL_ID` the agent inherited from its terminal. Matched
    /// against each terminal row's id. This is the primary key.
    terminal_id: String,
    status: String,
    #[serde(default)]
    ts: u64,
}

/// `${XDG_STATE_HOME:-$HOME/.local/state}/zed/cli-agent-status`.
fn status_dir() -> Option<PathBuf> {
    let base = match std::env::var_os("XDG_STATE_HOME") {
        Some(value) if !value.is_empty() => PathBuf::from(value),
        _ => {
            let home = std::env::var_os("HOME")?;
            PathBuf::from(home).join(".local").join("state")
        }
    };
    Some(base.join("zed").join("cli-agent-status"))
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs())
        .unwrap_or(0)
}

/// Read every status file in the directory into a `terminal_id -> status` map.
/// Performs blocking file IO and is intended to run on a background executor.
pub(crate) fn read_all() -> HashMap<String, CliAgentStatus> {
    let mut statuses = HashMap::new();
    let Some(dir) = status_dir() else {
        return statuses;
    };
    let Ok(entries) = fs::read_dir(&dir) else {
        return statuses;
    };
    let now = now_secs();
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("json") {
            continue;
        }
        let Ok(bytes) = fs::read(&path) else {
            continue;
        };
        let Ok(parsed) = serde_json::from_slice::<StatusFile>(&bytes) else {
            continue;
        };
        if parsed.ts != 0 && now.saturating_sub(parsed.ts) > STALE_AFTER_SECS {
            continue;
        }
        let Some(status) = CliAgentStatus::parse(&parsed.status) else {
            continue;
        };
        statuses.insert(parsed.terminal_id, status);
    }
    statuses
}
