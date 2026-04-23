use anyhow::{Context, Result};
use minidiff::{DiffOptions, Language, OutputStyle, RenderOptions, Wrapping};
use tracing::{info, info_span};

use crate::snapshot::ModifiedEntity;

pub fn render_modified_entity(change: &ModifiedEntity, width: Option<usize>) -> Result<String> {
    let _span = info_span!(
        "render_modified_entity",
        entity = %change.lhs.name,
        path = %change.lhs.location.snapshot_path.display(),
        width = width
    )
    .entered();

    let diff = minidiff::diff(
        Language::Rust,
        &change.lhs.source_text,
        &change.rhs.source_text,
        DiffOptions::default(),
    )
    .with_context(|| format!("failed to diff {}", change.lhs.name))?;

    let render_options = RenderOptions {
        output_style: OutputStyle::Ansi,
        wrapping: Wrapping::NoWrap,
        column_width: per_side_width(width),
    };

    let rendered = minidiff::render_side_by_side(&diff, &render_options)
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
