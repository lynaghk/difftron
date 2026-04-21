use std::{
    collections::{BTreeMap, BTreeSet},
    path::{Path, PathBuf},
};

use anyhow::{Context, Result, bail};
use tracing::{info, info_span};

use crate::{
    entity_collector::{Entity, collect_entities},
    project_discovery::discover_targets,
    source_repo::{FsSourceRepo, GitTreeSourceRepo, SourceRepo},
};

#[derive(Debug, Clone)]
pub enum SnapshotSpec {
    Directory { root: PathBuf },
    GitRevision { repo_root: PathBuf, rev: String },
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
    let resolved = if candidate.is_absolute() {
        candidate
    } else {
        cwd.join(candidate)
    };

    if resolved.exists() {
        if resolved.is_file() {
            bail!("{arg} is a file; expected a directory");
        }
        if resolved.is_dir() {
            return Ok(SnapshotSpec::Directory {
                root: resolved
                    .canonicalize()
                    .with_context(|| format!("failed to resolve {}", resolved.display()))?,
            });
        }
    }

    let repo = gix::discover(cwd).with_context(|| {
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
    let targets = discover_targets(source.as_ref())?;
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

    let mut lhs_by_name = group_by_name(lhs_entities);
    let mut rhs_by_name = group_by_name(rhs_entities);

    let mut added = Vec::new();
    let mut deleted = Vec::new();
    let mut modified = Vec::new();

    let names = lhs_by_name
        .keys()
        .chain(rhs_by_name.keys())
        .cloned()
        .collect::<BTreeSet<_>>();

    for name in names {
        let mut lhs_group = lhs_by_name.remove(&name).unwrap_or_default();
        let mut rhs_group = rhs_by_name.remove(&name).unwrap_or_default();

        while !lhs_group.is_empty() && !rhs_group.is_empty() {
            if let Some((lhs_index, rhs_index)) = find_exact_pair(&lhs_group, &rhs_group) {
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

pub fn render_diff(diff: &DiffResult) -> Vec<String> {
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
        SnapshotSpec::GitRevision { repo_root, rev } => format!("{}@{rev}", repo_root.display()),
    }
}

fn open_source_repo(spec: &SnapshotSpec) -> Result<Box<dyn SourceRepo>> {
    match spec {
        SnapshotSpec::Directory { root } => Ok(Box::new(FsSourceRepo::new(root.clone()))),
        SnapshotSpec::GitRevision { repo_root, rev } => Ok(Box::new(GitTreeSourceRepo::open(
            repo_root.clone(),
            rev.clone(),
        )?)),
    }
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
                .any(|filter| entity.location.relative_path.starts_with(filter))
        })
        .collect()
}

fn group_by_name(entities: Vec<&Entity>) -> BTreeMap<String, Vec<Entity>> {
    let mut groups = BTreeMap::new();
    for entity in entities {
        groups
            .entry(entity.name.clone())
            .or_insert_with(Vec::new)
            .push(entity.clone());
    }
    groups
}

fn find_exact_pair(lhs: &[Entity], rhs: &[Entity]) -> Option<(usize, usize)> {
    for (lhs_index, lhs_entity) in lhs.iter().enumerate() {
        for (rhs_index, rhs_entity) in rhs.iter().enumerate() {
            if lhs_entity == rhs_entity {
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
