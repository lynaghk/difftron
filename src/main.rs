use std::{
    env,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result, bail};
use ra_ap_hir::Crate;
use ra_ap_ide::RootDatabase;
use ra_ap_ide_db::base_db::SourceDatabase;
use ra_ap_load_cargo::{LoadCargoConfig, ProcMacroServerChoice, load_workspace_at};
use ra_ap_project_model::CargoConfig;

fn main() {
    if let Err(err) = run() {
        eprintln!("error: {err:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let input_path = parse_path_arg()?;
    let db = load_database(&input_path)?;

    for krate in workspace_crates(&db) {
        let name = krate
            .display_name(&db)
            .map(|name| name.to_string())
            .unwrap_or_else(|| "<unnamed>".to_owned());
        println!("{name}");
    }

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

fn load_database(path: &Path) -> Result<RootDatabase> {
    let cargo_config = CargoConfig::default();
    let load_config = LoadCargoConfig {
        load_out_dirs_from_check: false,
        with_proc_macro_server: ProcMacroServerChoice::None,
        prefill_caches: false,
        num_worker_threads: 1,
        proc_macro_processes: 1,
    };

    let (db, _vfs, _proc_macros) = load_workspace_at(path, &cargo_config, &load_config, &|msg| {
        eprintln!("{msg}");
    })
    .with_context(|| format!("failed to load Rust workspace at {}", path.display()))?;

    Ok(db)
}

fn workspace_crates(db: &RootDatabase) -> Vec<Crate> {
    let mut crates = Crate::all(db)
        .into_iter()
        .filter(|krate| is_workspace_crate(db, *krate))
        .collect::<Vec<_>>();

    crates.sort_by_key(|krate| crate_name(db, *krate));
    crates
}

fn is_workspace_crate(db: &RootDatabase, krate: Crate) -> bool {
    let root_file = krate.base().data(db).root_file_id;
    let source_root_id = db.file_source_root(root_file).source_root_id(db);
    !db.source_root(source_root_id).source_root(db).is_library
}

fn crate_name(db: &RootDatabase, krate: Crate) -> String {
    krate
        .display_name(db)
        .map(|name| name.to_string())
        .unwrap_or_else(|| "<unnamed>".to_owned())
}
