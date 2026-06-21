use std::{ops::Range, path::PathBuf};

use anyhow::{Context, Result};
use id_arena::Arena;
use minidiff::Language;
use tree_sitter_patched_arborium::{Language as TreeSitterLanguage, Node, Parser};

use crate::{
    entity_collector::{
        Entity, EntityDetail, EntityId, SourceLocation, compute_line_starts, format_location,
        insert_entity, source_location_from_offsets,
    },
    project_discovery::SourceTarget,
    source_repo::SourceRepo,
};

#[derive(Debug, Clone, Eq, PartialEq, Ord, PartialOrd)]
pub enum TypeScriptEntityDetail {
    Module,
    Function { signature: String },
    Class { members: Vec<String> },
    Interface { members: Vec<String> },
    TypeAlias { target: String },
    Enum { variants: Vec<String> },
    Var { value: String },
    Method { signature: String },
}

#[derive(Debug)]
struct ParsedTypeScriptFile {
    repo_path: PathBuf,
    snapshot_path: PathBuf,
    file_path: PathBuf,
    source_text: String,
    line_starts: Vec<usize>,
}

pub fn collect_target_entities(
    repo: &dyn SourceRepo,
    target: &SourceTarget,
    arena: &mut Arena<Entity>,
    entities: &mut Vec<EntityId>,
) -> Result<()> {
    let parsed = parse_typescript_file(repo, &target.root_file)?;
    let mut parser = Parser::new();
    let language = TreeSitterLanguage::from(arborium_typescript::language());
    parser.set_language(&language)?;
    let Some(tree) = parser.parse(&parsed.source_text, None) else {
        anyhow::bail!("failed to parse {}", target.root_file.display());
    };
    let root = tree.root_node();

    let root_id = insert_entity(
        arena,
        entities,
        Entity {
            name: target.root_name.clone(),
            parent: None,
            language: Language::TypeScript,
            location: source_location_bytes(&parsed, root.byte_range()),
            source_text: parsed.source_text.clone(),
            detail: EntityDetail::TypeScript(TypeScriptEntityDetail::Module),
        },
    );

    collect_top_level_entities(&parsed, target, root, root_id, arena, entities);

    Ok(())
}

pub fn render_entity(entity: &Entity, detail: &TypeScriptEntityDetail) -> String {
    let location = format_location(&entity.location);

    match detail {
        TypeScriptEntityDetail::Module => {
            format!("module {} @ {}", entity.name, location)
        }
        TypeScriptEntityDetail::Function { signature } => {
            format!("function {}{} @ {}", entity.name, signature, location)
        }
        TypeScriptEntityDetail::Class { members } => {
            format!(
                "class {} members=[{}] @ {}",
                entity.name,
                members.join(", "),
                location
            )
        }
        TypeScriptEntityDetail::Interface { members } => {
            format!(
                "interface {} members=[{}] @ {}",
                entity.name,
                members.join(", "),
                location
            )
        }
        TypeScriptEntityDetail::TypeAlias { target } => {
            format!("type {} = {} @ {}", entity.name, target, location)
        }
        TypeScriptEntityDetail::Enum { variants } => {
            format!(
                "enum {} variants=[{}] @ {}",
                entity.name,
                variants.join(", "),
                location
            )
        }
        TypeScriptEntityDetail::Var { value } => {
            format!("var {} = {} @ {}", entity.name, value, location)
        }
        TypeScriptEntityDetail::Method { signature } => {
            format!("method {}{} @ {}", entity.name, signature, location)
        }
    }
}

pub fn entity_kind_name(detail: &TypeScriptEntityDetail) -> &'static str {
    match detail {
        TypeScriptEntityDetail::Module => "module",
        TypeScriptEntityDetail::Function { .. } => "function",
        TypeScriptEntityDetail::Class { .. } => "class",
        TypeScriptEntityDetail::Interface { .. } => "interface",
        TypeScriptEntityDetail::TypeAlias { .. } => "type_alias",
        TypeScriptEntityDetail::Enum { .. } => "enum",
        TypeScriptEntityDetail::Var { .. } => "var",
        TypeScriptEntityDetail::Method { .. } => "method",
    }
}

fn parse_typescript_file(
    repo: &dyn SourceRepo,
    snapshot_path: &std::path::Path,
) -> Result<ParsedTypeScriptFile> {
    let source_text = repo
        .read_file(snapshot_path)?
        .with_context(|| format!("missing {}", snapshot_path.display()))?;
    let line_starts = compute_line_starts(&source_text);

    Ok(ParsedTypeScriptFile {
        repo_path: snapshot_path.to_path_buf(),
        snapshot_path: repo.snapshot_path(snapshot_path),
        file_path: repo.file_path(snapshot_path),
        source_text,
        line_starts,
    })
}

fn collect_top_level_entities(
    parsed: &ParsedTypeScriptFile,
    target: &SourceTarget,
    root: Node<'_>,
    parent: EntityId,
    arena: &mut Arena<Entity>,
    entities: &mut Vec<EntityId>,
) {
    let mut cursor = root.walk();
    for child in root.children(&mut cursor) {
        let declaration = exported_declaration(child).unwrap_or(child);
        match declaration.kind() {
            "function_declaration" | "generator_function_declaration" => {
                if let Some(entity) = function_entity(parsed, target, declaration, parent) {
                    insert_entity(arena, entities, entity);
                }
            }
            "class_declaration" | "abstract_class_declaration" => {
                if let Some((entity, class_id)) =
                    class_entity(parsed, target, declaration, parent, arena, entities)
                {
                    collect_class_methods(
                        parsed,
                        declaration,
                        &entity.name,
                        class_id,
                        arena,
                        entities,
                    );
                }
            }
            "interface_declaration" => {
                if let Some(entity) = interface_entity(parsed, target, declaration, parent) {
                    insert_entity(arena, entities, entity);
                }
            }
            "type_alias_declaration" => {
                if let Some(entity) = type_alias_entity(parsed, target, declaration, parent) {
                    insert_entity(arena, entities, entity);
                }
            }
            "enum_declaration" => {
                if let Some(entity) = enum_entity(parsed, target, declaration, parent) {
                    insert_entity(arena, entities, entity);
                }
            }
            "lexical_declaration" | "variable_declaration" => {
                collect_var_entities(parsed, target, declaration, parent, arena, entities);
            }
            _ => {}
        }
    }
}

fn exported_declaration(node: Node<'_>) -> Option<Node<'_>> {
    (node.kind() == "export_statement")
        .then(|| node.child_by_field_name("declaration"))
        .flatten()
}

fn function_entity(
    parsed: &ParsedTypeScriptFile,
    target: &SourceTarget,
    node: Node<'_>,
    parent: EntityId,
) -> Option<Entity> {
    let name = node_text(parsed, node.child_by_field_name("name")?);
    Some(Entity {
        name: qualified_name(target, &name),
        parent: Some(parent),
        language: Language::TypeScript,
        location: source_location_bytes(parsed, node.byte_range()),
        source_text: source_text(parsed, node),
        detail: EntityDetail::TypeScript(TypeScriptEntityDetail::Function {
            signature: callable_signature(parsed, node),
        }),
    })
}

fn class_entity(
    parsed: &ParsedTypeScriptFile,
    target: &SourceTarget,
    node: Node<'_>,
    parent: EntityId,
    arena: &mut Arena<Entity>,
    entities: &mut Vec<EntityId>,
) -> Option<(Entity, EntityId)> {
    let name = node_text(parsed, node.child_by_field_name("name")?);
    let entity = Entity {
        name: qualified_name(target, &name),
        parent: Some(parent),
        language: Language::TypeScript,
        location: source_location_bytes(parsed, node.byte_range()),
        source_text: source_text(parsed, node),
        detail: EntityDetail::TypeScript(TypeScriptEntityDetail::Class {
            members: class_members(parsed, node),
        }),
    };
    let id = insert_entity(arena, entities, entity.clone());
    Some((entity, id))
}

fn collect_class_methods(
    parsed: &ParsedTypeScriptFile,
    class_node: Node<'_>,
    class_name: &str,
    parent: EntityId,
    arena: &mut Arena<Entity>,
    entities: &mut Vec<EntityId>,
) {
    let Some(body) = class_node.child_by_field_name("body") else {
        return;
    };

    let mut cursor = body.walk();
    for child in body.children(&mut cursor) {
        if !matches!(
            child.kind(),
            "method_definition" | "abstract_method_signature"
        ) {
            continue;
        }
        let Some(name_node) = child.child_by_field_name("name") else {
            continue;
        };
        let method_name = node_text(parsed, name_node);
        insert_entity(
            arena,
            entities,
            Entity {
                name: format!("{class_name}::{method_name}"),
                parent: Some(parent),
                language: Language::TypeScript,
                location: source_location_bytes(parsed, child.byte_range()),
                source_text: source_text(parsed, child),
                detail: EntityDetail::TypeScript(TypeScriptEntityDetail::Method {
                    signature: callable_signature(parsed, child),
                }),
            },
        );
    }
}

fn interface_entity(
    parsed: &ParsedTypeScriptFile,
    target: &SourceTarget,
    node: Node<'_>,
    parent: EntityId,
) -> Option<Entity> {
    let name = node_text(parsed, node.child_by_field_name("name")?);
    Some(Entity {
        name: qualified_name(target, &name),
        parent: Some(parent),
        language: Language::TypeScript,
        location: source_location_bytes(parsed, node.byte_range()),
        source_text: source_text(parsed, node),
        detail: EntityDetail::TypeScript(TypeScriptEntityDetail::Interface {
            members: interface_members(parsed, node),
        }),
    })
}

fn type_alias_entity(
    parsed: &ParsedTypeScriptFile,
    target: &SourceTarget,
    node: Node<'_>,
    parent: EntityId,
) -> Option<Entity> {
    let name = node_text(parsed, node.child_by_field_name("name")?);
    Some(Entity {
        name: qualified_name(target, &name),
        parent: Some(parent),
        language: Language::TypeScript,
        location: source_location_bytes(parsed, node.byte_range()),
        source_text: source_text(parsed, node),
        detail: EntityDetail::TypeScript(TypeScriptEntityDetail::TypeAlias {
            target: node
                .child_by_field_name("value")
                .map(|value| node_text(parsed, value))
                .unwrap_or_default(),
        }),
    })
}

fn enum_entity(
    parsed: &ParsedTypeScriptFile,
    target: &SourceTarget,
    node: Node<'_>,
    parent: EntityId,
) -> Option<Entity> {
    let name = node_text(parsed, node.child_by_field_name("name")?);
    Some(Entity {
        name: qualified_name(target, &name),
        parent: Some(parent),
        language: Language::TypeScript,
        location: source_location_bytes(parsed, node.byte_range()),
        source_text: source_text(parsed, node),
        detail: EntityDetail::TypeScript(TypeScriptEntityDetail::Enum {
            variants: enum_variants(parsed, node),
        }),
    })
}

fn collect_var_entities(
    parsed: &ParsedTypeScriptFile,
    target: &SourceTarget,
    declaration: Node<'_>,
    parent: EntityId,
    arena: &mut Arena<Entity>,
    entities: &mut Vec<EntityId>,
) {
    let mut cursor = declaration.walk();
    for child in declaration.children(&mut cursor) {
        if child.kind() != "variable_declarator" {
            continue;
        }
        let Some(name_node) = child.child_by_field_name("name") else {
            continue;
        };
        if name_node.kind() != "identifier" {
            continue;
        }
        let name = node_text(parsed, name_node);
        insert_entity(
            arena,
            entities,
            Entity {
                name: qualified_name(target, &name),
                parent: Some(parent),
                language: Language::TypeScript,
                location: source_location_bytes(parsed, child.byte_range()),
                source_text: source_text(parsed, child),
                detail: EntityDetail::TypeScript(TypeScriptEntityDetail::Var {
                    value: child
                        .child_by_field_name("value")
                        .map(|value| node_text(parsed, value))
                        .unwrap_or_default(),
                }),
            },
        );
    }
}

fn callable_signature(parsed: &ParsedTypeScriptFile, node: Node<'_>) -> String {
    let type_parameters = node
        .child_by_field_name("type_parameters")
        .map(|value| node_text(parsed, value))
        .unwrap_or_default();
    let parameters = node
        .child_by_field_name("parameters")
        .map(|value| node_text(parsed, value))
        .unwrap_or_else(|| "()".to_owned());
    let return_type = node
        .child_by_field_name("return_type")
        .map(|value| format!(" {}", node_text(parsed, value)))
        .unwrap_or_default();

    format!("{type_parameters}{parameters}{return_type}")
}

fn class_members(parsed: &ParsedTypeScriptFile, node: Node<'_>) -> Vec<String> {
    let Some(body) = node.child_by_field_name("body") else {
        return Vec::new();
    };
    named_member_texts(parsed, body)
}

fn interface_members(parsed: &ParsedTypeScriptFile, node: Node<'_>) -> Vec<String> {
    let Some(body) = node.child_by_field_name("body") else {
        return Vec::new();
    };
    named_member_texts(parsed, body)
}

fn named_member_texts(parsed: &ParsedTypeScriptFile, body: Node<'_>) -> Vec<String> {
    let mut members = Vec::new();
    let mut cursor = body.walk();
    for child in body.children(&mut cursor) {
        if !matches!(
            child.kind(),
            "method_definition"
                | "abstract_method_signature"
                | "method_signature"
                | "public_field_definition"
                | "property_signature"
        ) {
            continue;
        }
        if let Some(name) = child.child_by_field_name("name") {
            members.push(node_text(parsed, name));
        }
    }
    members
}

fn enum_variants(parsed: &ParsedTypeScriptFile, node: Node<'_>) -> Vec<String> {
    let Some(body) = node.child_by_field_name("body") else {
        return Vec::new();
    };
    let mut variants = Vec::new();
    collect_enum_variant_names(parsed, body, &mut variants);
    variants
}

fn collect_enum_variant_names(
    parsed: &ParsedTypeScriptFile,
    node: Node<'_>,
    variants: &mut Vec<String>,
) {
    if matches!(node.kind(), "identifier" | "property_identifier") {
        variants.push(node_text(parsed, node));
        return;
    }

    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        collect_enum_variant_names(parsed, child, variants);
    }
}

fn qualified_name(target: &SourceTarget, name: &str) -> String {
    format!("{}::{name}", target.root_name)
}

fn source_text(parsed: &ParsedTypeScriptFile, node: Node<'_>) -> String {
    parsed.source_text[node.byte_range()].to_owned()
}

fn node_text(parsed: &ParsedTypeScriptFile, node: Node<'_>) -> String {
    source_text(parsed, node).trim().to_owned()
}

fn source_location_bytes(parsed: &ParsedTypeScriptFile, range: Range<usize>) -> SourceLocation {
    debug_assert!(!parsed.repo_path.as_os_str().is_empty());
    source_location_from_offsets(
        parsed.file_path.clone(),
        parsed.snapshot_path.clone(),
        &parsed.line_starts,
        range.start,
        range.end,
    )
}
