use anyhow::{Context, Result};
use minidiff::{DiffOptions, OutputStyle, PresentationOptions, RenderOptions, Wrapping};
use tracing::{info, info_span};

use crate::snapshot::ModifiedEntity;

pub fn present_modified_entity(
    change: &ModifiedEntity,
) -> Result<minidiff::StructuredPresentation> {
    let _span = info_span!(
        "present_modified_entity",
        entity = %change.lhs.name,
        path = %change.lhs.location.snapshot_path.display()
    )
    .entered();

    let diff = minidiff::diff(
        change.lhs.language,
        &change.lhs.source_text,
        &change.rhs.source_text,
        DiffOptions::default(),
    )
    .with_context(|| format!("failed to diff {}", change.lhs.name))?;

    Ok(minidiff::present_side_by_side(&diff, &PresentationOptions))
}

pub fn render_modified_entity(change: &ModifiedEntity, width: Option<usize>) -> Result<String> {
    let _span = info_span!(
        "render_modified_entity",
        entity = %change.lhs.name,
        path = %change.lhs.location.snapshot_path.display(),
        width = width
    )
    .entered();

    let render_options = RenderOptions {
        output_style: OutputStyle::Ansi,
        wrapping: Wrapping::NoWrap,
        column_width: per_side_width(width),
    };
    let presentation = present_modified_entity(change)?;

    let rendered = minidiff::render_side_by_side(&presentation, &render_options)
        .with_context(|| format!("failed to render {}", change.lhs.name))?;

    info!(output_bytes = rendered.len(), "rendered minidiff output");
    Ok(rendered.trim_end().to_owned())
}

fn per_side_width(total_width: Option<usize>) -> usize {
    total_width
        .map(|value| value.saturating_sub(3) / 2)
        .filter(|value| *value >= 24)
        .unwrap_or(48)
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use minidiff::{Language, PresentationChangeKind};

    use super::*;
    use crate::{
        entity_collector::{Entity, EntityDetail, SourceLocation},
        snapshot::ModifiedEntity,
    };

    #[test]
    fn modified_entity_diff_uses_entity_language() {
        let change = ModifiedEntity {
            lhs: sample_clojure_entity("(def message \"alpha\")\n"),
            rhs: sample_clojure_entity("(def message \"beta\")\n"),
        };

        let presentation = present_modified_entity(&change).unwrap();

        assert_eq!(presentation.rows.len(), 1);
        assert_eq!(presentation.rows[0].kind, PresentationChangeKind::ReplacedString);
    }

    fn sample_clojure_entity(source_text: &str) -> Entity {
        Entity {
            name: "file".to_owned(),
            parent: None,
            language: Language::Clojure,
            location: SourceLocation {
                file_path: PathBuf::from("/tmp/project/core.clj"),
                snapshot_path: PathBuf::from("core.clj"),
                start_line: 1,
                start_col: 1,
                end_line: 1,
                end_col: source_text.len() as u32,
            },
            source_text: source_text.to_owned(),
            detail: EntityDetail::Module { is_inline: false },
        }
    }
}
