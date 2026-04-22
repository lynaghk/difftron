use std::{
    collections::{BTreeMap, BTreeSet},
    path::{Path, PathBuf},
};

use anyhow::{Context, Result};
use tracing::{info, info_span};

use crate::{
    entity_collector::{Entity, EntityDetail, collect_entities},
    project_discovery::TargetRoot,
    project_discovery::discover_targets,
    source_repo::{FsSourceRepo, GitTreeSourceRepo, SingleFileSourceRepo, SourceRepo},
};

#[derive(Debug, Clone)]
pub enum SnapshotSpec {
    Directory {
        root: PathBuf,
    },
    File {
        path: PathBuf,
        display_base: Option<PathBuf>,
    },
    GitRevision {
        repo_root: PathBuf,
        rev: String,
    },
}

#[derive(Debug, Clone)]
pub struct Snapshot {
    pub entities: Vec<Entity>,
}

#[derive(Debug, Clone)]
pub struct DiffResult {
    pub added: Vec<Entity>,
    pub deleted: Vec<Entity>,
    pub modified: Vec<ModifiedEntity>,
}

#[derive(Debug, Clone)]
pub struct ModifiedEntity {
    pub lhs: Entity,
    pub rhs: Entity,
}

pub fn resolve_snapshot_spec(arg: &str, cwd: &Path) -> Result<SnapshotSpec> {
    let candidate = PathBuf::from(arg);
    let cwd = cwd
        .canonicalize()
        .with_context(|| format!("failed to resolve {}", cwd.display()))?;
    let resolved = if candidate.is_absolute() {
        candidate
    } else {
        cwd.join(candidate)
    };

    if resolved.exists() {
        if resolved.is_file() {
            let path = resolved
                .canonicalize()
                .with_context(|| format!("failed to resolve {}", resolved.display()))?;
            let display_base = path_starts_with(&path, &cwd).then_some(cwd.clone());
            return Ok(SnapshotSpec::File { path, display_base });
        }
        if resolved.is_dir() {
            return Ok(SnapshotSpec::Directory {
                root: resolved
                    .canonicalize()
                    .with_context(|| format!("failed to resolve {}", resolved.display()))?,
            });
        }
    }

    let repo = gix::discover(&cwd).with_context(|| {
        format!("{arg} is not a directory and {cwd:?} is not inside a git repository")
    })?;
    let repo_root = repo_workdir(&repo)?;
    repo.rev_parse_single(arg).with_context(|| {
        format!(
            "{arg} is not a valid git revision in {}",
            repo_root.display()
        )
    })?;

    Ok(SnapshotSpec::GitRevision {
        repo_root,
        rev: arg.to_owned(),
    })
}

pub fn build_snapshot(spec: &SnapshotSpec) -> Result<Snapshot> {
    let label = snapshot_label(spec);
    let _span = info_span!("build_snapshot", snapshot = %label).entered();

    let source = open_source_repo(spec)?;
    info!(root = %source.root().display(), "discovering targets");
    let targets = discover_snapshot_targets(spec, source.as_ref())?;
    info!(target_count = targets.len(), "discovered targets");
    let entities = collect_entities(source.as_ref(), &targets)?;

    Ok(Snapshot { entities })
}

pub fn diff_snapshots(lhs: &Snapshot, rhs: &Snapshot, path_filters: &[PathBuf]) -> DiffResult {
    let _span = info_span!(
        "diff_snapshots",
        lhs_entities = lhs.entities.len(),
        rhs_entities = rhs.entities.len(),
        filter_count = path_filters.len()
    )
    .entered();

    let lhs_entities = filtered_entities(lhs, path_filters);
    let rhs_entities = filtered_entities(rhs, path_filters);

    let mut lhs_by_identity = group_by_identity(lhs_entities);
    let mut rhs_by_identity = group_by_identity(rhs_entities);

    let mut added = Vec::new();
    let mut deleted = Vec::new();
    let mut modified = Vec::new();

    let identities = lhs_by_identity
        .keys()
        .chain(rhs_by_identity.keys())
        .cloned()
        .collect::<BTreeSet<_>>();

    for identity in identities {
        let mut lhs_group = lhs_by_identity.remove(&identity).unwrap_or_default();
        let mut rhs_group = rhs_by_identity.remove(&identity).unwrap_or_default();

        while !lhs_group.is_empty() && !rhs_group.is_empty() {
            if let Some((lhs_index, rhs_index)) = find_matching_pair(&lhs_group, &rhs_group) {
                lhs_group.remove(lhs_index);
                rhs_group.remove(rhs_index);
            } else {
                modified.push(ModifiedEntity {
                    lhs: lhs_group.remove(0),
                    rhs: rhs_group.remove(0),
                });
            }
        }

        deleted.extend(lhs_group);
        added.extend(rhs_group);
    }

    added.sort();
    deleted.sort();
    modified.sort_by(|lhs, rhs| lhs.lhs.name.cmp(&rhs.lhs.name));

    DiffResult {
        added,
        deleted,
        modified,
    }
}

pub fn render_diff_raw(diff: &DiffResult) -> Vec<String> {
    let mut lines = Vec::new();

    for entity in &diff.deleted {
        lines.push(format!(
            "- {}",
            crate::entity_collector::render_entity(entity)
        ));
    }
    for entity in &diff.added {
        lines.push(format!(
            "+ {}",
            crate::entity_collector::render_entity(entity)
        ));
    }
    for change in &diff.modified {
        lines.push(format!("~ {}", change.lhs.name));
        lines.push(format!(
            "  lhs: {}",
            crate::entity_collector::render_entity(&change.lhs)
        ));
        lines.push(format!(
            "  rhs: {}",
            crate::entity_collector::render_entity(&change.rhs)
        ));
    }

    lines
}

pub fn snapshot_label(spec: &SnapshotSpec) -> String {
    match spec {
        SnapshotSpec::Directory { root } => root.display().to_string(),
        SnapshotSpec::File { path, .. } => path.display().to_string(),
        SnapshotSpec::GitRevision { repo_root, rev } => format!("{}@{rev}", repo_root.display()),
    }
}

fn open_source_repo(spec: &SnapshotSpec) -> Result<Box<dyn SourceRepo>> {
    match spec {
        SnapshotSpec::Directory { root } => Ok(Box::new(FsSourceRepo::new(root.clone()))),
        SnapshotSpec::File { path, display_base } => Ok(Box::new(SingleFileSourceRepo::new(
            path.clone(),
            display_base.clone(),
        )?)),
        SnapshotSpec::GitRevision { repo_root, rev } => Ok(Box::new(GitTreeSourceRepo::open(
            repo_root.clone(),
            rev.clone(),
        )?)),
    }
}

fn discover_snapshot_targets(
    spec: &SnapshotSpec,
    repo: &dyn SourceRepo,
) -> Result<Vec<TargetRoot>> {
    match spec {
        SnapshotSpec::File { path, .. } => Ok(vec![single_file_target(path)?]),
        SnapshotSpec::Directory { .. } | SnapshotSpec::GitRevision { .. } => discover_targets(repo),
    }
}

fn single_file_target(path: &Path) -> Result<TargetRoot> {
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .context("file snapshot has no parent directory")?;
    let snapshot_path = path
        .strip_prefix(parent)
        .expect("file should be relative to its parent directory")
        .to_path_buf();
    Ok(TargetRoot {
        crate_name: "file".to_owned(),
        root_file: snapshot_path,
    })
}

fn path_starts_with(path: &Path, base: &Path) -> bool {
    path.strip_prefix(base).is_ok()
}

fn filtered_entities<'a>(snapshot: &'a Snapshot, path_filters: &[PathBuf]) -> Vec<&'a Entity> {
    if path_filters.is_empty() {
        return snapshot.entities.iter().collect();
    }

    snapshot
        .entities
        .iter()
        .filter(|entity| {
            path_filters
                .iter()
                .any(|filter| entity.location.snapshot_path.starts_with(filter))
        })
        .collect()
}

fn group_by_identity(entities: Vec<&Entity>) -> BTreeMap<EntityIdentity, Vec<Entity>> {
    let mut groups = BTreeMap::new();
    for entity in entities {
        groups
            .entry(entity_identity(entity))
            .or_insert_with(Vec::new)
            .push(entity.clone());
    }
    groups
}

fn find_matching_pair(lhs: &[Entity], rhs: &[Entity]) -> Option<(usize, usize)> {
    for (lhs_index, lhs_entity) in lhs.iter().enumerate() {
        for (rhs_index, rhs_entity) in rhs.iter().enumerate() {
            if entity_content_eq(lhs_entity, rhs_entity) {
                return Some((lhs_index, rhs_index));
            }
        }
    }
    None
}

fn repo_workdir(repo: &gix::Repository) -> Result<PathBuf> {
    repo.workdir()
        .map(Path::to_path_buf)
        .context("git repository has no working directory")
}

#[derive(Debug, Clone, Eq, PartialEq, Ord, PartialOrd)]
struct EntityIdentity {
    name: String,
    kind: EntityKind,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq, Ord, PartialOrd)]
enum EntityKind {
    Module,
    Function,
    Struct,
    Enum,
    Union,
    Trait,
    TypeAlias,
    Impl,
}

fn entity_identity(entity: &Entity) -> EntityIdentity {
    EntityIdentity {
        name: entity.name.clone(),
        kind: entity_kind(&entity.detail),
    }
}

fn entity_kind(detail: &EntityDetail) -> EntityKind {
    match detail {
        EntityDetail::Module { .. } => EntityKind::Module,
        EntityDetail::Function { .. } => EntityKind::Function,
        EntityDetail::Struct { .. } => EntityKind::Struct,
        EntityDetail::Enum { .. } => EntityKind::Enum,
        EntityDetail::Union { .. } => EntityKind::Union,
        EntityDetail::Trait { .. } => EntityKind::Trait,
        EntityDetail::TypeAlias { .. } => EntityKind::TypeAlias,
        EntityDetail::Impl { .. } => EntityKind::Impl,
    }
}

fn entity_content_eq(lhs: &Entity, rhs: &Entity) -> bool {
    entity_identity(lhs) == entity_identity(rhs)
        && lhs.detail == rhs.detail
        && lhs.source_text == rhs.source_text
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::entity_collector::SourceLocation;

    #[test]
    fn ignores_location_only_changes_when_matching_entities() {
        let lhs = Snapshot {
            entities: vec![sample_entity(
                "crate::thing",
                SourceLocation {
                    file_path: PathBuf::from("/tmp/lhs.rs"),
                    snapshot_path: PathBuf::from("src/lib.rs"),
                    start_line: 1,
                    start_col: 1,
                    end_line: 3,
                    end_col: 2,
                },
            )],
        };
        let rhs = Snapshot {
            entities: vec![sample_entity(
                "crate::thing",
                SourceLocation {
                    file_path: PathBuf::from("/tmp/rhs.rs"),
                    snapshot_path: PathBuf::from("src/lib.rs"),
                    start_line: 20,
                    start_col: 4,
                    end_line: 22,
                    end_col: 5,
                },
            )],
        };

        let diff = diff_snapshots(&lhs, &rhs, &[]);

        assert!(diff.added.is_empty());
        assert!(diff.deleted.is_empty());
        assert!(diff.modified.is_empty());
    }

    #[test]
    fn same_name_different_kind_does_not_match() {
        let lhs = Snapshot {
            entities: vec![sample_entity(
                "crate::thing",
                SourceLocation {
                    file_path: PathBuf::from("/tmp/lhs.rs"),
                    snapshot_path: PathBuf::from("src/lib.rs"),
                    start_line: 1,
                    start_col: 1,
                    end_line: 3,
                    end_col: 2,
                },
            )],
        };
        let rhs = Snapshot {
            entities: vec![Entity {
                name: "crate::thing".to_owned(),
                location: SourceLocation {
                    file_path: PathBuf::from("/tmp/rhs.rs"),
                    snapshot_path: PathBuf::from("src/lib.rs"),
                    start_line: 1,
                    start_col: 1,
                    end_line: 1,
                    end_col: 10,
                },
                source_text: "struct thing;".to_owned(),
                detail: EntityDetail::Struct { fields: Vec::new() },
            }],
        };

        let diff = diff_snapshots(&lhs, &rhs, &[]);

        assert_eq!(diff.deleted.len(), 1);
        assert_eq!(diff.added.len(), 1);
        assert!(diff.modified.is_empty());
    }

    fn sample_entity(name: &str, location: SourceLocation) -> Entity {
        Entity {
            name: name.to_owned(),
            location,
            source_text: "fn thing() {}".to_owned(),
            detail: EntityDetail::Function {
                signature: "()".to_owned(),
            },
        }
    }
}
