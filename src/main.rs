use std::{
    env,
    path::{Path, PathBuf},
};

mod entity_collector;
mod logging;
mod project_discovery;
mod snapshot;
mod source_repo;

use anyhow::{Result, bail};
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

    match parse_cli(&cwd)? {
        Command::List(spec) => run_list(&spec),
        Command::Diff { left, right, paths } => run_diff(&left, &right, &paths),
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

fn run_diff(left: &SnapshotSpec, right: &SnapshotSpec, path_filters: &[PathBuf]) -> Result<()> {
    let run_span = info_span!(
        "run_diff",
        left = %snapshot_label(left),
        right = %snapshot_label(right),
        filter_count = path_filters.len()
    );
    let _run_span = run_span.entered();

    info!("building left snapshot");
    let left_snapshot = build_snapshot(left)?;
    info!(
        entity_count = left_snapshot.entities.len(),
        "built left snapshot"
    );

    info!("building right snapshot");
    let right_snapshot = build_snapshot(right)?;
    info!(
        entity_count = right_snapshot.entities.len(),
        "built right snapshot"
    );

    let diff = diff_snapshots(&left_snapshot, &right_snapshot, path_filters);
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

#[derive(Debug)]
enum Command {
    List(SnapshotSpec),
    Diff {
        left: SnapshotSpec,
        right: SnapshotSpec,
        paths: Vec<PathBuf>,
    },
}

fn parse_cli(cwd: &Path) -> Result<Command> {
    let args = env::args().skip(1).collect::<Vec<_>>();
    if args.is_empty() {
        bail!(usage());
    }

    if args[0] == "diff" {
        parse_diff_args(&args[1..], cwd)
    } else if args[0] == "list" {
        if args.len() != 2 {
            bail!(usage());
        }
        Ok(Command::List(resolve_snapshot_spec(&args[1], cwd)?))
    } else if args.len() == 1 {
        Ok(Command::List(resolve_snapshot_spec(&args[0], cwd)?))
    } else {
        bail!(usage());
    }
}

fn parse_diff_args(args: &[String], cwd: &Path) -> Result<Command> {
    if args.len() < 2 {
        bail!(usage());
    }

    let left = resolve_snapshot_spec(&args[0], cwd)?;
    let right = resolve_snapshot_spec(&args[1], cwd)?;
    let mut paths = Vec::new();
    let mut index = 2;

    while index < args.len() {
        match args[index].as_str() {
            "--path" => {
                let Some(path) = args.get(index + 1) else {
                    bail!("--path requires a value");
                };
                paths.push(normalize_filter_path(path));
                index += 2;
            }
            flag => bail!("unknown argument: {flag}"),
        }
    }

    Ok(Command::Diff { left, right, paths })
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

fn usage() -> &'static str {
    "usage: rust_dive <path-or-rev>\n       rust_dive list <path-or-rev>\n       rust_dive diff <left> <right> [--path <relative-path>]..."
}
