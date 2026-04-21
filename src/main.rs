use std::{
    env,
    path::{Path, PathBuf},
};

mod entity_collector;
mod logging;
mod project_discovery;
mod snapshot;
mod source_repo;

use anyhow::Result;
use clap::{Parser, Subcommand};
use snapshot::{
    SnapshotSpec, build_snapshot, diff_snapshots, render_diff, resolve_snapshot_spec,
    snapshot_label,
};
use tracing::{info, info_span};

fn main() {
    if let Err(err) = run() {
        eprintln!("error: {err:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    logging::init()?;
    let cwd = env::current_dir()?;
    let cli = Cli::parse();

    match cli.command {
        Some(Command::List(args)) => run_list(&resolve_snapshot_spec(&args.snapshot, &cwd)?),
        Some(Command::Diff(args)) => {
            let lhs = resolve_snapshot_spec(&args.lhs, &cwd)?;
            let rhs = resolve_snapshot_spec(&args.rhs, &cwd)?;
            let paths = args
                .path
                .into_iter()
                .map(|path| normalize_filter_path(&path))
                .collect::<Vec<_>>();
            run_diff(&lhs, &rhs, &paths)
        }
        None => {
            let snapshot = cli
                .snapshot
                .as_deref()
                .ok_or_else(|| anyhow::anyhow!("missing required argument: <PATH_OR_REV>"))?;
            run_list(&resolve_snapshot_spec(snapshot, &cwd)?)
        }
    }
}

fn run_list(spec: &SnapshotSpec) -> Result<()> {
    let run_span = info_span!("run_list", snapshot = %snapshot_label(spec));
    let _run_span = run_span.entered();

    info!("building snapshot");
    let snapshot = build_snapshot(spec)?;
    info!(entity_count = snapshot.entities.len(), "collected entities");

    let render_span = info_span!("render_entities", entity_count = snapshot.entities.len());
    let _render_span = render_span.entered();
    for entity in snapshot.entities {
        println!("{}", entity_collector::render_entity(&entity));
    }
    info!("finished rendering entities");

    Ok(())
}

fn run_diff(lhs: &SnapshotSpec, rhs: &SnapshotSpec, path_filters: &[PathBuf]) -> Result<()> {
    let run_span = info_span!(
        "run_diff",
        lhs = %snapshot_label(lhs),
        rhs = %snapshot_label(rhs),
        filter_count = path_filters.len()
    );
    let _run_span = run_span.entered();

    info!("building lhs snapshot");
    let lhs_snapshot = build_snapshot(lhs)?;
    info!(
        entity_count = lhs_snapshot.entities.len(),
        "built lhs snapshot"
    );

    info!("building rhs snapshot");
    let rhs_snapshot = build_snapshot(rhs)?;
    info!(
        entity_count = rhs_snapshot.entities.len(),
        "built rhs snapshot"
    );

    let diff = diff_snapshots(&lhs_snapshot, &rhs_snapshot, path_filters);
    info!(
        added = diff.added.len(),
        deleted = diff.deleted.len(),
        modified = diff.modified.len(),
        "computed diff"
    );

    for line in render_diff(&diff) {
        println!("{line}");
    }

    Ok(())
}

#[derive(Debug, Parser)]
#[command(name = "rust_dive")]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,
    #[arg(value_name = "PATH_OR_REV")]
    snapshot: Option<String>,
}

#[derive(Debug, Subcommand)]
enum Command {
    List(ListArgs),
    Diff(DiffArgs),
}

#[derive(Debug, Parser)]
struct ListArgs {
    #[arg(value_name = "PATH_OR_REV")]
    snapshot: String,
}

#[derive(Debug, Parser)]
struct DiffArgs {
    #[arg(value_name = "LHS")]
    lhs: String,
    #[arg(value_name = "RHS")]
    rhs: String,
    #[arg(long = "path", value_name = "RELATIVE_PATH")]
    path: Vec<String>,
}

fn normalize_filter_path(path: &str) -> PathBuf {
    let mut normalized = PathBuf::new();
    for component in Path::new(path).components() {
        match component {
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => {
                normalized.pop();
            }
            std::path::Component::Normal(part) => normalized.push(part),
            std::path::Component::RootDir | std::path::Component::Prefix(_) => {}
        }
    }
    normalized
}
