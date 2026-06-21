use std::path::PathBuf;

use anyhow::Result;
use id_arena::{Arena, Id};
use minidiff::Language;
use tracing::{info, info_span};

use crate::{
    languages::{
        clojure::ClojureEntityDetail, rust::RustEntityDetail, typescript::TypeScriptEntityDetail,
    },
    project_discovery::SourceTarget,
    source_repo::SourceRepo,
};

pub type EntityId = Id<Entity>;

#[derive(Debug, Clone, Eq, PartialEq, Ord, PartialOrd)]
pub struct Entity {
    pub name: String,
    pub parent: Option<EntityId>,
    pub language: Language,
    pub location: SourceLocation,
    pub source_text: String,
    pub detail: EntityDetail,
}

#[derive(Debug, Clone, Eq, PartialEq, Ord, PartialOrd)]
pub struct SourceLocation {
    pub file_path: PathBuf,
    pub snapshot_path: PathBuf,
    pub start_line: u32,
    pub start_col: u32,
    pub end_line: u32,
    pub end_col: u32,
}

#[derive(Debug, Clone, Eq, PartialEq, Ord, PartialOrd)]
pub enum EntityDetail {
    Rust(RustEntityDetail),
    Clojure(ClojureEntityDetail),
    TypeScript(TypeScriptEntityDetail),
}

#[derive(Debug)]
pub struct EntityArena {
    pub arena: Arena<Entity>,
    pub entities: Vec<EntityId>,
}

pub fn collect_entities(repo: &dyn SourceRepo, targets: &[SourceTarget]) -> Result<EntityArena> {
    let _span = info_span!("collect_entities", target_count = targets.len()).entered();
    let mut arena = Arena::new();
    let mut entities = Vec::new();

    info!(target_count = targets.len(), "collecting source targets");

    for target in targets {
        let target_span = info_span!("collect_target", root_name = %target.root_name);
        let _target_span = target_span.entered();
        match target.language {
            Language::Rust => {
                crate::languages::rust::collect_target_entities(
                    repo,
                    target,
                    &mut arena,
                    &mut entities,
                )?;
            }
            Language::Clojure => {
                crate::languages::clojure::collect_target_entities(
                    repo,
                    target,
                    &mut arena,
                    &mut entities,
                )?;
            }
            Language::TypeScript => {
                crate::languages::typescript::collect_target_entities(
                    repo,
                    target,
                    &mut arena,
                    &mut entities,
                )?;
            }
        }
        info!(entity_count = entities.len(), "finished target");
    }

    entities.sort_by(|lhs, rhs| arena[*lhs].cmp(&arena[*rhs]));
    info!(entity_count = entities.len(), "entity collection complete");
    Ok(EntityArena { arena, entities })
}

pub fn render_entity(entity: &Entity) -> String {
    match &entity.detail {
        EntityDetail::Rust(detail) => crate::languages::rust::render_entity(entity, detail),
        EntityDetail::Clojure(detail) => crate::languages::clojure::render_entity(entity, detail),
        EntityDetail::TypeScript(detail) => {
            crate::languages::typescript::render_entity(entity, detail)
        }
    }
}

pub fn entity_kind_name(detail: &EntityDetail) -> &'static str {
    match detail {
        EntityDetail::Rust(detail) => crate::languages::rust::entity_kind_name(detail),
        EntityDetail::Clojure(detail) => crate::languages::clojure::entity_kind_name(detail),
        EntityDetail::TypeScript(detail) => crate::languages::typescript::entity_kind_name(detail),
    }
}

pub(crate) fn insert_entity(
    arena: &mut Arena<Entity>,
    entities: &mut Vec<EntityId>,
    entity: Entity,
) -> EntityId {
    let id = arena.alloc(entity);
    entities.push(id);
    id
}

pub(crate) fn compute_line_starts(text: &str) -> Vec<usize> {
    let mut starts = vec![0];
    for (idx, byte) in text.bytes().enumerate() {
        if byte == b'\n' {
            starts.push(idx + 1);
        }
    }
    starts
}

pub(crate) fn source_location_from_offsets(
    file_path: PathBuf,
    snapshot_path: PathBuf,
    line_starts: &[usize],
    start_offset: usize,
    end_offset: usize,
) -> SourceLocation {
    let start = line_col_usize(line_starts, start_offset);
    let end = line_col_usize(line_starts, end_offset);

    SourceLocation {
        file_path,
        snapshot_path,
        start_line: start.0,
        start_col: start.1,
        end_line: end.0,
        end_col: end.1,
    }
}

pub(crate) fn format_location(location: &SourceLocation) -> String {
    format!(
        "{}:{}:{}-{}:{}",
        location.file_path.display(),
        location.start_line,
        location.start_col,
        location.end_line,
        location.end_col
    )
}

fn line_col_usize(line_starts: &[usize], offset: usize) -> (u32, u32) {
    let line_index = match line_starts.binary_search(&offset) {
        Ok(idx) => idx,
        Err(idx) => idx.saturating_sub(1),
    };
    let line_start = line_starts[line_index];
    (line_index as u32 + 1, (offset - line_start) as u32 + 1)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn entity_details_are_scoped_by_language() {
        let rust_detail = EntityDetail::Rust(RustEntityDetail::Function {
            signature: "()".to_owned(),
        });
        let clojure_detail = EntityDetail::Clojure(ClojureEntityDetail::Function {
            signature: "[]".to_owned(),
        });

        assert_eq!(entity_kind_name(&rust_detail), "function");
        assert_eq!(entity_kind_name(&clojure_detail), "function");
        assert_ne!(rust_detail, clojure_detail);
        let typescript_detail = EntityDetail::TypeScript(TypeScriptEntityDetail::Function {
            signature: "()".to_owned(),
        });

        assert_eq!(entity_kind_name(&typescript_detail), "function");
        assert_ne!(rust_detail, typescript_detail);
    }
}
