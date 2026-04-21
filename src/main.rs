use std::{
    env,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result, bail};
use ra_ap_hir::{AssocItem, Crate, Function, HasContainer, HasSource, Impl, Module, ModuleDef};
use ra_ap_ide::{Edition, RootDatabase};
use ra_ap_ide_db::base_db::SourceDatabase;
use ra_ap_load_cargo::{LoadCargoConfig, ProcMacroServerChoice, load_workspace_at};
use ra_ap_project_model::CargoConfig;
use ra_ap_syntax::{AstNode, ast};

#[derive(Debug, Clone, Eq, PartialEq, Ord, PartialOrd)]
struct FunctionRecord {
    path: String,
    arity: usize,
    has_self: bool,
    params: Vec<String>,
}

fn main() {
    if let Err(err) = run() {
        eprintln!("error: {err:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let input_path = parse_path_arg()?;
    let db = load_database(&input_path)?;
    let functions = collect_functions(&db);

    for function in functions {
        println!(
            "{}({}) arity={} has_self={}",
            function.path,
            function.params.join(", "),
            function.arity,
            function.has_self
        );
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

    let (db, _vfs, _proc_macros) = load_workspace_at(path, &cargo_config, &load_config, &|_| {})
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

fn collect_functions(db: &RootDatabase) -> Vec<FunctionRecord> {
    let mut records = Vec::new();

    for krate in workspace_crates(db) {
        for module in krate.modules(db) {
            collect_module_functions(db, module, &mut records);
        }

        for impl_def in Impl::all_in_crate(db, krate) {
            for item in impl_def.items(db) {
                if let AssocItem::Function(function) = item {
                    records.push(function_record(db, function));
                }
            }
        }
    }

    records.sort();
    records
}

fn collect_module_functions(db: &RootDatabase, module: Module, records: &mut Vec<FunctionRecord>) {
    for declaration in module.declarations(db) {
        match declaration {
            ModuleDef::Function(function) => records.push(function_record(db, function)),
            ModuleDef::Trait(trait_def) => {
                for item in trait_def.items(db) {
                    if let AssocItem::Function(function) = item {
                        records.push(function_record(db, function));
                    }
                }
            }
            _ => {}
        }
    }
}

fn function_record(db: &RootDatabase, function: Function) -> FunctionRecord {
    let has_self = function.has_self_param(db);
    let params = function_params(function, db);
    FunctionRecord {
        path: function_path(db, function),
        arity: params.len(),
        has_self,
        params,
    }
}

fn function_path(db: &RootDatabase, function: Function) -> String {
    let module = function.module(db);
    let mut segments = Vec::new();
    segments.push(crate_name(db, module.krate(db)));
    segments.extend(module_path_segments(db, module));

    match function.container(db) {
        ra_ap_hir::ItemContainer::Trait(trait_def) => {
            segments.push(name_text(&trait_def.name(db)));
        }
        ra_ap_hir::ItemContainer::Impl(impl_def) => {
            segments.push(impl_container_name(db, impl_def));
        }
        ra_ap_hir::ItemContainer::Module(_)
        | ra_ap_hir::ItemContainer::ExternBlock(_)
        | ra_ap_hir::ItemContainer::Crate(_) => {}
    }

    segments.push(name_text(&function.name(db)));
    segments.join("::")
}

fn module_path_segments(db: &RootDatabase, module: Module) -> Vec<String> {
    module
        .path_to_root(db)
        .into_iter()
        .rev()
        .filter_map(|module| module.name(db).map(|name| name_text(&name)))
        .collect()
}

fn impl_container_name(db: &RootDatabase, impl_def: Impl) -> String {
    let self_ty = impl_def.self_ty(db);
    if let Some(adt) = self_ty.as_adt() {
        return name_text(&adt.name(db));
    }
    if let Some(trait_def) = self_ty.as_dyn_trait() {
        return name_text(&trait_def.name(db));
    }
    if let Some(builtin) = self_ty.as_builtin() {
        return name_text(&builtin.name());
    }
    "<impl>".to_owned()
}

fn name_text(name: &ra_ap_hir::Name) -> String {
    name.display_no_db(Edition::CURRENT).to_string()
}

fn format_ast_param(param: &ast::Param) -> String {
    match (param.pat(), param.ty()) {
        (Some(pattern), Some(ty)) => format!("{}: {}", pattern.syntax().text(), ty.syntax().text()),
        _ => param.syntax().text().to_string(),
    }
}

fn function_params(function: Function, db: &RootDatabase) -> Vec<String> {
    let Some(source) = function.source(db) else {
        return Vec::new();
    };
    let Some(param_list) = source.value.param_list() else {
        return Vec::new();
    };

    param_list
        .params()
        .map(|param| format_ast_param(&param))
        .collect()
}
