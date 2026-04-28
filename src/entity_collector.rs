use std::{
    collections::HashSet,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result};
use id_arena::{Arena, Id};
use minidiff::Language;
use ra_ap_syntax::{
    AstNode, Edition, SourceFile, TextRange, TextSize,
    ast::{self, HasAttrs, HasModuleItem, HasName},
};
use tracing::{info, info_span};
use tree_sitter_patched_arborium::{Language as TreeSitterLanguage, Node, Parser};

use crate::{project_discovery::TargetRoot, source_repo::SourceRepo};

pub type EntityId = Id<Entity>;

#[derive(Debug, Clone, Eq, PartialEq, Ord, PartialOrd)]
pub struct Entity {
    pub name: String,
    pub parent: Option<EntityId>,
    pub language: Language,
    pub location: SourceLocation,
    pub source_text: String,
    pub detail: EntityDetail,
}

#[derive(Debug, Clone, Eq, PartialEq, Ord, PartialOrd)]
pub struct SourceLocation {
    pub file_path: PathBuf,
    pub snapshot_path: PathBuf,
    pub start_line: u32,
    pub start_col: u32,
    pub end_line: u32,
    pub end_col: u32,
}

#[derive(Debug, Clone, Eq, PartialEq, Ord, PartialOrd)]
pub enum EntityDetail {
    Module { is_inline: bool },
    Namespace,
    Function { signature: String },
    Macro { signature: String },
    Multimethod { body: String },
    Method { signature: String },
    Var { value: String },
    Struct { fields: Vec<String> },
    Enum { variants: Vec<String> },
    Union { fields: Vec<String> },
    Trait { items: Vec<String> },
    Protocol { body: String },
    Record { fields: String },
    ClojureType { fields: String },
    TypeAlias { target: String },
    Impl { header: String, items: Vec<String> },
}

#[derive(Debug)]
struct ParsedFile {
    repo_path: PathBuf,
    snapshot_path: PathBuf,
    file_path: PathBuf,
    source_file: SourceFile,
    line_starts: Vec<usize>,
}

#[derive(Debug)]
struct ParsedClojureFile {
    repo_path: PathBuf,
    snapshot_path: PathBuf,
    file_path: PathBuf,
    source_text: String,
    line_starts: Vec<usize>,
}

#[derive(Debug)]
pub struct EntityArena {
    pub arena: Arena<Entity>,
    pub entities: Vec<EntityId>,
}

#[derive(Debug, Clone, Default)]
struct TraversalContext {
    modules: Vec<String>,
    container: Option<String>,
    parent: Option<EntityId>,
}

pub fn collect_entities(repo: &dyn SourceRepo, targets: &[TargetRoot]) -> Result<EntityArena> {
    let _span = info_span!("collect_entities", target_count = targets.len()).entered();
    let mut arena = Arena::new();
    let mut entities = Vec::new();

    info!(crate_count = targets.len(), "collecting workspace crates");

    for target in targets {
        let crate_span = info_span!("collect_crate", crate_name = %target.crate_name);
        let _crate_span = crate_span.entered();
        let mut visited = HashSet::new();
        collect_target_entities(repo, target, &mut visited, &mut arena, &mut entities)?;
        info!(entity_count = entities.len(), "finished crate");
    }

    entities.sort_by(|lhs, rhs| arena[*lhs].cmp(&arena[*rhs]));
    info!(entity_count = entities.len(), "entity collection complete");
    Ok(EntityArena { arena, entities })
}

pub fn render_entity(entity: &Entity) -> String {
    let location = format_location(&entity.location);

    match &entity.detail {
        EntityDetail::Module { is_inline } => {
            format!("module {} inline={} @ {}", entity.name, is_inline, location)
        }
        EntityDetail::Namespace => {
            format!("namespace {} @ {}", entity.name, location)
        }
        EntityDetail::Function { signature } => {
            format!("function {}{} @ {}", entity.name, signature, location)
        }
        EntityDetail::Macro { signature } => {
            format!("macro {}{} @ {}", entity.name, signature, location)
        }
        EntityDetail::Multimethod { body } => {
            format!("multimethod {} {} @ {}", entity.name, body, location)
        }
        EntityDetail::Method { signature } => {
            format!("method {}{} @ {}", entity.name, signature, location)
        }
        EntityDetail::Var { value } => {
            format!("var {} = {} @ {}", entity.name, value, location)
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
        EntityDetail::Protocol { body } => {
            format!("protocol {} {} @ {}", entity.name, body, location)
        }
        EntityDetail::Record { fields } => {
            format!("record {} {} @ {}", entity.name, fields, location)
        }
        EntityDetail::ClojureType { fields } => {
            format!("type {} {} @ {}", entity.name, fields, location)
        }
        EntityDetail::TypeAlias { target } => {
            format!("type {} = {} @ {}", entity.name, target, location)
        }
        EntityDetail::Impl { header, items } => {
            format!("{} items=[{}] @ {}", header, items.join(", "), location)
        }
    }
}

pub fn entity_kind_name(detail: &EntityDetail) -> &'static str {
    match detail {
        EntityDetail::Module { .. } => "module",
        EntityDetail::Namespace => "namespace",
        EntityDetail::Function { .. } => "function",
        EntityDetail::Macro { .. } => "macro",
        EntityDetail::Multimethod { .. } => "multimethod",
        EntityDetail::Method { .. } => "method",
        EntityDetail::Var { .. } => "var",
        EntityDetail::Struct { .. } => "struct",
        EntityDetail::Enum { .. } => "enum",
        EntityDetail::Union { .. } => "union",
        EntityDetail::Trait { .. } => "trait",
        EntityDetail::Protocol { .. } => "protocol",
        EntityDetail::Record { .. } => "record",
        EntityDetail::ClojureType { .. } => "type",
        EntityDetail::TypeAlias { .. } => "type_alias",
        EntityDetail::Impl { .. } => "impl",
    }
}

fn collect_target_entities(
    repo: &dyn SourceRepo,
    target: &TargetRoot,
    visited: &mut HashSet<PathBuf>,
    arena: &mut Arena<Entity>,
    entities: &mut Vec<EntityId>,
) -> Result<()> {
    if target.language == Language::Clojure {
        return collect_clojure_target_entities(repo, target, arena, entities);
    }

    let parsed = parse_file(repo, &target.root_file)?;
    visited.insert(parsed.repo_path.clone());
    let root_id = insert_entity(
        arena,
        entities,
        Entity {
            name: target.crate_name.clone(),
            parent: None,
            language: target.language,
            location: source_location(&parsed, parsed.source_file.syntax().text_range()),
            source_text: parsed.source_file.syntax().text().to_string(),
            detail: EntityDetail::Module { is_inline: false },
        },
    );

    collect_items(
        repo,
        target,
        &parsed,
        parsed.source_file.items().collect(),
        &TraversalContext {
            parent: Some(root_id),
            ..TraversalContext::default()
        },
        visited,
        arena,
        entities,
    )
}

fn collect_clojure_target_entities(
    repo: &dyn SourceRepo,
    target: &TargetRoot,
    arena: &mut Arena<Entity>,
    entities: &mut Vec<EntityId>,
) -> Result<()> {
    let parsed = parse_clojure_file(repo, &target.root_file)?;
    let mut parser = Parser::new();
    let language = TreeSitterLanguage::from(arborium_clojure::language());
    parser.set_language(&language)?;
    let Some(tree) = parser.parse(&parsed.source_text, None) else {
        anyhow::bail!("failed to parse {}", target.root_file.display());
    };
    let root = tree.root_node();
    if root.has_error() {
        anyhow::bail!("failed to parse {}", target.root_file.display());
    }

    let forms = top_level_clojure_forms(&parsed.source_text, root);
    let namespace = forms
        .iter()
        .find_map(|form| clojure_namespace(&parsed.source_text, *form))
        .unwrap_or_else(|| target.crate_name.clone());

    let root_id = insert_entity(
        arena,
        entities,
        Entity {
            name: namespace.clone(),
            parent: None,
            language: Language::Clojure,
            location: source_location_bytes(&parsed, root.byte_range()),
            source_text: parsed.source_text.clone(),
            detail: EntityDetail::Namespace,
        },
    );

    for form in forms {
        if let Some(entity) = clojure_top_level_entity(&parsed, &namespace, form, root_id) {
            insert_entity(arena, entities, entity);
        }
    }

    Ok(())
}

fn parse_file(repo: &dyn SourceRepo, snapshot_path: &Path) -> Result<ParsedFile> {
    let text = repo
        .read_file(snapshot_path)?
        .with_context(|| format!("missing {}", snapshot_path.display()))?;
    let source_file = SourceFile::parse(&text, Edition::CURRENT).tree();
    let line_starts = compute_line_starts(&text);

    Ok(ParsedFile {
        repo_path: snapshot_path.to_path_buf(),
        snapshot_path: repo.snapshot_path(snapshot_path),
        file_path: repo.file_path(snapshot_path),
        source_file,
        line_starts,
    })
}

fn parse_clojure_file(repo: &dyn SourceRepo, snapshot_path: &Path) -> Result<ParsedClojureFile> {
    let source_text = repo
        .read_file(snapshot_path)?
        .with_context(|| format!("missing {}", snapshot_path.display()))?;
    let line_starts = compute_line_starts(&source_text);

    Ok(ParsedClojureFile {
        repo_path: snapshot_path.to_path_buf(),
        snapshot_path: repo.snapshot_path(snapshot_path),
        file_path: repo.file_path(snapshot_path),
        source_text,
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

#[allow(clippy::too_many_arguments)]
fn collect_items(
    repo: &dyn SourceRepo,
    target: &TargetRoot,
    parsed: &ParsedFile,
    items: Vec<ast::Item>,
    context: &TraversalContext,
    visited: &mut HashSet<PathBuf>,
    arena: &mut Arena<Entity>,
    entities: &mut Vec<EntityId>,
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
                insert_entity(
                    arena,
                    entities,
                    function_entity(target, parsed, &function, context),
                );
            }
            ast::Item::Struct(struct_def) => {
                insert_entity(
                    arena,
                    entities,
                    struct_entity(target, parsed, &struct_def, context),
                );
            }
            ast::Item::Enum(enum_def) => {
                insert_entity(
                    arena,
                    entities,
                    enum_entity(target, parsed, &enum_def, context),
                );
            }
            ast::Item::Union(union_def) => {
                insert_entity(
                    arena,
                    entities,
                    union_entity(target, parsed, &union_def, context),
                );
            }
            ast::Item::Trait(trait_def) => {
                let trait_id = insert_entity(
                    arena,
                    entities,
                    trait_entity(target, parsed, &trait_def, context),
                );
                let nested = nested_assoc_context(context, ast_name(&trait_def), trait_id);
                collect_assoc_functions(
                    target,
                    parsed,
                    trait_def
                        .assoc_item_list()
                        .into_iter()
                        .flat_map(|list| list.assoc_items()),
                    &nested,
                    arena,
                    entities,
                );
            }
            ast::Item::TypeAlias(type_alias) => {
                insert_entity(
                    arena,
                    entities,
                    type_alias_entity(target, parsed, &type_alias, context),
                );
            }
            ast::Item::Impl(impl_def) => {
                let impl_id = insert_entity(
                    arena,
                    entities,
                    impl_entity(target, parsed, &impl_def, context),
                );
                let nested = nested_assoc_context(context, impl_container_name(&impl_def), impl_id);
                collect_assoc_functions(
                    target,
                    parsed,
                    impl_def
                        .assoc_item_list()
                        .into_iter()
                        .flat_map(|list| list.assoc_items()),
                    &nested,
                    arena,
                    entities,
                );
            }
            ast::Item::Module(module) => {
                let module_id = insert_entity(
                    arena,
                    entities,
                    module_entity(target, parsed, &module, context),
                );
                if let Some(item_list) = module.item_list() {
                    let mut nested = context.clone();
                    nested.modules.push(ast_name(&module));
                    nested.parent = Some(module_id);
                    collect_items(
                        repo,
                        target,
                        parsed,
                        item_list.items().collect(),
                        &nested,
                        visited,
                        arena,
                        entities,
                    )?;
                } else if let Some(module_file) =
                    resolve_module_file(repo, &parsed.repo_path, &module)?
                    && visited.insert(module_file.clone())
                {
                    let nested_file = parse_file(repo, &module_file)?;
                    let mut nested = context.clone();
                    nested.modules.push(ast_name(&module));
                    nested.parent = Some(module_id);
                    collect_items(
                        repo,
                        target,
                        &nested_file,
                        nested_file.source_file.items().collect(),
                        &nested,
                        visited,
                        arena,
                        entities,
                    )?;
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

fn nested_assoc_context(
    context: &TraversalContext,
    container: String,
    parent_id: EntityId,
) -> TraversalContext {
    let mut nested = context.clone();
    nested.container = Some(container);
    nested.parent = Some(parent_id);
    nested
}

fn collect_assoc_functions(
    target: &TargetRoot,
    parsed: &ParsedFile,
    assoc_items: impl IntoIterator<Item = ast::AssocItem>,
    context: &TraversalContext,
    arena: &mut Arena<Entity>,
    entities: &mut Vec<EntityId>,
) {
    for item in assoc_items {
        if is_test_only(&item) {
            continue;
        }

        if let ast::AssocItem::Fn(function) = item {
            insert_entity(
                arena,
                entities,
                function_entity(target, parsed, &function, context),
            );
        }
    }
}

fn top_level_clojure_forms<'tree>(source: &str, root: Node<'tree>) -> Vec<Node<'tree>> {
    let mut forms = Vec::new();
    let mut cursor = root.walk();
    for child in root.children(&mut cursor) {
        if source[child.byte_range()].trim_start().starts_with('(') {
            forms.push(child);
        }
    }
    forms
}

fn clojure_namespace(source: &str, form: Node<'_>) -> Option<String> {
    let elements = clojure_form_elements(source, form);
    let head = elements.first()?;
    if clojure_node_text(source, *head) != "ns" {
        return None;
    }
    elements.get(1).map(|node| clojure_node_text(source, *node))
}

fn clojure_top_level_entity(
    parsed: &ParsedClojureFile,
    namespace: &str,
    form: Node<'_>,
    parent: EntityId,
) -> Option<Entity> {
    let source = &parsed.source_text;
    let elements = clojure_form_elements(source, form);
    let head = elements
        .first()
        .map(|node| clojure_node_text(source, *node))?;
    let name = elements
        .get(1)
        .map(|node| clojure_node_text(source, *node))?;

    let detail = match head.as_str() {
        "defn" | "defn-" => EntityDetail::Function {
            signature: clojure_function_signature(source, &elements),
        },
        "defmacro" => EntityDetail::Macro {
            signature: clojure_function_signature(source, &elements),
        },
        "defmulti" => EntityDetail::Multimethod {
            body: clojure_form_tail(source, &elements, 2),
        },
        "defmethod" => EntityDetail::Method {
            signature: clojure_function_signature(source, &elements),
        },
        "def" | "defonce" => EntityDetail::Var {
            value: clojure_form_tail(source, &elements, 2),
        },
        "defprotocol" => EntityDetail::Protocol {
            body: clojure_form_tail(source, &elements, 2),
        },
        "defrecord" => EntityDetail::Record {
            fields: clojure_form_tail(source, &elements, 2),
        },
        "deftype" => EntityDetail::ClojureType {
            fields: clojure_form_tail(source, &elements, 2),
        },
        _ => return None,
    };

    Some(Entity {
        name: format!("{namespace}::{name}"),
        parent: Some(parent),
        language: Language::Clojure,
        location: source_location_bytes(parsed, form.byte_range()),
        source_text: source[form.byte_range()].to_owned(),
        detail,
    })
}

fn clojure_form_elements<'tree>(source: &str, form: Node<'tree>) -> Vec<Node<'tree>> {
    let mut elements = Vec::new();
    let mut cursor = form.walk();
    for child in form.children(&mut cursor) {
        let text = source[child.byte_range()].trim();
        if text.is_empty() || matches!(text, "(" | ")" | "[" | "]" | "{" | "}" | "#{") {
            continue;
        }
        elements.push(child);
    }
    elements
}

fn clojure_node_text(source: &str, node: Node<'_>) -> String {
    source[node.byte_range()].trim().to_owned()
}

fn clojure_function_signature(source: &str, elements: &[Node<'_>]) -> String {
    elements
        .iter()
        .skip(2)
        .map(|node| clojure_node_text(source, *node))
        .find(|text| text.starts_with('['))
        .unwrap_or_else(|| "[]".to_owned())
}

fn clojure_form_tail(source: &str, elements: &[Node<'_>], start: usize) -> String {
    elements
        .iter()
        .skip(start)
        .map(|node| clojure_node_text(source, *node))
        .collect::<Vec<_>>()
        .join(" ")
}

fn insert_entity(
    arena: &mut Arena<Entity>,
    entities: &mut Vec<EntityId>,
    entity: Entity,
) -> EntityId {
    let id = arena.alloc(entity);
    entities.push(id);
    id
}

fn module_entity(
    target: &TargetRoot,
    parsed: &ParsedFile,
    module: &ast::Module,
    context: &TraversalContext,
) -> Entity {
    Entity {
        name: qualified_name(target, context, &ast_name(module)),
        parent: context.parent,
        language: target.language,
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
        parent: context.parent,
        language: target.language,
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
        parent: context.parent,
        language: target.language,
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
        parent: context.parent,
        language: target.language,
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
        parent: context.parent,
        language: target.language,
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
        parent: context.parent,
        language: target.language,
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
        parent: context.parent,
        language: target.language,
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
        parent: context.parent,
        language: target.language,
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

fn resolve_module_file(
    repo: &dyn SourceRepo,
    current_file: &Path,
    module: &ast::Module,
) -> Result<Option<PathBuf>> {
    let Some(module_name) = module.name().map(|name| name.text().to_string()) else {
        return Ok(None);
    };
    let Some(parent_dir) = current_file.parent() else {
        return Ok(None);
    };

    let is_root_like = current_file
        .file_stem()
        .is_some_and(|stem| stem == "mod" || stem == "lib" || stem == "main");
    let search_dir = if is_root_like {
        parent_dir.to_path_buf()
    } else {
        parent_dir.join(current_file.file_stem().unwrap_or_default())
    };

    let candidates = [
        search_dir.join(format!("{module_name}.rs")),
        search_dir.join(&module_name).join("mod.rs"),
    ];

    for candidate in candidates {
        if repo.is_file(&candidate)? {
            return Ok(Some(candidate));
        }
    }

    Ok(None)
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
        file_path: parsed.file_path.clone(),
        snapshot_path: parsed.snapshot_path.clone(),
        start_line: start.0,
        start_col: start.1,
        end_line: end.0,
        end_col: end.1,
    }
}

fn source_location_bytes(
    parsed: &ParsedClojureFile,
    range: std::ops::Range<usize>,
) -> SourceLocation {
    debug_assert!(!parsed.repo_path.as_os_str().is_empty());
    let start = line_col_usize(&parsed.line_starts, range.start);
    let end = line_col_usize(&parsed.line_starts, range.end);

    SourceLocation {
        file_path: parsed.file_path.clone(),
        snapshot_path: parsed.snapshot_path.clone(),
        start_line: start.0,
        start_col: start.1,
        end_line: end.0,
        end_col: end.1,
    }
}

fn line_col(line_starts: &[usize], offset: TextSize) -> (u32, u32) {
    line_col_usize(line_starts, usize::from(offset))
}

fn line_col_usize(line_starts: &[usize], offset: usize) -> (u32, u32) {
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
