use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

use anyhow::{Context, Result, bail};
use tempfile::Builder;

use crate::snapshot::{DiffResult, ModifiedEntity};

pub fn render_diff(diff: &DiffResult) -> Result<String> {
    let mut sections = Vec::new();

    for entity in &diff.deleted {
        sections.push(format!(
            "- {}",
            crate::entity_collector::render_entity(entity)
        ));
    }

    for entity in &diff.added {
        sections.push(format!(
            "+ {}",
            crate::entity_collector::render_entity(entity)
        ));
    }

    for change in &diff.modified {
        sections.push(render_modified_entity(change)?);
    }

    if sections.is_empty() {
        Ok(String::new())
    } else {
        Ok(format!("{}\n", sections.join("\n\n")))
    }
}

fn render_modified_entity(change: &ModifiedEntity) -> Result<String> {
    let temp_dir = tempfile::tempdir().context("failed to create temporary directory")?;
    let lhs_path = write_entity_source(temp_dir.path(), "lhs", &change.lhs.source_text)?;
    let rhs_path = write_entity_source(temp_dir.path(), "rhs", &change.rhs.source_text)?;
    let display_path = &change.lhs.name;

    let output = Command::new(difft_binary())
        .arg("--display")
        .arg("side-by-side")
        .arg("--color")
        .arg("always")
        .arg("--context")
        .arg("999999")
        .arg(display_path)
        .arg(&lhs_path)
        .arg("0000000")
        .arg("100644")
        .arg(&rhs_path)
        .arg("1111111")
        .arg("100644")
        .output()
        .with_context(|| format!("failed to run difftastic for {}", change.lhs.name))?;

    if !output.status.success() && output.stdout.is_empty() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        bail!(
            "difftastic failed for {}: {}",
            change.lhs.name,
            stderr.trim()
        );
    }

    Ok(String::from_utf8_lossy(&output.stdout)
        .trim_end()
        .to_owned())
}

fn write_entity_source(dir: &Path, stem: &str, source: &str) -> Result<PathBuf> {
    let file = Builder::new()
        .prefix(stem)
        .suffix(".rs")
        .tempfile_in(dir)
        .context("failed to create temporary Rust file")?;
    fs::write(file.path(), source)
        .with_context(|| format!("failed to write {}", file.path().display()))?;
    let (_file, path) = file.keep().context("failed to persist temporary file")?;
    Ok(path)
}

fn difft_binary() -> PathBuf {
    if let Some(configured) = std::env::var_os("RUST_DIVE_DIFFT_PATH") {
        return PathBuf::from(configured);
    }

    PathBuf::from("difft")
}
