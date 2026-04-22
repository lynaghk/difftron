use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

use anyhow::{Context, Result, bail};
use tempfile::Builder;
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
    let temp_dir = tempfile::tempdir().context("failed to create temporary directory")?;
    let lhs_path = write_entity_source(temp_dir.path(), "lhs", &change.lhs.source_text)?;
    let rhs_path = write_entity_source(temp_dir.path(), "rhs", &change.rhs.source_text)?;
    let display_path = &change.lhs.name;

    let mut command = Command::new(difft_binary());
    command
        .arg("--display")
        .arg("side-by-side")
        .arg("--color")
        .arg("always")
        .arg("--context")
        .arg("999999");
    if let Some(width) = width {
        command.arg("--width").arg(width.to_string());
    }
    let output = command
        .arg(display_path)
        .arg(&lhs_path)
        .arg("0000000")
        .arg("100644")
        .arg(&rhs_path)
        .arg("1111111")
        .arg("100644")
        .output()
        .with_context(|| format!("failed to run difftastic for {}", change.lhs.name))?;
    info!(
        status = ?output.status.code(),
        stdout_bytes = output.stdout.len(),
        stderr_bytes = output.stderr.len(),
        "finished difftastic subprocess"
    );

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
