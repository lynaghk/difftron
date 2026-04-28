use anyhow::Result;
use gix::bstr::ByteSlice;
use serde::Serialize;
use std::{collections::BTreeMap, path::Path};
use tracing::{info, info_span};

use crate::{
    entity_collector::{Entity, entity_kind_name, render_entity},
    snapshot::{DiffResult, ModifiedEntity, Snapshot, SnapshotSpec, snapshot_label},
};

#[derive(Debug, Clone, Copy, Default, Eq, PartialEq, clap::ValueEnum)]
pub enum OutputFormat {
    #[default]
    Text,
    Json,
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
            entity_kind_order: entity_kind_order(),
            entity_kinds: entity_kinds(),
            snapshot: SnapshotOutput::from(snapshot),
            entities: entities
                .entities
                .iter()
                .map(|id| EntityOutput::from(&entities.arena[*id]))
                .collect(),
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
    let _span = info_span!(
        "render_diff",
        format = ?format,
        added = diff.added.len(),
        deleted = diff.deleted.len(),
        modified = diff.modified.len(),
        width = width
    )
    .entered();
    match format {
        OutputFormat::Text => render_diff_text(diff, width),
        OutputFormat::Json => {
            info!("rendering modified entities for json output");
            let modified = diff
                .modified
                .iter()
                .map(ModifiedEntityOutput::try_from_change)
                .collect::<Result<Vec<_>>>()?;
            info!("serializing diff json");
            serde_json::to_string_pretty(&DiffOutput {
                command: "diff",
                entity_kind_order: entity_kind_order(),
                entity_kinds: entity_kinds(),
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
    render_lines(
        snapshot
            .entities
            .iter()
            .map(|id| render_entity(&snapshot.arena[*id])),
    )
}

fn render_lines(lines: impl IntoIterator<Item = String>) -> String {
    let lines = lines.into_iter().collect::<Vec<_>>();
    if lines.is_empty() {
        String::new()
    } else {
        format!("{}\n", lines.join("\n"))
    }
}

fn render_diff_text(diff: &DiffResult, width: Option<usize>) -> Result<String> {
    let _span = info_span!(
        "render_diff_text",
        added = diff.added.len(),
        deleted = diff.deleted.len(),
        modified = diff.modified.len(),
        width = width
    )
    .entered();
    let mut sections = Vec::new();

    for entity in &diff.deleted {
        sections.push(format!("- {}", render_entity(entity)));
    }

    for entity in &diff.added {
        sections.push(format!("+ {}", render_entity(entity)));
    }

    for change in &diff.modified {
        sections.push(crate::minidiff_renderer::render_modified_entity(
            change, width,
        )?);
    }

    Ok(render_sections(sections))
}

fn render_sections(sections: Vec<String>) -> String {
    if sections.is_empty() {
        String::new()
    } else {
        format!("{}\n", sections.join("\n\n"))
    }
}

#[derive(Debug, Serialize)]
struct ListOutput {
    command: &'static str,
    entity_kind_order: &'static [&'static str],
    entity_kinds: BTreeMap<&'static str, EntityKindMetadataOutput>,
    snapshot: SnapshotOutput,
    entities: Vec<EntityOutput>,
}

#[derive(Debug, Serialize)]
struct DiffOutput {
    command: &'static str,
    entity_kind_order: &'static [&'static str],
    entity_kinds: BTreeMap<&'static str, EntityKindMetadataOutput>,
    lhs: SnapshotOutput,
    rhs: SnapshotOutput,
    added: Vec<EntityOutput>,
    deleted: Vec<EntityOutput>,
    modified: Vec<ModifiedEntityOutput>,
}

#[derive(Debug, Clone, Copy, Serialize)]
struct EntityKindMetadataOutput {
    label: &'static str,
    group_label: &'static str,
}

fn entity_kind_order() -> &'static [&'static str] {
    &[
        "struct",
        "enum",
        "union",
        "trait",
        "protocol",
        "record",
        "type",
        "type_alias",
        "function",
        "macro",
        "multimethod",
        "method",
        "var",
        "impl",
        "module",
        "namespace",
    ]
}

fn entity_kinds() -> BTreeMap<&'static str, EntityKindMetadataOutput> {
    BTreeMap::from([
        (
            "struct",
            EntityKindMetadataOutput {
                label: "Struct",
                group_label: "Structs",
            },
        ),
        (
            "enum",
            EntityKindMetadataOutput {
                label: "Enum",
                group_label: "Enums",
            },
        ),
        (
            "union",
            EntityKindMetadataOutput {
                label: "Union",
                group_label: "Unions",
            },
        ),
        (
            "trait",
            EntityKindMetadataOutput {
                label: "Trait",
                group_label: "Traits",
            },
        ),
        (
            "protocol",
            EntityKindMetadataOutput {
                label: "Protocol",
                group_label: "Protocols",
            },
        ),
        (
            "record",
            EntityKindMetadataOutput {
                label: "Record",
                group_label: "Records",
            },
        ),
        (
            "type",
            EntityKindMetadataOutput {
                label: "Type",
                group_label: "Types",
            },
        ),
        (
            "type_alias",
            EntityKindMetadataOutput {
                label: "Type Alias",
                group_label: "Type Aliases",
            },
        ),
        (
            "function",
            EntityKindMetadataOutput {
                label: "Function",
                group_label: "Functions",
            },
        ),
        (
            "macro",
            EntityKindMetadataOutput {
                label: "Macro",
                group_label: "Macros",
            },
        ),
        (
            "multimethod",
            EntityKindMetadataOutput {
                label: "Multimethod",
                group_label: "Multimethods",
            },
        ),
        (
            "method",
            EntityKindMetadataOutput {
                label: "Method",
                group_label: "Methods",
            },
        ),
        (
            "var",
            EntityKindMetadataOutput {
                label: "Var",
                group_label: "Vars",
            },
        ),
        (
            "impl",
            EntityKindMetadataOutput {
                label: "Impl",
                group_label: "Impls",
            },
        ),
        (
            "module",
            EntityKindMetadataOutput {
                label: "Module",
                group_label: "Modules",
            },
        ),
        (
            "namespace",
            EntityKindMetadataOutput {
                label: "Namespace",
                group_label: "Namespaces",
            },
        ),
    ])
}

#[derive(Debug, Serialize)]
struct SnapshotOutput {
    label: String,
    kind: &'static str,
    root: String,
    rev: Option<String>,
    summary: Option<String>,
}

impl From<&SnapshotSpec> for SnapshotOutput {
    fn from(value: &SnapshotSpec) -> Self {
        match value {
            SnapshotSpec::Directory { root } => Self {
                label: snapshot_label(value),
                kind: "directory",
                root: root.display().to_string(),
                rev: None,
                summary: None,
            },
            SnapshotSpec::File { path, .. } => Self {
                label: snapshot_label(value),
                kind: "file",
                root: path.display().to_string(),
                rev: None,
                summary: None,
            },
            SnapshotSpec::GitRevision { repo_root, rev } => Self {
                label: snapshot_label(value),
                kind: "git_revision",
                root: repo_root.display().to_string(),
                rev: Some(rev.clone()),
                summary: commit_summary(repo_root, rev),
            },
        }
    }
}

fn commit_summary(repo_root: &Path, rev: &str) -> Option<String> {
    let repo = gix::open(repo_root).ok()?;
    let commit = repo
        .rev_parse_single(rev)
        .ok()?
        .object()
        .ok()?
        .peel_to_commit()
        .ok()?;
    commit
        .message_raw()
        .ok()?
        .to_str_lossy()
        .lines()
        .next()
        .map(str::trim)
        .filter(|summary| !summary.is_empty())
        .map(str::to_owned)
}

#[derive(Debug, Serialize)]
struct ModifiedEntityOutput {
    path: String,
    lhs: EntityOutput,
    rhs: EntityOutput,
    diff: StructuredDiffOutput,
}

impl ModifiedEntityOutput {
    fn try_from_change(value: &ModifiedEntity) -> Result<Self> {
        Ok(Self {
            path: value.lhs.location.snapshot_path.display().to_string(),
            lhs: EntityOutput::from(&value.lhs),
            rhs: EntityOutput::from(&value.rhs),
            diff: StructuredDiffOutput::try_from_change(value)?,
        })
    }
}

#[derive(Debug, Serialize)]
struct StructuredDiffOutput {
    rows: Vec<StructuredDiffRowOutput>,
}

impl StructuredDiffOutput {
    fn try_from_change(value: &ModifiedEntity) -> Result<Self> {
        let _span = info_span!(
            "render_modified_entity_json",
            entity = %value.lhs.name,
            path = %value.lhs.location.snapshot_path.display()
        )
        .entered();
        let presentation = crate::minidiff_renderer::present_modified_entity(value)?;
        info!(
            rows = presentation.rows.len(),
            "built structured diff presentation"
        );
        Ok(Self {
            rows: presentation
                .rows
                .iter()
                .map(StructuredDiffRowOutput::from)
                .collect(),
        })
    }
}

#[derive(Debug, Serialize)]
struct StructuredDiffRowOutput {
    kind: StructuredDiffChangeKind,
    left: Option<StructuredDiffSideOutput>,
    right: Option<StructuredDiffSideOutput>,
}

impl From<&minidiff::PresentationRow> for StructuredDiffRowOutput {
    fn from(value: &minidiff::PresentationRow) -> Self {
        Self {
            kind: StructuredDiffChangeKind::from(value.kind),
            left: value.left.as_ref().map(StructuredDiffSideOutput::from),
            right: value.right.as_ref().map(StructuredDiffSideOutput::from),
        }
    }
}

#[derive(Debug, Serialize)]
struct StructuredDiffSideOutput {
    line_number: usize,
    text: String,
    segments: Vec<StructuredDiffSegmentOutput>,
}

impl From<&minidiff::PresentationSide> for StructuredDiffSideOutput {
    fn from(value: &minidiff::PresentationSide) -> Self {
        Self {
            line_number: value.line_number,
            text: value.text.clone(),
            segments: value
                .segments
                .iter()
                .map(StructuredDiffSegmentOutput::from)
                .collect(),
        }
    }
}

#[derive(Debug, Serialize)]
struct StructuredDiffSegmentOutput {
    text: String,
    kind: StructuredDiffSegmentKind,
}

impl From<&minidiff::PresentationSegment> for StructuredDiffSegmentOutput {
    fn from(value: &minidiff::PresentationSegment) -> Self {
        Self {
            text: value.text.clone(),
            kind: StructuredDiffSegmentKind::from(value.kind),
        }
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "snake_case")]
enum StructuredDiffChangeKind {
    Unchanged,
    NovelLeft,
    NovelRight,
    ReplacedCode,
    ReplacedComment,
    ReplacedString,
}

impl From<minidiff::PresentationChangeKind> for StructuredDiffChangeKind {
    fn from(value: minidiff::PresentationChangeKind) -> Self {
        match value {
            minidiff::PresentationChangeKind::Unchanged => Self::Unchanged,
            minidiff::PresentationChangeKind::NovelLeft => Self::NovelLeft,
            minidiff::PresentationChangeKind::NovelRight => Self::NovelRight,
            minidiff::PresentationChangeKind::ReplacedCode => Self::ReplacedCode,
            minidiff::PresentationChangeKind::ReplacedComment => Self::ReplacedComment,
            minidiff::PresentationChangeKind::ReplacedString => Self::ReplacedString,
        }
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "snake_case")]
enum StructuredDiffSegmentKind {
    Context,
    Novel,
}

impl From<minidiff::PresentationSegmentKind> for StructuredDiffSegmentKind {
    fn from(value: minidiff::PresentationSegmentKind) -> Self {
        match value {
            minidiff::PresentationSegmentKind::Context => Self::Context,
            minidiff::PresentationSegmentKind::Novel => Self::Novel,
        }
    }
}

#[derive(Debug, Serialize)]
struct EntityOutput {
    name: String,
    kind: &'static str,
    rendered_summary: String,
    file_path: String,
    snapshot_path: String,
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
            snapshot_path: value.location.snapshot_path.display().to_string(),
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
    use std::path::PathBuf;

    use serde_json::Value;

    use super::*;
    use crate::{
        entity_collector::{EntityDetail, SourceLocation},
        languages::rust::RustEntityDetail,
    };

    #[test]
    fn renders_list_json_with_snapshot_metadata() {
        let snapshot_spec = SnapshotSpec::Directory {
            root: PathBuf::from("/tmp/project"),
        };
        let snapshot = snapshot_from_entities(vec![sample_entity("crate::demo", "src/lib.rs")]);

        let rendered = render_list(&snapshot_spec, &snapshot, OutputFormat::Json).unwrap();
        let json: Value = serde_json::from_str(&rendered).unwrap();

        assert_eq!(json["command"], "list");
        assert_eq!(
            json["entity_kind_order"]
                .as_array()
                .unwrap()
                .iter()
                .map(|kind| kind.as_str().unwrap())
                .collect::<Vec<_>>(),
            vec![
                "struct",
                "enum",
                "union",
                "trait",
                "protocol",
                "record",
                "type",
                "type_alias",
                "function",
                "macro",
                "multimethod",
                "method",
                "var",
                "impl",
                "module",
                "namespace"
            ]
        );
        assert_eq!(json["entity_kinds"]["function"]["group_label"], "Functions");
        assert_eq!(json["snapshot"]["kind"], "directory");
        assert_eq!(json["entities"][0]["kind"], "function");
        assert_eq!(json["entities"][0]["snapshot_path"], "src/lib.rs");
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

        let rendered = render_diff(&lhs, &rhs, &diff, OutputFormat::Json, None).unwrap();
        let json: Value = serde_json::from_str(&rendered).unwrap();

        assert_eq!(json["command"], "diff");
        assert_eq!(json["entity_kinds"]["struct"]["label"], "Struct");
        assert_eq!(json["lhs"]["rev"], "HEAD~1");
        assert_eq!(json["rhs"]["rev"], "HEAD");
        assert_eq!(json["added"][0]["name"], "crate::added");
        assert_eq!(json["modified"][0]["lhs"]["name"], "crate::changed");
        assert!(json["modified"][0].get("diff_display").is_none());
        assert_eq!(
            json["modified"][0]["diff"]["rows"][0]["kind"],
            "replaced_code"
        );
        assert_eq!(
            json["modified"][0]["diff"]["rows"][0]["left"]["segments"][1]["kind"],
            "novel"
        );
        assert!(
            json["modified"][0]["diff"]["rows"][0]["right"]["segments"]
                .as_array()
                .unwrap()
                .iter()
                .any(|segment| segment["kind"] == "novel")
        );
        assert_eq!(
            json["modified"][0]["rhs"]["source_text"],
            "fn changed() -> u32 { 2 }"
        );
    }

    #[test]
    fn renders_list_text_compatibly() {
        let snapshot = snapshot_from_entities(vec![sample_entity("crate::demo", "src/lib.rs")]);

        let rendered = render_list_text(&snapshot);

        assert_eq!(
            rendered,
            "function crate::demo() @ /tmp/project/src/lib.rs:1:1-1:20\n"
        );
    }

    fn sample_entity(name: &str, relative_path: &str) -> Entity {
        Entity {
            name: name.to_owned(),
            parent: None,
            language: minidiff::Language::Rust,
            location: SourceLocation {
                file_path: PathBuf::from(format!("/tmp/project/{relative_path}")),
                snapshot_path: PathBuf::from(relative_path),
                start_line: 1,
                start_col: 1,
                end_line: 1,
                end_col: 20,
            },
            source_text: "fn demo() {}".to_owned(),
            detail: EntityDetail::Rust(RustEntityDetail::Function {
                signature: "()".to_owned(),
            }),
        }
    }

    fn snapshot_from_entities(values: Vec<Entity>) -> Snapshot {
        let mut arena = id_arena::Arena::new();
        let entities = values
            .into_iter()
            .map(|entity| arena.alloc(entity))
            .collect();
        Snapshot { arena, entities }
    }
}
