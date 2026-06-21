use std::{
    collections::{BTreeMap, BTreeSet},
    ops::Range,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result};
use id_arena::Arena;
use minidiff::Language;
use tracing::{info, info_span};

use crate::{
    entity_collector::{
        Entity, EntityId, SourceLocation, collect_entities, entity_kind_name, render_entity,
    },
    project_discovery::SourceTarget,
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

#[derive(Debug)]
pub struct Snapshot {
    pub arena: Arena<Entity>,
    pub entities: Vec<EntityId>,
}

#[derive(Debug, Clone)]
pub struct DiffResult {
    pub added: Vec<Entity>,
    pub deleted: Vec<Entity>,
    pub moved: Vec<MovedEntity>,
    pub moved_modified: Vec<MovedModifiedEntity>,
    pub modified: Vec<ModifiedEntity>,
}

#[derive(Debug, Clone)]
pub struct MovedEntity {
    pub lhs: Entity,
    pub rhs: Entity,
}

#[derive(Debug, Clone)]
pub struct MovedModifiedEntity {
    pub lhs: Entity,
    pub rhs: Entity,
}

#[derive(Debug, Clone)]
pub struct ModifiedEntity {
    pub lhs: Entity,
    pub rhs: Entity,
}

#[derive(Debug, Clone)]
struct IndexedEntity {
    id: EntityId,
    entity: Entity,
}

#[derive(Debug, Clone)]
struct IndexedModifiedEntity {
    lhs_id: EntityId,
    lhs: Entity,
    rhs_id: EntityId,
    rhs: Entity,
}

#[derive(Debug, Clone)]
struct IndexedMovedEntity {
    lhs_id: EntityId,
    lhs: Entity,
    rhs_id: EntityId,
    rhs: Entity,
}

#[derive(Debug, Clone)]
struct IndexedMovedModifiedEntity {
    lhs_id: EntityId,
    lhs: Entity,
    rhs_id: EntityId,
    rhs: Entity,
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
    let collected = collect_entities(source.as_ref(), &targets)?;

    Ok(Snapshot {
        arena: collected.arena,
        entities: collected.entities,
    })
}

pub fn diff_snapshots(lhs: &Snapshot, rhs: &Snapshot, path_filters: &[PathBuf]) -> DiffResult {
    let _span = info_span!(
        "diff_snapshots",
        lhs_entities = lhs.entities.len(),
        rhs_entities = rhs.entities.len(),
        filter_count = path_filters.len()
    )
    .entered();

    let lhs_entities = indexed_entities(lhs);
    let rhs_entities = indexed_entities(rhs);

    let mut lhs_by_identity = group_by_identity(lhs_entities);
    let mut rhs_by_identity = group_by_identity(rhs_entities);

    let mut added = Vec::new();
    let mut deleted = Vec::new();
    let mut moved = Vec::new();
    let mut moved_modified = Vec::new();
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
                let lhs_entity = lhs_group.remove(lhs_index);
                let rhs_entity = rhs_group.remove(rhs_index);
                if entity_move_location_changed(&lhs_entity.entity, &rhs_entity.entity) {
                    moved.push(IndexedMovedEntity {
                        lhs_id: lhs_entity.id,
                        lhs: lhs_entity.entity,
                        rhs_id: rhs_entity.id,
                        rhs: rhs_entity.entity,
                    });
                }
            } else {
                let lhs_entity = lhs_group.remove(0);
                let rhs_entity = rhs_group.remove(0);
                modified.push(IndexedModifiedEntity {
                    lhs_id: lhs_entity.id,
                    lhs: lhs_entity.entity,
                    rhs_id: rhs_entity.id,
                    rhs: rhs_entity.entity,
                });
            }
        }

        deleted.extend(lhs_group);
        added.extend(rhs_group);
    }

    detect_unique_moves(&mut deleted, &mut added, &mut moved);
    detect_unique_moved_modified(&mut deleted, &mut added, &mut moved_modified);

    suppress_redundant_parents(
        lhs,
        rhs,
        &mut added,
        &mut deleted,
        &moved,
        &moved_modified,
        &mut modified,
    );

    filter_diff_by_paths(
        path_filters,
        &mut added,
        &mut deleted,
        &mut moved,
        &mut moved_modified,
        &mut modified,
    );

    added.sort_by(|lhs, rhs| lhs.entity.cmp(&rhs.entity));
    deleted.sort_by(|lhs, rhs| lhs.entity.cmp(&rhs.entity));
    moved.sort_by(|lhs, rhs| lhs.rhs.name.as_str().cmp(rhs.rhs.name.as_str()));
    moved_modified.sort_by(|lhs, rhs| lhs.rhs.name.as_str().cmp(rhs.rhs.name.as_str()));
    modified.sort_by(|lhs, rhs| lhs.lhs.name.cmp(&rhs.lhs.name));

    DiffResult {
        added: added.into_iter().map(|entity| entity.entity).collect(),
        deleted: deleted.into_iter().map(|entity| entity.entity).collect(),
        moved: moved
            .into_iter()
            .map(|change| MovedEntity {
                lhs: change.lhs,
                rhs: change.rhs,
            })
            .collect(),
        moved_modified: moved_modified
            .into_iter()
            .map(|change| MovedModifiedEntity {
                lhs: change.lhs,
                rhs: change.rhs,
            })
            .collect(),
        modified: modified
            .into_iter()
            .map(|change| ModifiedEntity {
                lhs: change.lhs,
                rhs: change.rhs,
            })
            .collect(),
    }
}

pub fn render_diff_raw(diff: &DiffResult) -> Vec<String> {
    let mut lines = Vec::new();

    for entity in &diff.deleted {
        lines.push(format!("- {}", render_entity(entity)));
    }
    for entity in &diff.added {
        lines.push(format!("+ {}", render_entity(entity)));
    }
    for change in &diff.moved {
        lines.push(format!("R {} -> {}", change.lhs.name, change.rhs.name));
        lines.push(format!("  lhs: {}", render_entity(&change.lhs)));
        lines.push(format!("  rhs: {}", render_entity(&change.rhs)));
    }
    for change in &diff.moved_modified {
        lines.push(format!("R~ {} -> {}", change.lhs.name, change.rhs.name));
        lines.push(format!("  lhs: {}", render_entity(&change.lhs)));
        lines.push(format!("  rhs: {}", render_entity(&change.rhs)));
    }
    for change in &diff.modified {
        lines.push(format!("~ {}", change.lhs.name));
        lines.push(format!("  lhs: {}", render_entity(&change.lhs)));
        lines.push(format!("  rhs: {}", render_entity(&change.rhs)));
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
) -> Result<Vec<SourceTarget>> {
    match spec {
        SnapshotSpec::File { path, .. } => Ok(vec![single_file_target(path)?]),
        SnapshotSpec::Directory { .. } | SnapshotSpec::GitRevision { .. } => discover_targets(repo),
    }
}

fn single_file_target(path: &Path) -> Result<SourceTarget> {
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .context("file snapshot has no parent directory")?;
    let snapshot_path = path
        .strip_prefix(parent)
        .expect("file should be relative to its parent directory")
        .to_path_buf();
    Ok(SourceTarget {
        root_name: "file".to_owned(),
        root_file: snapshot_path,
        language: language_for_path(path)
            .with_context(|| format!("unsupported source file extension: {}", path.display()))?,
    })
}

fn language_for_path(path: &Path) -> Option<Language> {
    match path.extension().and_then(|extension| extension.to_str()) {
        Some("rs") => Some(Language::Rust),
        Some("clj" | "cljs" | "cljc" | "edn") => Some(Language::Clojure),
        Some("ts") if !is_typescript_declaration_file(path) => Some(Language::TypeScript),
        Some(_) | None => None,
    }
}

fn is_typescript_declaration_file(path: &Path) -> bool {
    path.file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| name.ends_with(".d.ts"))
}

fn path_starts_with(path: &Path, base: &Path) -> bool {
    path.strip_prefix(base).is_ok()
}

fn indexed_entities(snapshot: &Snapshot) -> Vec<IndexedEntity> {
    snapshot
        .entities
        .iter()
        .map(|id| IndexedEntity {
            id: *id,
            entity: snapshot.arena[*id].clone(),
        })
        .collect()
}

fn group_by_identity(entities: Vec<IndexedEntity>) -> BTreeMap<EntityIdentity, Vec<IndexedEntity>> {
    let mut groups: BTreeMap<EntityIdentity, Vec<IndexedEntity>> = BTreeMap::new();
    for entity in entities {
        groups
            .entry(entity_identity(&entity.entity))
            .or_default()
            .push(entity);
    }
    groups
}

fn find_matching_pair(lhs: &[IndexedEntity], rhs: &[IndexedEntity]) -> Option<(usize, usize)> {
    for (lhs_index, lhs_entity) in lhs.iter().enumerate() {
        for (rhs_index, rhs_entity) in rhs.iter().enumerate() {
            if entity_content_eq(&lhs_entity.entity, &rhs_entity.entity) {
                return Some((lhs_index, rhs_index));
            }
        }
    }
    None
}

fn detect_unique_moves(
    deleted: &mut Vec<IndexedEntity>,
    added: &mut Vec<IndexedEntity>,
    moved: &mut Vec<IndexedMovedEntity>,
) {
    let mut lhs_by_signature: BTreeMap<MoveSignature, Vec<usize>> = BTreeMap::new();
    let mut rhs_by_signature: BTreeMap<MoveSignature, Vec<usize>> = BTreeMap::new();

    for (index, entity) in deleted.iter().enumerate() {
        lhs_by_signature
            .entry(move_signature(&entity.entity))
            .or_default()
            .push(index);
    }
    for (index, entity) in added.iter().enumerate() {
        rhs_by_signature
            .entry(move_signature(&entity.entity))
            .or_default()
            .push(index);
    }

    let signatures = lhs_by_signature
        .keys()
        .chain(rhs_by_signature.keys())
        .cloned()
        .collect::<BTreeSet<_>>();
    let mut deleted_to_move = BTreeSet::new();
    let mut added_to_move = BTreeSet::new();
    let mut discovered = Vec::new();

    for signature in signatures {
        let lhs_indices = lhs_by_signature
            .get(&signature)
            .cloned()
            .unwrap_or_default();
        let rhs_indices = rhs_by_signature
            .get(&signature)
            .cloned()
            .unwrap_or_default();
        if lhs_indices.len() == 1 && rhs_indices.len() == 1 {
            let lhs_index = lhs_indices[0];
            let rhs_index = rhs_indices[0];
            let lhs_entity = deleted[lhs_index].clone();
            let rhs_entity = added[rhs_index].clone();
            discovered.push(IndexedMovedEntity {
                lhs_id: lhs_entity.id,
                lhs: lhs_entity.entity,
                rhs_id: rhs_entity.id,
                rhs: rhs_entity.entity,
            });
            deleted_to_move.insert(lhs_index);
            added_to_move.insert(rhs_index);
        }
    }

    moved.extend(discovered);
    remove_indices(deleted, &deleted_to_move);
    remove_indices(added, &added_to_move);
}

fn detect_unique_moved_modified(
    deleted: &mut Vec<IndexedEntity>,
    added: &mut Vec<IndexedEntity>,
    moved_modified: &mut Vec<IndexedMovedModifiedEntity>,
) {
    let mut candidates = Vec::new();

    for (lhs_index, lhs_entity) in deleted.iter().enumerate() {
        for (rhs_index, rhs_entity) in added.iter().enumerate() {
            if let Some(score) = moved_modified_similarity(&lhs_entity.entity, &rhs_entity.entity) {
                candidates.push((score, lhs_index, rhs_index));
            }
        }
    }

    let mut lhs_matches: BTreeMap<usize, Vec<(usize, usize)>> = BTreeMap::new();
    let mut rhs_matches: BTreeMap<usize, Vec<(usize, usize)>> = BTreeMap::new();
    for &(score, lhs_index, rhs_index) in &candidates {
        lhs_matches
            .entry(lhs_index)
            .or_default()
            .push((score, rhs_index));
        rhs_matches
            .entry(rhs_index)
            .or_default()
            .push((score, lhs_index));
    }

    let mut deleted_to_move = BTreeSet::new();
    let mut added_to_move = BTreeSet::new();
    let mut discovered = Vec::new();

    for (score, lhs_index, rhs_index) in candidates {
        if deleted_to_move.contains(&lhs_index) || added_to_move.contains(&rhs_index) {
            continue;
        }
        if !is_unique_best_match(&lhs_matches[&lhs_index], score, rhs_index)
            || !is_unique_best_match(&rhs_matches[&rhs_index], score, lhs_index)
        {
            continue;
        }

        let lhs_entity = deleted[lhs_index].clone();
        let rhs_entity = added[rhs_index].clone();
        discovered.push(IndexedMovedModifiedEntity {
            lhs_id: lhs_entity.id,
            lhs: lhs_entity.entity,
            rhs_id: rhs_entity.id,
            rhs: rhs_entity.entity,
        });
        deleted_to_move.insert(lhs_index);
        added_to_move.insert(rhs_index);
    }

    moved_modified.extend(discovered);
    remove_indices(deleted, &deleted_to_move);
    remove_indices(added, &added_to_move);
}

fn is_unique_best_match(matches: &[(usize, usize)], score: usize, index: usize) -> bool {
    let Some(best_score) = matches
        .iter()
        .map(|(candidate_score, _)| *candidate_score)
        .max()
    else {
        return false;
    };

    score == best_score
        && matches
            .iter()
            .filter(|(candidate_score, _)| *candidate_score == best_score)
            .all(|(_, candidate_index)| *candidate_index == index)
}

fn moved_modified_similarity(lhs: &Entity, rhs: &Entity) -> Option<usize> {
    if lhs.language != rhs.language
        || entity_kind_name(&lhs.detail) != entity_kind_name(&rhs.detail)
        || local_entity_name(&lhs.name) != local_entity_name(&rhs.name)
        || lhs.source_text == rhs.source_text
    {
        return None;
    }

    let lhs_source = normalized_similarity_source(&lhs.source_text);
    let rhs_source = normalized_similarity_source(&rhs.source_text);
    if lhs_source.is_empty() || rhs_source.is_empty() {
        return None;
    }

    let score = lcs_len(lhs_source.as_bytes(), rhs_source.as_bytes());
    let longer = lhs_source.len().max(rhs_source.len());
    (score * 100 >= longer * 75).then_some(score)
}

fn normalized_similarity_source(source: &str) -> String {
    source
        .chars()
        .filter(|ch| ch.is_alphanumeric() || *ch == '_')
        .collect()
}

fn local_entity_name(name: &str) -> &str {
    name.rsplit("::").next().unwrap_or(name)
}

fn lcs_len(lhs: &[u8], rhs: &[u8]) -> usize {
    let mut previous = vec![0; rhs.len() + 1];
    let mut current = vec![0; rhs.len() + 1];

    for lhs_byte in lhs {
        for (rhs_index, rhs_byte) in rhs.iter().enumerate() {
            current[rhs_index + 1] = if lhs_byte == rhs_byte {
                previous[rhs_index] + 1
            } else {
                current[rhs_index].max(previous[rhs_index + 1])
            };
        }
        std::mem::swap(&mut previous, &mut current);
        current.fill(0);
    }

    previous[rhs.len()]
}

fn remove_indices<T>(values: &mut Vec<T>, indices: &BTreeSet<usize>) {
    let mut next_index = 0;
    values.retain(|_| {
        let keep = !indices.contains(&next_index);
        next_index += 1;
        keep
    });
}

fn suppress_redundant_parents(
    lhs: &Snapshot,
    rhs: &Snapshot,
    added: &mut Vec<IndexedEntity>,
    deleted: &mut Vec<IndexedEntity>,
    moved: &[IndexedMovedEntity],
    moved_modified: &[IndexedMovedModifiedEntity],
    modified: &mut Vec<IndexedModifiedEntity>,
) {
    let rhs_changed = added
        .iter()
        .cloned()
        .chain(moved.iter().map(|change| IndexedEntity {
            id: change.rhs_id,
            entity: change.rhs.clone(),
        }))
        .chain(moved_modified.iter().map(|change| IndexedEntity {
            id: change.rhs_id,
            entity: change.rhs.clone(),
        }))
        .chain(modified.iter().map(|change| IndexedEntity {
            id: change.rhs_id,
            entity: change.rhs.clone(),
        }))
        .collect::<Vec<_>>();
    let lhs_changed = deleted
        .iter()
        .cloned()
        .chain(moved.iter().map(|change| IndexedEntity {
            id: change.lhs_id,
            entity: change.lhs.clone(),
        }))
        .chain(moved_modified.iter().map(|change| IndexedEntity {
            id: change.lhs_id,
            entity: change.lhs.clone(),
        }))
        .chain(modified.iter().map(|change| IndexedEntity {
            id: change.lhs_id,
            entity: change.lhs.clone(),
        }))
        .collect::<Vec<_>>();

    added.retain(|candidate| {
        let descendants = descendant_ranges(rhs, candidate.id, &candidate.entity, &rhs_changed);
        !is_redundant_add_or_delete(&candidate.entity, &descendants)
    });
    deleted.retain(|candidate| {
        let descendants = descendant_ranges(lhs, candidate.id, &candidate.entity, &lhs_changed);
        !is_redundant_add_or_delete(&candidate.entity, &descendants)
    });
    modified.retain(|candidate| {
        let lhs_descendants =
            descendant_ranges(lhs, candidate.lhs_id, &candidate.lhs, &lhs_changed);
        let rhs_descendants =
            descendant_ranges(rhs, candidate.rhs_id, &candidate.rhs, &rhs_changed);
        !is_redundant_modified(
            &candidate.lhs,
            &lhs_descendants,
            &candidate.rhs,
            &rhs_descendants,
        )
    });
}

fn descendant_ranges(
    snapshot: &Snapshot,
    candidate_id: EntityId,
    candidate: &Entity,
    changed_entities: &[IndexedEntity],
) -> Vec<Range<usize>> {
    let mut ranges = changed_entities
        .iter()
        .filter_map(|entity| {
            if entity.id == candidate_id || !is_descendant(snapshot, entity.id, candidate_id) {
                return None;
            }
            relative_range(candidate, &entity.entity)
        })
        .collect::<Vec<_>>();
    ranges.sort_by_key(|range| (range.start, range.end));
    merge_ranges(ranges)
}

fn is_descendant(snapshot: &Snapshot, mut entity_id: EntityId, ancestor_id: EntityId) -> bool {
    while let Some(parent_id) = snapshot.arena[entity_id].parent {
        if parent_id == ancestor_id {
            return true;
        }
        entity_id = parent_id;
    }
    false
}

fn is_redundant_add_or_delete(entity: &Entity, descendant_ranges: &[Range<usize>]) -> bool {
    if descendant_ranges.is_empty() {
        return false;
    }
    normalized_residual(entity, descendant_ranges).is_empty()
}

fn is_redundant_modified(
    lhs: &Entity,
    lhs_descendants: &[Range<usize>],
    rhs: &Entity,
    rhs_descendants: &[Range<usize>],
) -> bool {
    if lhs_descendants.is_empty() && rhs_descendants.is_empty() {
        return false;
    }

    normalized_residual(lhs, lhs_descendants) == normalized_residual(rhs, rhs_descendants)
}

fn normalized_residual(entity: &Entity, descendant_ranges: &[Range<usize>]) -> String {
    let mut residual = String::new();
    let mut cursor = 0;
    for range in descendant_ranges {
        if cursor < range.start {
            residual.push_str(&entity.source_text[cursor..range.start]);
        }
        cursor = cursor.max(range.end);
    }
    if cursor < entity.source_text.len() {
        residual.push_str(&entity.source_text[cursor..]);
    }
    residual
        .chars()
        .filter(|ch| ch.is_alphanumeric() || *ch == '_')
        .collect()
}

fn relative_range(parent: &Entity, child: &Entity) -> Option<Range<usize>> {
    if parent.location.file_path != child.location.file_path {
        return None;
    }

    let line_starts = compute_line_starts(&parent.source_text);
    let start = offset_in_parent(
        &line_starts,
        &parent.location,
        child.location.start_line,
        child.location.start_col,
    )?;
    let end = offset_in_parent(
        &line_starts,
        &parent.location,
        child.location.end_line,
        child.location.end_col,
    )?;
    Some(start..end)
}

fn offset_in_parent(
    line_starts: &[usize],
    parent: &SourceLocation,
    line: u32,
    col: u32,
) -> Option<usize> {
    if line < parent.start_line {
        return None;
    }
    let line_index = (line - parent.start_line) as usize;
    let line_start = *line_starts.get(line_index)?;
    let base_col = if line_index == 0 { parent.start_col } else { 1 };
    if col < base_col {
        return None;
    }
    Some(line_start + (col - base_col) as usize)
}

fn compute_line_starts(text: &str) -> Vec<usize> {
    let mut starts = vec![0];
    for (idx, byte) in text.bytes().enumerate() {
        if byte == b'\n' {
            starts.push(idx + 1);
        }
    }
    starts
}

fn merge_ranges(ranges: Vec<Range<usize>>) -> Vec<Range<usize>> {
    let mut merged: Vec<Range<usize>> = Vec::new();
    for range in ranges {
        if let Some(last) = merged.last_mut()
            && range.start <= last.end
        {
            last.end = last.end.max(range.end);
            continue;
        }
        merged.push(range);
    }
    merged
}

fn filter_diff_by_paths(
    path_filters: &[PathBuf],
    added: &mut Vec<IndexedEntity>,
    deleted: &mut Vec<IndexedEntity>,
    moved: &mut Vec<IndexedMovedEntity>,
    moved_modified: &mut Vec<IndexedMovedModifiedEntity>,
    modified: &mut Vec<IndexedModifiedEntity>,
) {
    if path_filters.is_empty() {
        return;
    }

    added.retain(|entity| entity_matches_filters(&entity.entity, path_filters));
    deleted.retain(|entity| entity_matches_filters(&entity.entity, path_filters));
    moved.retain(|change| {
        entity_matches_filters(&change.lhs, path_filters)
            || entity_matches_filters(&change.rhs, path_filters)
    });
    moved_modified.retain(|change| {
        entity_matches_filters(&change.lhs, path_filters)
            || entity_matches_filters(&change.rhs, path_filters)
    });
    modified.retain(|change| {
        entity_matches_filters(&change.lhs, path_filters)
            || entity_matches_filters(&change.rhs, path_filters)
    });
}

fn entity_matches_filters(entity: &Entity, path_filters: &[PathBuf]) -> bool {
    path_filters
        .iter()
        .any(|filter| entity.location.snapshot_path.starts_with(filter))
}

fn repo_workdir(repo: &gix::Repository) -> Result<PathBuf> {
    repo.workdir()
        .map(Path::to_path_buf)
        .context("git repository has no working directory")
}

#[derive(Debug, Clone, Eq, PartialEq, Ord, PartialOrd)]
struct EntityIdentity {
    name: String,
    language: Language,
    kind: &'static str,
}

#[derive(Debug, Clone, Eq, PartialEq, Ord, PartialOrd)]
struct MoveSignature {
    language: Language,
    kind: &'static str,
    detail: crate::entity_collector::EntityDetail,
    source_text: String,
}

fn entity_identity(entity: &Entity) -> EntityIdentity {
    EntityIdentity {
        name: entity.name.clone(),
        language: entity.language,
        kind: entity_kind_name(&entity.detail),
    }
}

fn move_signature(entity: &Entity) -> MoveSignature {
    MoveSignature {
        language: entity.language,
        kind: entity_kind_name(&entity.detail),
        detail: entity.detail.clone(),
        source_text: entity.source_text.clone(),
    }
}

fn entity_content_eq(lhs: &Entity, rhs: &Entity) -> bool {
    entity_identity(lhs) == entity_identity(rhs)
        && lhs.detail == rhs.detail
        && lhs.source_text == rhs.source_text
}

fn entity_move_location_changed(lhs: &Entity, rhs: &Entity) -> bool {
    lhs.name != rhs.name || lhs.location.snapshot_path != rhs.location.snapshot_path
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        entity_collector::{EntityDetail, SourceLocation},
        languages::{clojure::ClojureEntityDetail, rust::RustEntityDetail},
    };

    #[test]
    fn ignores_location_only_changes_when_matching_entities() {
        let lhs = snapshot_from_entities(vec![sample_entity(
            "crate::thing",
            SourceLocation {
                file_path: PathBuf::from("/tmp/lhs.rs"),
                snapshot_path: PathBuf::from("src/lib.rs"),
                start_line: 1,
                start_col: 1,
                end_line: 3,
                end_col: 2,
            },
        )]);
        let rhs = snapshot_from_entities(vec![sample_entity(
            "crate::thing",
            SourceLocation {
                file_path: PathBuf::from("/tmp/rhs.rs"),
                snapshot_path: PathBuf::from("src/lib.rs"),
                start_line: 20,
                start_col: 4,
                end_line: 22,
                end_col: 5,
            },
        )]);

        let diff = diff_snapshots(&lhs, &rhs, &[]);

        assert!(diff.added.is_empty());
        assert!(diff.deleted.is_empty());
        assert!(diff.moved.is_empty());
        assert!(diff.modified.is_empty());
    }

    #[test]
    fn reports_exact_content_rename_as_move() {
        let lhs = snapshot_from_entities(vec![sample_entity(
            "crate::old",
            SourceLocation {
                file_path: PathBuf::from("/tmp/project/src/lib.rs"),
                snapshot_path: PathBuf::from("src/lib.rs"),
                start_line: 1,
                start_col: 1,
                end_line: 1,
                end_col: 14,
            },
        )]);
        let rhs = snapshot_from_entities(vec![sample_entity(
            "crate::new",
            SourceLocation {
                file_path: PathBuf::from("/tmp/project/src/lib.rs"),
                snapshot_path: PathBuf::from("src/lib.rs"),
                start_line: 1,
                start_col: 1,
                end_line: 1,
                end_col: 14,
            },
        )]);

        let diff = diff_snapshots(&lhs, &rhs, &[]);

        assert!(diff.added.is_empty());
        assert!(diff.deleted.is_empty());
        assert!(diff.modified.is_empty());
        assert_eq!(diff.moved.len(), 1);
        assert_eq!(diff.moved[0].lhs.name, "crate::old");
        assert_eq!(diff.moved[0].rhs.name, "crate::new");
    }

    #[test]
    fn reports_exact_content_path_change_as_move() {
        let lhs = snapshot_from_entities(vec![sample_entity(
            "crate::thing",
            SourceLocation {
                file_path: PathBuf::from("/tmp/project/src/old.rs"),
                snapshot_path: PathBuf::from("src/old.rs"),
                start_line: 1,
                start_col: 1,
                end_line: 1,
                end_col: 14,
            },
        )]);
        let rhs = snapshot_from_entities(vec![sample_entity(
            "crate::thing",
            SourceLocation {
                file_path: PathBuf::from("/tmp/project/src/new.rs"),
                snapshot_path: PathBuf::from("src/new.rs"),
                start_line: 10,
                start_col: 1,
                end_line: 10,
                end_col: 14,
            },
        )]);

        let diff = diff_snapshots(&lhs, &rhs, &[]);

        assert!(diff.added.is_empty());
        assert!(diff.deleted.is_empty());
        assert!(diff.modified.is_empty());
        assert_eq!(diff.moved.len(), 1);
        assert_eq!(
            diff.moved[0].lhs.location.snapshot_path,
            PathBuf::from("src/old.rs")
        );
        assert_eq!(
            diff.moved[0].rhs.location.snapshot_path,
            PathBuf::from("src/new.rs")
        );
    }

    #[test]
    fn reports_similar_path_change_as_moved_modified() {
        let lhs = snapshot_from_entities(vec![Entity {
            source_text: "fn moved() -> u32 { 41 }".to_owned(),
            ..sample_entity(
                "crate::old::moved",
                SourceLocation {
                    file_path: PathBuf::from("/tmp/project/src/old.rs"),
                    snapshot_path: PathBuf::from("src/old.rs"),
                    start_line: 1,
                    start_col: 1,
                    end_line: 1,
                    end_col: 24,
                },
            )
        }]);
        let rhs = snapshot_from_entities(vec![Entity {
            source_text: "fn moved() -> u32 { 42 }".to_owned(),
            ..sample_entity(
                "crate::new::moved",
                SourceLocation {
                    file_path: PathBuf::from("/tmp/project/src/new.rs"),
                    snapshot_path: PathBuf::from("src/new.rs"),
                    start_line: 1,
                    start_col: 1,
                    end_line: 1,
                    end_col: 24,
                },
            )
        }]);

        let diff = diff_snapshots(&lhs, &rhs, &[]);

        assert!(diff.added.is_empty());
        assert!(diff.deleted.is_empty());
        assert!(diff.moved.is_empty());
        assert!(diff.modified.is_empty());
        assert_eq!(diff.moved_modified.len(), 1);
        assert_eq!(diff.moved_modified[0].lhs.name, "crate::old::moved");
        assert_eq!(diff.moved_modified[0].rhs.name, "crate::new::moved");
    }

    #[test]
    fn path_filters_keep_moves_when_either_endpoint_matches() {
        let lhs = snapshot_from_entities(vec![sample_entity(
            "crate::thing",
            SourceLocation {
                file_path: PathBuf::from("/tmp/project/src/old.rs"),
                snapshot_path: PathBuf::from("src/old.rs"),
                start_line: 1,
                start_col: 1,
                end_line: 1,
                end_col: 14,
            },
        )]);
        let rhs = snapshot_from_entities(vec![sample_entity(
            "crate::thing",
            SourceLocation {
                file_path: PathBuf::from("/tmp/project/src/new.rs"),
                snapshot_path: PathBuf::from("src/new.rs"),
                start_line: 10,
                start_col: 1,
                end_line: 10,
                end_col: 14,
            },
        )]);

        let diff = diff_snapshots(&lhs, &rhs, &[PathBuf::from("src/old.rs")]);

        assert!(diff.added.is_empty());
        assert!(diff.deleted.is_empty());
        assert_eq!(diff.moved.len(), 1);
        assert!(diff.modified.is_empty());
    }

    #[test]
    fn leaves_duplicate_exact_content_candidates_as_add_delete() {
        let location = SourceLocation {
            file_path: PathBuf::from("/tmp/project/src/lib.rs"),
            snapshot_path: PathBuf::from("src/lib.rs"),
            start_line: 1,
            start_col: 1,
            end_line: 1,
            end_col: 14,
        };
        let lhs = snapshot_from_entities(vec![
            sample_entity("crate::old_a", location.clone()),
            sample_entity("crate::old_b", location.clone()),
        ]);
        let rhs = snapshot_from_entities(vec![sample_entity("crate::new", location)]);

        let diff = diff_snapshots(&lhs, &rhs, &[]);

        assert_eq!(diff.deleted.len(), 2);
        assert_eq!(diff.added.len(), 1);
        assert!(diff.moved.is_empty());
        assert!(diff.modified.is_empty());
    }

    #[test]
    fn does_not_move_when_exact_content_detail_differs() {
        let location = SourceLocation {
            file_path: PathBuf::from("/tmp/project/src/lib.rs"),
            snapshot_path: PathBuf::from("src/lib.rs"),
            start_line: 1,
            start_col: 1,
            end_line: 1,
            end_col: 14,
        };
        let lhs = snapshot_from_entities(vec![sample_entity("crate::old", location.clone())]);
        let rhs = snapshot_from_entities(vec![Entity {
            name: "crate::new".to_owned(),
            parent: None,
            language: Language::Rust,
            location,
            source_text: "fn thing() {}".to_owned(),
            detail: EntityDetail::Rust(RustEntityDetail::Function {
                signature: "(arg: u32)".to_owned(),
            }),
        }]);

        let diff = diff_snapshots(&lhs, &rhs, &[]);

        assert_eq!(diff.deleted.len(), 1);
        assert_eq!(diff.added.len(), 1);
        assert!(diff.moved.is_empty());
        assert!(diff.modified.is_empty());
    }

    #[test]
    fn same_name_different_kind_does_not_match() {
        let lhs = snapshot_from_entities(vec![sample_entity(
            "crate::thing",
            SourceLocation {
                file_path: PathBuf::from("/tmp/lhs.rs"),
                snapshot_path: PathBuf::from("src/lib.rs"),
                start_line: 1,
                start_col: 1,
                end_line: 3,
                end_col: 2,
            },
        )]);
        let rhs = snapshot_from_entities(vec![Entity {
            name: "crate::thing".to_owned(),
            parent: None,
            language: Language::Rust,
            location: SourceLocation {
                file_path: PathBuf::from("/tmp/rhs.rs"),
                snapshot_path: PathBuf::from("src/lib.rs"),
                start_line: 1,
                start_col: 1,
                end_line: 1,
                end_col: 10,
            },
            source_text: "struct thing;".to_owned(),
            detail: EntityDetail::Rust(RustEntityDetail::Struct { fields: Vec::new() }),
        }]);

        let diff = diff_snapshots(&lhs, &rhs, &[]);

        assert_eq!(diff.deleted.len(), 1);
        assert_eq!(diff.added.len(), 1);
        assert!(diff.modified.is_empty());
    }

    #[test]
    fn same_name_same_external_kind_different_language_does_not_match() {
        let location = SourceLocation {
            file_path: PathBuf::from("/tmp/project/src/core"),
            snapshot_path: PathBuf::from("src/core"),
            start_line: 1,
            start_col: 1,
            end_line: 1,
            end_col: 10,
        };
        let lhs = snapshot_from_entities(vec![Entity {
            name: "demo::meaning".to_owned(),
            parent: None,
            language: Language::Rust,
            location: location.clone(),
            source_text: "fn meaning() {}".to_owned(),
            detail: EntityDetail::Rust(RustEntityDetail::Function {
                signature: "()".to_owned(),
            }),
        }]);
        let rhs = snapshot_from_entities(vec![Entity {
            name: "demo::meaning".to_owned(),
            parent: None,
            language: Language::Clojure,
            location,
            source_text: "(defn meaning [] nil)".to_owned(),
            detail: EntityDetail::Clojure(ClojureEntityDetail::Function {
                signature: "[]".to_owned(),
            }),
        }]);

        let diff = diff_snapshots(&lhs, &rhs, &[]);

        assert_eq!(diff.deleted.len(), 1);
        assert_eq!(diff.added.len(), 1);
        assert!(diff.modified.is_empty());
    }

    #[test]
    fn single_file_target_rejects_unknown_extensions() {
        let err = single_file_target(Path::new("/tmp/example.txt")).unwrap_err();

        assert!(
            err.to_string()
                .contains("unsupported source file extension")
        );
    }

    #[test]
    fn suppresses_redundant_root_change_but_keeps_module_change_with_unique_text() {
        let file_path = PathBuf::from("/tmp/example.rs");
        let lhs = snapshot_from_specs(
            &file_path,
            vec![
                EntitySpec {
                    name: "file",
                    parent: None,
                    start_line: 1,
                    start_col: 1,
                    end_line: 5,
                    end_col: 2,
                    source_text: "mod demo {\n    fn compute() {\n        1\n    }\n}\n",
                    detail: EntityDetail::Rust(RustEntityDetail::Module { is_inline: false }),
                },
                EntitySpec {
                    name: "file::demo",
                    parent: Some(0),
                    start_line: 1,
                    start_col: 1,
                    end_line: 5,
                    end_col: 2,
                    source_text: "mod demo {\n    fn compute() {\n        1\n    }\n}\n",
                    detail: EntityDetail::Rust(RustEntityDetail::Module { is_inline: true }),
                },
                EntitySpec {
                    name: "file::demo::compute",
                    parent: Some(1),
                    start_line: 2,
                    start_col: 5,
                    end_line: 4,
                    end_col: 6,
                    source_text: "fn compute() {\n        1\n    }\n",
                    detail: EntityDetail::Rust(RustEntityDetail::Function {
                        signature: "()".to_owned(),
                    }),
                },
            ],
        );
        let rhs = snapshot_from_specs(
            &file_path,
            vec![
                EntitySpec {
                    name: "file",
                    parent: None,
                    start_line: 1,
                    start_col: 1,
                    end_line: 9,
                    end_col: 2,
                    source_text: "mod demo {\n    use std::fmt::Debug;\n\n    fn compute() {\n        2\n    }\n\n    fn render<T: Debug>(value: T) {}\n}\n",
                    detail: EntityDetail::Rust(RustEntityDetail::Module { is_inline: false }),
                },
                EntitySpec {
                    name: "file::demo",
                    parent: Some(0),
                    start_line: 1,
                    start_col: 1,
                    end_line: 9,
                    end_col: 2,
                    source_text: "mod demo {\n    use std::fmt::Debug;\n\n    fn compute() {\n        2\n    }\n\n    fn render<T: Debug>(value: T) {}\n}\n",
                    detail: EntityDetail::Rust(RustEntityDetail::Module { is_inline: true }),
                },
                EntitySpec {
                    name: "file::demo::compute",
                    parent: Some(1),
                    start_line: 4,
                    start_col: 5,
                    end_line: 6,
                    end_col: 6,
                    source_text: "fn compute() {\n        2\n    }\n",
                    detail: EntityDetail::Rust(RustEntityDetail::Function {
                        signature: "()".to_owned(),
                    }),
                },
                EntitySpec {
                    name: "file::demo::render",
                    parent: Some(1),
                    start_line: 8,
                    start_col: 5,
                    end_line: 8,
                    end_col: 35,
                    source_text: "fn render<T: Debug>(value: T) {}\n",
                    detail: EntityDetail::Rust(RustEntityDetail::Function {
                        signature: "(value: T)".to_owned(),
                    }),
                },
            ],
        );

        let diff = diff_snapshots(&lhs, &rhs, &[]);

        assert_eq!(diff.added.len(), 1);
        assert_eq!(diff.added[0].name, "file::demo::render");
        assert_eq!(diff.modified.len(), 2);
        assert!(
            diff.modified
                .iter()
                .any(|change| change.lhs.name == "file::demo")
        );
        assert!(
            diff.modified
                .iter()
                .any(|change| change.lhs.name == "file::demo::compute")
        );
        assert!(!diff.modified.iter().any(|change| change.lhs.name == "file"));
    }

    fn sample_entity(name: &str, location: SourceLocation) -> Entity {
        Entity {
            name: name.to_owned(),
            parent: None,
            language: Language::Rust,
            location,
            source_text: "fn thing() {}".to_owned(),
            detail: EntityDetail::Rust(RustEntityDetail::Function {
                signature: "()".to_owned(),
            }),
        }
    }

    fn snapshot_from_entities(values: Vec<Entity>) -> Snapshot {
        let mut arena = Arena::new();
        let entities = values
            .into_iter()
            .map(|entity| arena.alloc(entity))
            .collect();
        Snapshot { arena, entities }
    }

    #[derive(Clone)]
    struct EntitySpec {
        name: &'static str,
        parent: Option<usize>,
        start_line: u32,
        start_col: u32,
        end_line: u32,
        end_col: u32,
        source_text: &'static str,
        detail: EntityDetail,
    }

    fn snapshot_from_specs(file_path: &Path, specs: Vec<EntitySpec>) -> Snapshot {
        let mut arena = Arena::new();
        let mut entities = Vec::new();

        for spec in specs {
            let parent = spec.parent.map(|index| entities[index]);
            entities.push(arena.alloc(Entity {
                name: spec.name.to_owned(),
                parent,
                language: Language::Rust,
                location: SourceLocation {
                    file_path: file_path.to_path_buf(),
                    snapshot_path: PathBuf::from("example.rs"),
                    start_line: spec.start_line,
                    start_col: spec.start_col,
                    end_line: spec.end_line,
                    end_col: spec.end_col,
                },
                source_text: spec.source_text.to_owned(),
                detail: spec.detail,
            }));
        }

        Snapshot { arena, entities }
    }
}
