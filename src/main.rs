use std::{
    env,
    path::{Path, PathBuf},
};

mod logging;

use anyhow::{Context, Result, bail};
use ra_ap_hir::{
    Adt, AssocItem, Crate, Function, HasContainer, HasSource, Impl, Module, ModuleDef, Trait,
    TypeAlias,
};
use ra_ap_ide::{Edition, FileId, RootDatabase};
use ra_ap_ide_db::{base_db::SourceDatabase, line_index};
use ra_ap_load_cargo::{LoadCargoConfig, ProcMacroServerChoice, load_workspace_at};
use ra_ap_project_model::CargoConfig;
use ra_ap_syntax::{
    AstNode,
    ast::{self, HasName},
};
use ra_ap_vfs::Vfs;
use tracing::{info, info_span};

#[derive(Debug, Clone, Eq, PartialEq, Ord, PartialOrd)]
struct Entity {
    name: String,
    location: SourceLocation,
    detail: EntityDetail,
}

#[derive(Debug, Clone, Eq, PartialEq, Ord, PartialOrd)]
struct SourceLocation {
    file_path: PathBuf,
    start_line: u32,
    start_col: u32,
    end_line: u32,
    end_col: u32,
}

#[derive(Debug, Clone, Eq, PartialEq, Ord, PartialOrd)]
enum EntityDetail {
    Module { is_inline: bool },
    Function { signature: String },
    Struct { fields: Vec<String> },
    Enum { variants: Vec<String> },
    Union { fields: Vec<String> },
    Trait { items: Vec<String> },
    TypeAlias { target: String },
    Impl { header: String, items: Vec<String> },
}

struct LoadedProject {
    db: RootDatabase,
    vfs: Vfs,
}

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
    let entities = collect_entities(&project);
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

fn load_project(path: &Path) -> Result<LoadedProject> {
    let _span = info_span!("load_project", path = %path.display()).entered();
    let cargo_config = CargoConfig::default();
    let load_config = LoadCargoConfig {
        load_out_dirs_from_check: false,
        with_proc_macro_server: ProcMacroServerChoice::None,
        prefill_caches: false,
        num_worker_threads: 1,
        proc_macro_processes: 1,
    };

    let (db, vfs, _proc_macros) = load_workspace_at(path, &cargo_config, &load_config, &|_| {})
        .with_context(|| format!("failed to load Rust workspace at {}", path.display()))?;

    info!("workspace loaded");
    Ok(LoadedProject { db, vfs })
}

fn collect_entities(project: &LoadedProject) -> Vec<Entity> {
    let _span = info_span!("collect_entities").entered();
    let mut entities = Vec::new();
    let crates = workspace_crates(&project.db);

    info!(crate_count = crates.len(), "collecting workspace crates");

    for krate in crates {
        let crate_name = crate_name(&project.db, krate);
        let crate_span = info_span!("collect_crate", crate_name = %crate_name);
        let _crate_span = crate_span.entered();
        for module in krate.modules(&project.db) {
            entities.push(module_entity(project, module));
            collect_module_entities(project, module, &mut entities);
        }

        for impl_def in Impl::all_in_crate(&project.db, krate) {
            entities.push(impl_entity(project, impl_def));

            for item in impl_def.items(&project.db) {
                if let AssocItem::Function(function) = item {
                    entities.push(function_entity(project, function));
                }
            }
        }

        info!(entity_count = entities.len(), "finished crate");
    }

    entities.sort();
    info!(entity_count = entities.len(), "entity collection complete");
    entities
}

fn collect_module_entities(project: &LoadedProject, module: Module, entities: &mut Vec<Entity>) {
    let module_name = module
        .name(&project.db)
        .map(|name| name_text(&name))
        .unwrap_or_else(|| "<crate-root>".to_owned());
    let _span = info_span!("collect_module", module = %module_name).entered();

    for declaration in module.declarations(&project.db) {
        match declaration {
            ModuleDef::Function(function) => entities.push(function_entity(project, function)),
            ModuleDef::Adt(adt) => entities.push(adt_entity(project, adt)),
            ModuleDef::Trait(trait_def) => {
                entities.push(trait_entity(project, trait_def));

                for item in trait_def.items(&project.db) {
                    if let AssocItem::Function(function) = item {
                        entities.push(function_entity(project, function));
                    }
                }
            }
            ModuleDef::TypeAlias(type_alias) => {
                entities.push(type_alias_entity(project, type_alias))
            }
            ModuleDef::Module(_) => {}
            ModuleDef::EnumVariant(_)
            | ModuleDef::Const(_)
            | ModuleDef::Static(_)
            | ModuleDef::Macro(_)
            | ModuleDef::BuiltinType(_) => {}
        }
    }
}

fn module_entity(project: &LoadedProject, module: Module) -> Entity {
    Entity {
        name: module_path(&project.db, module),
        location: module_location(project, module),
        detail: EntityDetail::Module {
            is_inline: module.is_inline(&project.db),
        },
    }
}

fn function_entity(project: &LoadedProject, function: Function) -> Entity {
    Entity {
        name: function_path(project, function),
        location: node_location(project, function.source(&project.db)),
        detail: EntityDetail::Function {
            signature: function_signature(function, &project.db),
        },
    }
}

fn adt_entity(project: &LoadedProject, adt: Adt) -> Entity {
    match adt {
        Adt::Struct(struct_def) => Entity {
            name: item_path(
                &project.db,
                struct_def.module(&project.db),
                &name_text(&struct_def.name(&project.db)),
            ),
            location: node_location(project, struct_def.source(&project.db)),
            detail: EntityDetail::Struct {
                fields: struct_fields(&project.db, struct_def),
            },
        },
        Adt::Enum(enum_def) => Entity {
            name: item_path(
                &project.db,
                enum_def.module(&project.db),
                &name_text(&enum_def.name(&project.db)),
            ),
            location: node_location(project, enum_def.source(&project.db)),
            detail: EntityDetail::Enum {
                variants: enum_variants(&project.db, enum_def),
            },
        },
        Adt::Union(union_def) => Entity {
            name: item_path(
                &project.db,
                union_def.module(&project.db),
                &name_text(&union_def.name(&project.db)),
            ),
            location: node_location(project, union_def.source(&project.db)),
            detail: EntityDetail::Union {
                fields: union_fields(&project.db, union_def),
            },
        },
    }
}

fn trait_entity(project: &LoadedProject, trait_def: Trait) -> Entity {
    Entity {
        name: item_path(
            &project.db,
            trait_def.module(&project.db),
            &name_text(&trait_def.name(&project.db)),
        ),
        location: node_location(project, trait_def.source(&project.db)),
        detail: EntityDetail::Trait {
            items: trait_items(project, trait_def),
        },
    }
}

fn type_alias_entity(project: &LoadedProject, type_alias: TypeAlias) -> Entity {
    Entity {
        name: item_path(
            &project.db,
            type_alias.module(&project.db),
            &name_text(&type_alias.name(&project.db)),
        ),
        location: node_location(project, type_alias.source(&project.db)),
        detail: EntityDetail::TypeAlias {
            target: type_alias_target(project, type_alias),
        },
    }
}

fn impl_entity(project: &LoadedProject, impl_def: Impl) -> Entity {
    Entity {
        name: impl_name(project, impl_def),
        location: node_location(project, impl_def.source(&project.db)),
        detail: EntityDetail::Impl {
            header: impl_header(project, impl_def),
            items: impl_items(project, impl_def),
        },
    }
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

fn module_path(db: &RootDatabase, module: Module) -> String {
    let mut segments = Vec::new();
    segments.push(crate_name(db, module.krate(db)));
    segments.extend(module_path_segments(db, module));
    segments.join("::")
}

fn item_path(db: &RootDatabase, module: Module, item_name: &str) -> String {
    let mut segments = Vec::new();
    segments.push(crate_name(db, module.krate(db)));
    segments.extend(module_path_segments(db, module));
    segments.push(item_name.to_owned());
    segments.join("::")
}

fn function_path(project: &LoadedProject, function: Function) -> String {
    let db = &project.db;
    let module = function.module(db);
    let mut segments = Vec::new();
    segments.push(crate_name(db, module.krate(db)));
    segments.extend(module_path_segments(db, module));

    match function.container(db) {
        ra_ap_hir::ItemContainer::Trait(trait_def) => {
            segments.push(name_text(&trait_def.name(db)));
        }
        ra_ap_hir::ItemContainer::Impl(impl_def) => {
            segments.push(impl_container_name(project, impl_def));
        }
        ra_ap_hir::ItemContainer::Module(_)
        | ra_ap_hir::ItemContainer::ExternBlock(_)
        | ra_ap_hir::ItemContainer::Crate(_) => {}
    }

    segments.push(name_text(&function.name(db)));
    segments.join("::")
}

fn impl_name(project: &LoadedProject, impl_def: Impl) -> String {
    format!(
        "{}::{}",
        module_path(&project.db, impl_def.module(&project.db)),
        impl_header(project, impl_def)
    )
}

fn impl_container_name(project: &LoadedProject, impl_def: Impl) -> String {
    let header = impl_header(project, impl_def);
    if let Some((_, rhs)) = header.split_once(" for ") {
        return rhs.trim().to_owned();
    }
    header
        .strip_prefix("impl")
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| "<impl>".to_owned())
}

fn module_path_segments(db: &RootDatabase, module: Module) -> Vec<String> {
    module
        .path_to_root(db)
        .into_iter()
        .rev()
        .filter_map(|module| module.name(db).map(|name| name_text(&name)))
        .collect()
}

fn function_signature(function: Function, db: &RootDatabase) -> String {
    let Some(source) = function.source(db) else {
        return "()".to_owned();
    };
    let params = source
        .value
        .param_list()
        .map(|param_list| {
            param_list
                .params()
                .map(|param| format_ast_param(&param))
                .collect::<Vec<_>>()
                .join(", ")
        })
        .unwrap_or_default();
    let ret = source
        .value
        .ret_type()
        .map(|ret_type| ret_type.syntax().text().to_string())
        .unwrap_or_default();

    if ret.is_empty() {
        format!("({params})")
    } else {
        format!("({params}) {ret}")
    }
}

fn struct_fields(db: &RootDatabase, struct_def: ra_ap_hir::Struct) -> Vec<String> {
    struct_def
        .source(db)
        .and_then(|source| source.value.field_list())
        .map(field_list_strings)
        .unwrap_or_default()
}

fn union_fields(db: &RootDatabase, union_def: ra_ap_hir::Union) -> Vec<String> {
    union_def
        .source(db)
        .and_then(|source| source.value.record_field_list())
        .map(|fields| {
            fields
                .fields()
                .map(|field| field.syntax().text().to_string())
                .collect()
        })
        .unwrap_or_default()
}

fn enum_variants(db: &RootDatabase, enum_def: ra_ap_hir::Enum) -> Vec<String> {
    enum_def
        .source(db)
        .and_then(|source| source.value.variant_list())
        .map(|variants| {
            variants
                .variants()
                .map(|variant| match variant.field_list() {
                    Some(field_list) => {
                        format!("{}{}", ast_name(&variant), field_list.syntax().text())
                    }
                    None => ast_name(&variant),
                })
                .collect()
        })
        .unwrap_or_default()
}

fn trait_items(project: &LoadedProject, trait_def: Trait) -> Vec<String> {
    trait_def
        .source(&project.db)
        .and_then(|source| source.value.assoc_item_list())
        .map(|items| {
            items
                .assoc_items()
                .map(|item| item.syntax().text().to_string())
                .collect()
        })
        .unwrap_or_default()
}

fn type_alias_target(project: &LoadedProject, type_alias: TypeAlias) -> String {
    type_alias
        .source(&project.db)
        .and_then(|source| source.value.ty())
        .map(|ty| ty.syntax().text().to_string())
        .unwrap_or_default()
}

fn impl_header(project: &LoadedProject, impl_def: Impl) -> String {
    impl_def
        .source(&project.db)
        .map(|source| {
            let syntax = source.value.syntax().text().to_string();
            syntax
                .split_once('{')
                .map(|(header, _)| header.trim().to_owned())
                .or_else(|| {
                    syntax
                        .split_once(';')
                        .map(|(header, _)| header.trim().to_owned())
                })
                .unwrap_or_else(|| syntax.trim().to_owned())
        })
        .unwrap_or_else(|| "impl <unknown>".to_owned())
}

fn impl_items(project: &LoadedProject, impl_def: Impl) -> Vec<String> {
    impl_def
        .source(&project.db)
        .and_then(|source| source.value.assoc_item_list())
        .map(|items| {
            items
                .assoc_items()
                .map(|item| item.syntax().text().to_string())
                .collect()
        })
        .unwrap_or_default()
}

fn field_list_strings(field_list: ast::FieldList) -> Vec<String> {
    match field_list {
        ast::FieldList::RecordFieldList(fields) => fields
            .fields()
            .map(|field| field.syntax().text().to_string())
            .collect(),
        ast::FieldList::TupleFieldList(fields) => fields
            .fields()
            .map(|field| field.syntax().text().to_string())
            .collect(),
    }
}

fn module_location(project: &LoadedProject, module: Module) -> SourceLocation {
    if let Some(declaration) = module.declaration_source(&project.db) {
        return source_location(
            &project.db,
            &project.vfs,
            declaration
                .file_id
                .original_file(&project.db)
                .file_id(&project.db),
            declaration.value.syntax().text_range(),
        );
    }

    let definition_range = module.definition_source_range(&project.db);
    source_location(
        &project.db,
        &project.vfs,
        definition_range
            .file_id
            .original_file(&project.db)
            .file_id(&project.db),
        definition_range.value,
    )
}

fn node_location<N: AstNode>(
    project: &LoadedProject,
    source: Option<ra_ap_hir::InFile<N>>,
) -> SourceLocation {
    if let Some(source) = source {
        return source_location(
            &project.db,
            &project.vfs,
            source
                .file_id
                .original_file(&project.db)
                .file_id(&project.db),
            source.value.syntax().text_range(),
        );
    }

    SourceLocation {
        file_path: PathBuf::new(),
        start_line: 0,
        start_col: 0,
        end_line: 0,
        end_col: 0,
    }
}

fn source_location(
    db: &RootDatabase,
    vfs: &Vfs,
    file_id: FileId,
    range: ra_ap_ide::TextRange,
) -> SourceLocation {
    let index = line_index(db, file_id);
    let start = index.line_col(range.start());
    let end = index.line_col(range.end());
    let file_path: PathBuf = vfs
        .file_path(file_id)
        .as_path()
        .map(|path| PathBuf::from(<ra_ap_vfs::AbsPath as AsRef<Path>>::as_ref(path)))
        .unwrap_or_else(|| PathBuf::from(vfs.file_path(file_id).to_string()));

    SourceLocation {
        file_path,
        start_line: start.line as u32 + 1,
        start_col: start.col as u32 + 1,
        end_line: end.line as u32 + 1,
        end_col: end.col as u32 + 1,
    }
}

fn render_entity(entity: &Entity) -> String {
    let location = format_location(&entity.location);

    match &entity.detail {
        EntityDetail::Module { is_inline } => {
            format!("module {} inline={} @ {}", entity.name, is_inline, location)
        }
        EntityDetail::Function { signature } => {
            format!("function {}{} @ {}", entity.name, signature, location)
        }
        EntityDetail::Struct { fields } => {
            format!(
                "struct {} fields=[{}] @ {}",
                entity.name,
                fields.join(", "),
                location
            )
        }
        EntityDetail::Enum { variants } => {
            format!(
                "enum {} variants=[{}] @ {}",
                entity.name,
                variants.join(", "),
                location
            )
        }
        EntityDetail::Union { fields } => {
            format!(
                "union {} fields=[{}] @ {}",
                entity.name,
                fields.join(", "),
                location
            )
        }
        EntityDetail::Trait { items } => {
            format!(
                "trait {} items=[{}] @ {}",
                entity.name,
                items.join(", "),
                location
            )
        }
        EntityDetail::TypeAlias { target } => {
            format!("type {} = {} @ {}", entity.name, target, location)
        }
        EntityDetail::Impl { header, items } => {
            format!("{} items=[{}] @ {}", header, items.join(", "), location)
        }
    }
}

fn format_location(location: &SourceLocation) -> String {
    format!(
        "{}:{}:{}-{}:{}",
        location.file_path.display(),
        location.start_line,
        location.start_col,
        location.end_line,
        location.end_col
    )
}

fn format_ast_param(param: &ast::Param) -> String {
    match (param.pat(), param.ty()) {
        (Some(pattern), Some(ty)) => format!("{}: {}", pattern.syntax().text(), ty.syntax().text()),
        _ => param.syntax().text().to_string(),
    }
}

fn ast_name<N: HasName>(node: &N) -> String {
    node.name()
        .map(|name| name.text().to_string())
        .unwrap_or_else(|| "<anonymous>".to_owned())
}

fn name_text(name: &ra_ap_hir::Name) -> String {
    name.display_no_db(Edition::CURRENT).to_string()
}
