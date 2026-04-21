use std::{
    collections::HashSet,
    fs,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result};
use cargo_metadata::{MetadataCommand, Package, PackageId, Target, TargetKind};
use ra_ap_syntax::{
    AstNode, Edition, SourceFile, TextRange, TextSize,
    ast::{self, HasAttrs, HasModuleItem, HasName},
};
use tracing::{info, info_span};

#[derive(Debug, Clone, Eq, PartialEq, Ord, PartialOrd)]
pub struct Entity {
    pub name: String,
    pub location: SourceLocation,
    pub source_text: String,
    pub detail: EntityDetail,
}

#[derive(Debug, Clone, Eq, PartialEq, Ord, PartialOrd)]
pub struct SourceLocation {
    pub file_path: PathBuf,
    pub start_line: u32,
    pub start_col: u32,
    pub end_line: u32,
    pub end_col: u32,
}

#[derive(Debug, Clone, Eq, PartialEq, Ord, PartialOrd)]
pub enum EntityDetail {
    Module { is_inline: bool },
    Function { signature: String },
    Struct { fields: Vec<String> },
    Enum { variants: Vec<String> },
    Union { fields: Vec<String> },
    Trait { items: Vec<String> },
    TypeAlias { target: String },
    Impl { header: String, items: Vec<String> },
}

#[derive(Debug, Clone)]
pub struct LoadedProject {
    targets: Vec<TargetRoot>,
}

#[derive(Debug, Clone)]
struct TargetRoot {
    crate_name: String,
    root_file: PathBuf,
}

#[derive(Debug)]
struct ParsedFile {
    path: PathBuf,
    source_file: SourceFile,
    line_starts: Vec<usize>,
}

#[derive(Debug, Clone, Default)]
struct TraversalContext {
    modules: Vec<String>,
    container: Option<String>,
}

pub fn load_project(path: &Path) -> Result<LoadedProject> {
    let _span = info_span!("load_project", path = %path.display()).entered();
    let metadata = cargo_metadata(path)?;
    let targets = workspace_targets(&metadata);
    info!(target_count = targets.len(), "workspace loaded");
    Ok(LoadedProject { targets })
}

pub fn collect_entities(project: &LoadedProject) -> Result<Vec<Entity>> {
    let _span = info_span!("collect_entities").entered();
    let mut entities = Vec::new();

    info!(
        crate_count = project.targets.len(),
        "collecting workspace crates"
    );

    for target in &project.targets {
        let crate_span = info_span!("collect_crate", crate_name = %target.crate_name);
        let _crate_span = crate_span.entered();
        let mut visited = HashSet::new();
        collect_target_entities(target, &mut visited, &mut entities)?;
        info!(entity_count = entities.len(), "finished crate");
    }

    entities.sort();
    info!(entity_count = entities.len(), "entity collection complete");
    Ok(entities)
}

pub fn render_entity(entity: &Entity) -> String {
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

fn cargo_metadata(path: &Path) -> Result<cargo_metadata::Metadata> {
    let mut command = MetadataCommand::new();
    command.no_deps();

    if path.is_file() {
        command.manifest_path(path);
    } else {
        let manifest_path = path.join("Cargo.toml");
        if manifest_path.exists() {
            command.manifest_path(manifest_path);
        } else {
            command.current_dir(path);
        }
    }

    command.exec().context("failed to run cargo metadata")
}

fn workspace_targets(metadata: &cargo_metadata::Metadata) -> Vec<TargetRoot> {
    let workspace_members: HashSet<&PackageId> = metadata.workspace_members.iter().collect();
    let packages_by_id = metadata
        .packages
        .iter()
        .map(|package| (&package.id, package))
        .collect::<std::collections::HashMap<_, _>>();

    let mut targets = workspace_members
        .into_iter()
        .filter_map(|id| packages_by_id.get(id).copied())
        .flat_map(target_roots_for_package)
        .collect::<Vec<_>>();

    targets.sort_by(|left, right| {
        left.crate_name
            .cmp(&right.crate_name)
            .then_with(|| left.root_file.cmp(&right.root_file))
    });
    targets
}

fn target_roots_for_package(package: &Package) -> Vec<TargetRoot> {
    package
        .targets
        .iter()
        .filter(|target| is_supported_target(target))
        .map(|target| TargetRoot {
            crate_name: target.name.replace('-', "_"),
            root_file: target.src_path.as_std_path().to_path_buf(),
        })
        .collect()
}

fn is_supported_target(target: &Target) -> bool {
    target.src_path.extension().is_some_and(|ext| ext == "rs")
        && target.kind.iter().any(|kind| {
            matches!(
                kind,
                TargetKind::Lib
                    | TargetKind::Bin
                    | TargetKind::Example
                    | TargetKind::Test
                    | TargetKind::Bench
            )
        })
}

fn collect_target_entities(
    target: &TargetRoot,
    visited: &mut HashSet<PathBuf>,
    entities: &mut Vec<Entity>,
) -> Result<()> {
    let parsed = parse_file(&target.root_file)?;
    visited.insert(parsed.path.clone());
    entities.push(Entity {
        name: target.crate_name.clone(),
        location: source_location(&parsed, parsed.source_file.syntax().text_range()),
        source_text: parsed.source_file.syntax().text().to_string(),
        detail: EntityDetail::Module { is_inline: false },
    });

    collect_items(
        target,
        &parsed,
        parsed.source_file.items().collect(),
        &TraversalContext::default(),
        visited,
        entities,
    )
}

fn parse_file(path: &Path) -> Result<ParsedFile> {
    let text =
        fs::read_to_string(path).with_context(|| format!("failed to read {}", path.display()))?;
    let source_file = SourceFile::parse(&text, Edition::CURRENT).tree();
    let line_starts = compute_line_starts(&text);

    Ok(ParsedFile {
        path: path.to_path_buf(),
        source_file,
        line_starts,
    })
}

fn compute_line_starts(text: &str) -> Vec<usize> {
    let mut starts = vec![0];
    for (idx, byte) in text.bytes().enumerate() {
        if byte == b'\n' {
            starts.push(idx + 1);
        }
    }
    starts
}

fn collect_items(
    target: &TargetRoot,
    parsed: &ParsedFile,
    items: Vec<ast::Item>,
    context: &TraversalContext,
    visited: &mut HashSet<PathBuf>,
    entities: &mut Vec<Entity>,
) -> Result<()> {
    let module_name = context
        .modules
        .last()
        .cloned()
        .unwrap_or_else(|| "<crate-root>".to_owned());
    let _span = info_span!("collect_module", module = %module_name).entered();

    for item in items {
        if is_test_only(&item) {
            continue;
        }

        match item {
            ast::Item::Fn(function) => {
                entities.push(function_entity(target, parsed, &function, context));
            }
            ast::Item::Struct(struct_def) => {
                entities.push(struct_entity(target, parsed, &struct_def, context));
            }
            ast::Item::Enum(enum_def) => {
                entities.push(enum_entity(target, parsed, &enum_def, context));
            }
            ast::Item::Union(union_def) => {
                entities.push(union_entity(target, parsed, &union_def, context));
            }
            ast::Item::Trait(trait_def) => {
                entities.push(trait_entity(target, parsed, &trait_def, context));
                let mut nested = context.clone();
                nested.container = Some(ast_name(&trait_def));
                collect_assoc_functions(
                    target,
                    parsed,
                    trait_def
                        .assoc_item_list()
                        .map(|list| list.assoc_items().collect())
                        .unwrap_or_default(),
                    &nested,
                    entities,
                );
            }
            ast::Item::TypeAlias(type_alias) => {
                entities.push(type_alias_entity(target, parsed, &type_alias, context));
            }
            ast::Item::Impl(impl_def) => {
                entities.push(impl_entity(target, parsed, &impl_def, context));
                let mut nested = context.clone();
                nested.container = Some(impl_container_name(&impl_def));
                collect_assoc_functions(
                    target,
                    parsed,
                    impl_def
                        .assoc_item_list()
                        .map(|list| list.assoc_items().collect())
                        .unwrap_or_default(),
                    &nested,
                    entities,
                );
            }
            ast::Item::Module(module) => {
                entities.push(module_entity(target, parsed, &module, context));
                if let Some(item_list) = module.item_list() {
                    let mut nested = context.clone();
                    nested.modules.push(ast_name(&module));
                    collect_items(
                        target,
                        parsed,
                        item_list.items().collect(),
                        &nested,
                        visited,
                        entities,
                    )?;
                } else if let Some(module_file) = resolve_module_file(&parsed.path, &module) {
                    let module_file = fs::canonicalize(&module_file).unwrap_or(module_file);
                    if visited.insert(module_file.clone()) {
                        let nested_file = parse_file(&module_file)?;
                        let mut nested = context.clone();
                        nested.modules.push(ast_name(&module));
                        collect_items(
                            target,
                            &nested_file,
                            nested_file.source_file.items().collect(),
                            &nested,
                            visited,
                            entities,
                        )?;
                    }
                }
            }
            ast::Item::Const(_)
            | ast::Item::ExternBlock(_)
            | ast::Item::ExternCrate(_)
            | ast::Item::MacroCall(_)
            | ast::Item::MacroDef(_)
            | ast::Item::MacroRules(_)
            | ast::Item::Static(_)
            | ast::Item::Use(_)
            | ast::Item::AsmExpr(_) => {}
        }
    }

    Ok(())
}

fn collect_assoc_functions(
    target: &TargetRoot,
    parsed: &ParsedFile,
    assoc_items: Vec<ast::AssocItem>,
    context: &TraversalContext,
    entities: &mut Vec<Entity>,
) {
    for item in assoc_items {
        if is_test_only(&item) {
            continue;
        }

        if let ast::AssocItem::Fn(function) = item {
            entities.push(function_entity(target, parsed, &function, context));
        }
    }
}

fn module_entity(
    target: &TargetRoot,
    parsed: &ParsedFile,
    module: &ast::Module,
    context: &TraversalContext,
) -> Entity {
    Entity {
        name: qualified_name(target, context, &ast_name(module)),
        location: source_location(parsed, module.syntax().text_range()),
        source_text: module.syntax().text().to_string(),
        detail: EntityDetail::Module {
            is_inline: module.item_list().is_some(),
        },
    }
}

fn function_entity(
    target: &TargetRoot,
    parsed: &ParsedFile,
    function: &ast::Fn,
    context: &TraversalContext,
) -> Entity {
    let mut name = path_prefix(target, context);
    if let Some(container) = &context.container {
        name.push(container.clone());
    }
    name.push(ast_name(function));

    Entity {
        name: name.join("::"),
        location: source_location(parsed, function.syntax().text_range()),
        source_text: function.syntax().text().to_string(),
        detail: EntityDetail::Function {
            signature: function_signature(function),
        },
    }
}

fn struct_entity(
    target: &TargetRoot,
    parsed: &ParsedFile,
    struct_def: &ast::Struct,
    context: &TraversalContext,
) -> Entity {
    Entity {
        name: qualified_name(target, context, &ast_name(struct_def)),
        location: source_location(parsed, struct_def.syntax().text_range()),
        source_text: struct_def.syntax().text().to_string(),
        detail: EntityDetail::Struct {
            fields: struct_def
                .field_list()
                .map(field_list_strings)
                .unwrap_or_default(),
        },
    }
}

fn enum_entity(
    target: &TargetRoot,
    parsed: &ParsedFile,
    enum_def: &ast::Enum,
    context: &TraversalContext,
) -> Entity {
    Entity {
        name: qualified_name(target, context, &ast_name(enum_def)),
        location: source_location(parsed, enum_def.syntax().text_range()),
        source_text: enum_def.syntax().text().to_string(),
        detail: EntityDetail::Enum {
            variants: enum_def
                .variant_list()
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
                .unwrap_or_default(),
        },
    }
}

fn union_entity(
    target: &TargetRoot,
    parsed: &ParsedFile,
    union_def: &ast::Union,
    context: &TraversalContext,
) -> Entity {
    Entity {
        name: qualified_name(target, context, &ast_name(union_def)),
        location: source_location(parsed, union_def.syntax().text_range()),
        source_text: union_def.syntax().text().to_string(),
        detail: EntityDetail::Union {
            fields: union_def
                .record_field_list()
                .map(|fields| {
                    fields
                        .fields()
                        .map(|field| field.syntax().text().to_string())
                        .collect()
                })
                .unwrap_or_default(),
        },
    }
}

fn trait_entity(
    target: &TargetRoot,
    parsed: &ParsedFile,
    trait_def: &ast::Trait,
    context: &TraversalContext,
) -> Entity {
    Entity {
        name: qualified_name(target, context, &ast_name(trait_def)),
        location: source_location(parsed, trait_def.syntax().text_range()),
        source_text: trait_def.syntax().text().to_string(),
        detail: EntityDetail::Trait {
            items: trait_def
                .assoc_item_list()
                .map(|items| {
                    items
                        .assoc_items()
                        .map(|item| item.syntax().text().to_string())
                        .collect()
                })
                .unwrap_or_default(),
        },
    }
}

fn type_alias_entity(
    target: &TargetRoot,
    parsed: &ParsedFile,
    type_alias: &ast::TypeAlias,
    context: &TraversalContext,
) -> Entity {
    Entity {
        name: qualified_name(target, context, &ast_name(type_alias)),
        location: source_location(parsed, type_alias.syntax().text_range()),
        source_text: type_alias.syntax().text().to_string(),
        detail: EntityDetail::TypeAlias {
            target: type_alias
                .ty()
                .map(|ty| ty.syntax().text().to_string())
                .unwrap_or_default(),
        },
    }
}

fn impl_entity(
    target: &TargetRoot,
    parsed: &ParsedFile,
    impl_def: &ast::Impl,
    context: &TraversalContext,
) -> Entity {
    let header = impl_header(impl_def);
    Entity {
        name: format!("{}::{}", path_prefix(target, context).join("::"), header),
        location: source_location(parsed, impl_def.syntax().text_range()),
        source_text: impl_def.syntax().text().to_string(),
        detail: EntityDetail::Impl {
            header,
            items: impl_def
                .assoc_item_list()
                .map(|items| {
                    items
                        .assoc_items()
                        .map(|item| item.syntax().text().to_string())
                        .collect()
                })
                .unwrap_or_default(),
        },
    }
}

fn resolve_module_file(current_file: &Path, module: &ast::Module) -> Option<PathBuf> {
    let module_name = module.name()?.text().to_string();
    let parent_dir = current_file.parent()?;
    let is_root_like = current_file
        .file_stem()
        .is_some_and(|stem| stem == "mod" || stem == "lib" || stem == "main");
    let search_dir = if is_root_like {
        parent_dir.to_path_buf()
    } else {
        parent_dir.join(current_file.file_stem()?)
    };

    let candidates = [
        search_dir.join(format!("{module_name}.rs")),
        search_dir.join(module_name).join("mod.rs"),
    ];

    candidates.into_iter().find(|candidate| candidate.exists())
}

fn path_prefix(target: &TargetRoot, context: &TraversalContext) -> Vec<String> {
    let mut parts = vec![target.crate_name.clone()];
    parts.extend(context.modules.iter().cloned());
    parts
}

fn qualified_name(target: &TargetRoot, context: &TraversalContext, name: &str) -> String {
    let mut parts = path_prefix(target, context);
    parts.push(name.to_owned());
    parts.join("::")
}

fn function_signature(function: &ast::Fn) -> String {
    let params = function
        .param_list()
        .map(|param_list| {
            param_list
                .params()
                .map(|param| format_ast_param(&param))
                .collect::<Vec<_>>()
                .join(", ")
        })
        .unwrap_or_default();
    let ret = function
        .ret_type()
        .map(|ret_type| ret_type.syntax().text().to_string())
        .unwrap_or_default();

    if ret.is_empty() {
        format!("({params})")
    } else {
        format!("({params}) {ret}")
    }
}

fn impl_header(impl_def: &ast::Impl) -> String {
    let syntax = impl_def.syntax().text().to_string();
    syntax
        .split_once('{')
        .map(|(header, _)| header.trim().to_owned())
        .or_else(|| {
            syntax
                .split_once(';')
                .map(|(header, _)| header.trim().to_owned())
        })
        .unwrap_or_else(|| syntax.trim().to_owned())
}

fn impl_container_name(impl_def: &ast::Impl) -> String {
    let header = impl_header(impl_def);
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

fn source_location(parsed: &ParsedFile, range: TextRange) -> SourceLocation {
    let start = line_col(&parsed.line_starts, range.start());
    let end = line_col(&parsed.line_starts, range.end());

    SourceLocation {
        file_path: parsed.path.clone(),
        start_line: start.0,
        start_col: start.1,
        end_line: end.0,
        end_col: end.1,
    }
}

fn line_col(line_starts: &[usize], offset: TextSize) -> (u32, u32) {
    let offset = usize::from(offset);
    let line_index = match line_starts.binary_search(&offset) {
        Ok(idx) => idx,
        Err(idx) => idx.saturating_sub(1),
    };
    let line_start = line_starts[line_index];
    (line_index as u32 + 1, (offset - line_start) as u32 + 1)
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

fn is_test_only<N: HasAttrs>(node: &N) -> bool {
    node.attrs().any(|attr| {
        let text = attr.syntax().text().to_string();
        text.contains("cfg(test)") || text.contains("cfg(any(test") || text.contains("cfg(all(test")
    })
}
