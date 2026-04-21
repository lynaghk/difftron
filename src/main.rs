use std::{env, path::PathBuf};

mod entity_collector;
mod logging;

use anyhow::{Result, bail};
use entity_collector::{collect_entities, load_project, render_entity};
use tracing::{info, info_span};

fn main() {
    if let Err(err) = run() {
        eprintln!("error: {err:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    logging::init()?;
    let input_path = parse_path_arg()?;
    let run_span = info_span!("run", path = %input_path.display());
    let _run_span = run_span.entered();

    info!("loading project");
    let project = load_project(&input_path)?;
    let entities = collect_entities(&project)?;
    info!(entity_count = entities.len(), "collected entities");

    let render_span = info_span!("render_entities", entity_count = entities.len());
    let _render_span = render_span.entered();
    for entity in entities {
        println!("{}", render_entity(&entity));
    }
    info!("finished rendering entities");

    Ok(())
}

fn parse_path_arg() -> Result<PathBuf> {
    let mut args = env::args_os();
    let _binary = args.next();

    let Some(path) = args.next() else {
        bail!("usage: rust_dive <path-to-crate-or-workspace>");
    };

    if args.next().is_some() {
        bail!("usage: rust_dive <path-to-crate-or-workspace>");
    }

    Ok(PathBuf::from(path))
}
