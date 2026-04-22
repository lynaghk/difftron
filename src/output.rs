use anyhow::Result;
use serde::Serialize;

use crate::{
    entity_collector::{Entity, entity_kind_name, render_entity},
    snapshot::{DiffResult, ModifiedEntity, Snapshot, SnapshotSpec, snapshot_label},
};

#[derive(Debug, Clone, Copy, Eq, PartialEq, clap::ValueEnum)]
pub enum OutputFormat {
    Text,
    Json,
}

impl Default for OutputFormat {
    fn default() -> Self {
        Self::Text
    }
}

pub fn render_list(
    snapshot: &SnapshotSpec,
    entities: &Snapshot,
    format: OutputFormat,
) -> Result<String> {
    match format {
        OutputFormat::Text => Ok(render_list_text(entities)),
        OutputFormat::Json => serde_json::to_string_pretty(&ListOutput {
            command: "list",
            snapshot: SnapshotOutput::from(snapshot),
            entities: entities.entities.iter().map(EntityOutput::from).collect(),
        })
        .map_err(Into::into),
    }
}

pub fn render_diff(
    lhs: &SnapshotSpec,
    rhs: &SnapshotSpec,
    diff: &DiffResult,
    format: OutputFormat,
    width: Option<usize>,
) -> Result<String> {
    match format {
        OutputFormat::Text => render_diff_text(diff, width),
        OutputFormat::Json => {
            let modified = diff
                .modified
                .iter()
                .map(|change| ModifiedEntityOutput::try_from_change(change, width))
                .collect::<Result<Vec<_>>>()?;
            serde_json::to_string_pretty(&DiffOutput {
                command: "diff",
                lhs: SnapshotOutput::from(lhs),
                rhs: SnapshotOutput::from(rhs),
                added: diff.added.iter().map(EntityOutput::from).collect(),
                deleted: diff.deleted.iter().map(EntityOutput::from).collect(),
                modified,
            })
            .map_err(Into::into)
        }
    }
}

fn render_list_text(snapshot: &Snapshot) -> String {
    let lines = snapshot
        .entities
        .iter()
        .map(render_entity)
        .collect::<Vec<_>>();
    render_lines(lines)
}

fn render_diff_text(diff: &DiffResult, width: Option<usize>) -> Result<String> {
    let mut sections = Vec::new();

    for entity in &diff.deleted {
        sections.push(format!("- {}", render_entity(entity)));
    }

    for entity in &diff.added {
        sections.push(format!("+ {}", render_entity(entity)));
    }

    for change in &diff.modified {
        sections.push(crate::difftastic_renderer::render_modified_entity(
            change, width,
        )?);
    }

    if sections.is_empty() {
        Ok(String::new())
    } else {
        Ok(format!("{}\n", sections.join("\n\n")))
    }
}

fn render_lines(lines: Vec<String>) -> String {
    if lines.is_empty() {
        String::new()
    } else {
        format!("{}\n", lines.join("\n"))
    }
}

#[derive(Debug, Serialize)]
struct ListOutput {
    command: &'static str,
    snapshot: SnapshotOutput,
    entities: Vec<EntityOutput>,
}

#[derive(Debug, Serialize)]
struct DiffOutput {
    command: &'static str,
    lhs: SnapshotOutput,
    rhs: SnapshotOutput,
    added: Vec<EntityOutput>,
    deleted: Vec<EntityOutput>,
    modified: Vec<ModifiedEntityOutput>,
}

#[derive(Debug, Serialize)]
struct SnapshotOutput {
    label: String,
    kind: &'static str,
    root: String,
    rev: Option<String>,
}

impl From<&SnapshotSpec> for SnapshotOutput {
    fn from(value: &SnapshotSpec) -> Self {
        match value {
            SnapshotSpec::Directory { root } => Self {
                label: snapshot_label(value),
                kind: "directory",
                root: root.display().to_string(),
                rev: None,
            },
            SnapshotSpec::GitRevision { repo_root, rev } => Self {
                label: snapshot_label(value),
                kind: "git_revision",
                root: repo_root.display().to_string(),
                rev: Some(rev.clone()),
            },
        }
    }
}

#[derive(Debug, Serialize)]
struct ModifiedEntityOutput {
    path: String,
    lhs: EntityOutput,
    rhs: EntityOutput,
    difftastic_display: String,
}

impl ModifiedEntityOutput {
    fn try_from_change(value: &ModifiedEntity, width: Option<usize>) -> Result<Self> {
        Ok(Self {
            path: value.lhs.location.relative_path.display().to_string(),
            lhs: EntityOutput::from(&value.lhs),
            rhs: EntityOutput::from(&value.rhs),
            difftastic_display: crate::difftastic_renderer::render_modified_entity(value, width)?,
        })
    }
}

#[derive(Debug, Serialize)]
struct EntityOutput {
    name: String,
    kind: &'static str,
    rendered_summary: String,
    file_path: String,
    relative_path: String,
    start_line: u32,
    start_col: u32,
    end_line: u32,
    end_col: u32,
    source_text: String,
}

impl From<&Entity> for EntityOutput {
    fn from(value: &Entity) -> Self {
        Self {
            name: value.name.clone(),
            kind: entity_kind_name(&value.detail),
            rendered_summary: render_entity(value),
            file_path: value.location.file_path.display().to_string(),
            relative_path: value.location.relative_path.display().to_string(),
            start_line: value.location.start_line,
            start_col: value.location.start_col,
            end_line: value.location.end_line,
            end_col: value.location.end_col,
            source_text: value.source_text.clone(),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::{
        fs,
        os::unix::fs::PermissionsExt,
        path::{Path, PathBuf},
        sync::{Mutex, OnceLock},
    };

    use serde_json::Value;
    use tempfile::TempDir;

    use super::*;
    use crate::entity_collector::{EntityDetail, SourceLocation};

    #[test]
    fn renders_list_json_with_snapshot_metadata() {
        let snapshot_spec = SnapshotSpec::Directory {
            root: PathBuf::from("/tmp/project"),
        };
        let snapshot = Snapshot {
            entities: vec![sample_entity("crate::demo", "src/lib.rs")],
        };

        let rendered = render_list(&snapshot_spec, &snapshot, OutputFormat::Json).unwrap();
        let json: Value = serde_json::from_str(&rendered).unwrap();

        assert_eq!(json["command"], "list");
        assert_eq!(json["snapshot"]["kind"], "directory");
        assert_eq!(json["entities"][0]["kind"], "function");
        assert_eq!(json["entities"][0]["relative_path"], "src/lib.rs");
    }

    #[test]
    fn renders_diff_json_with_modified_payloads() {
        let lhs = SnapshotSpec::GitRevision {
            repo_root: PathBuf::from("/tmp/project"),
            rev: "HEAD~1".to_owned(),
        };
        let rhs = SnapshotSpec::GitRevision {
            repo_root: PathBuf::from("/tmp/project"),
            rev: "HEAD".to_owned(),
        };
        let diff = DiffResult {
            added: vec![sample_entity("crate::added", "src/lib.rs")],
            deleted: Vec::new(),
            modified: vec![ModifiedEntity {
                lhs: sample_entity("crate::changed", "src/lib.rs"),
                rhs: Entity {
                    source_text: "fn changed() -> u32 { 2 }".to_owned(),
                    ..sample_entity("crate::changed", "src/lib.rs")
                },
            }],
        };

        let _guard = difftastic_test_lock().lock().unwrap();
        let previous = std::env::var_os("RUST_DIVE_DIFFT_PATH");
        let mock = MockDifftastic::new("mock difftastic");
        unsafe {
            std::env::set_var("RUST_DIVE_DIFFT_PATH", mock.path());
        }
        let rendered = render_diff(&lhs, &rhs, &diff, OutputFormat::Json, None).unwrap();
        restore_difftastic_env(previous);
        let json: Value = serde_json::from_str(&rendered).unwrap();

        assert_eq!(json["command"], "diff");
        assert_eq!(json["lhs"]["rev"], "HEAD~1");
        assert_eq!(json["rhs"]["rev"], "HEAD");
        assert_eq!(json["added"][0]["name"], "crate::added");
        assert_eq!(json["modified"][0]["lhs"]["name"], "crate::changed");
        assert_eq!(json["modified"][0]["difftastic_display"], "mock difftastic");
        assert_eq!(
            json["modified"][0]["rhs"]["source_text"],
            "fn changed() -> u32 { 2 }"
        );
    }

    #[test]
    fn renders_list_text_compatibly() {
        let snapshot = Snapshot {
            entities: vec![sample_entity("crate::demo", "src/lib.rs")],
        };

        let rendered = render_list_text(&snapshot);

        assert_eq!(
            rendered,
            "function crate::demo() @ /tmp/project/src/lib.rs:1:1-1:20\n"
        );
    }

    fn sample_entity(name: &str, relative_path: &str) -> Entity {
        Entity {
            name: name.to_owned(),
            location: SourceLocation {
                file_path: PathBuf::from(format!("/tmp/project/{relative_path}")),
                relative_path: PathBuf::from(relative_path),
                start_line: 1,
                start_col: 1,
                end_line: 1,
                end_col: 20,
            },
            source_text: "fn demo() {}".to_owned(),
            detail: EntityDetail::Function {
                signature: "()".to_owned(),
            },
        }
    }

    fn difftastic_test_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    fn restore_difftastic_env(previous: Option<std::ffi::OsString>) {
        match previous {
            Some(value) => unsafe {
                std::env::set_var("RUST_DIVE_DIFFT_PATH", value);
            },
            None => unsafe {
                std::env::remove_var("RUST_DIVE_DIFFT_PATH");
            },
        }
    }

    struct MockDifftastic {
        _dir: TempDir,
        path: PathBuf,
    }

    impl MockDifftastic {
        fn new(output: &str) -> Self {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("mock-difft");
            let script = format!("#!/usr/bin/env bash\nprintf {}\n", shell_quote(output));
            fs::write(&path, script).unwrap();
            let mut permissions = fs::metadata(&path).unwrap().permissions();
            permissions.set_mode(0o755);
            fs::set_permissions(&path, permissions).unwrap();
            Self { _dir: dir, path }
        }

        fn path(&self) -> &Path {
            &self.path
        }
    }

    fn shell_quote(value: &str) -> String {
        format!("'{}'", value.replace('\'', "'\"'\"'"))
    }
}
