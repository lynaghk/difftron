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
pub enum ClojureEntityDetail {
    Namespace,
    Function { signature: String },
    Macro { signature: String },
    Multimethod { body: String },
    Method { signature: String },
    Var { value: String },
    Protocol { body: String },
    Record { fields: String },
    Type { fields: String },
}

#[derive(Debug)]
struct ParsedClojureFile {
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
        .unwrap_or_else(|| target.root_name.clone());

    let root_id = insert_entity(
        arena,
        entities,
        Entity {
            name: namespace.clone(),
            parent: None,
            language: Language::Clojure,
            location: source_location_bytes(&parsed, root.byte_range()),
            source_text: parsed.source_text.clone(),
            detail: EntityDetail::Clojure(ClojureEntityDetail::Namespace),
        },
    );

    for form in forms {
        if let Some(entity) = clojure_top_level_entity(&parsed, &namespace, form, root_id) {
            insert_entity(arena, entities, entity);
        }
    }

    Ok(())
}

pub fn render_entity(entity: &Entity, detail: &ClojureEntityDetail) -> String {
    let location = format_location(&entity.location);

    match detail {
        ClojureEntityDetail::Namespace => {
            format!("namespace {} @ {}", entity.name, location)
        }
        ClojureEntityDetail::Function { signature } => {
            format!("function {}{} @ {}", entity.name, signature, location)
        }
        ClojureEntityDetail::Macro { signature } => {
            format!("macro {}{} @ {}", entity.name, signature, location)
        }
        ClojureEntityDetail::Multimethod { body } => {
            format!("multimethod {} {} @ {}", entity.name, body, location)
        }
        ClojureEntityDetail::Method { signature } => {
            format!("method {}{} @ {}", entity.name, signature, location)
        }
        ClojureEntityDetail::Var { value } => {
            format!("var {} = {} @ {}", entity.name, value, location)
        }
        ClojureEntityDetail::Protocol { body } => {
            format!("protocol {} {} @ {}", entity.name, body, location)
        }
        ClojureEntityDetail::Record { fields } => {
            format!("record {} {} @ {}", entity.name, fields, location)
        }
        ClojureEntityDetail::Type { fields } => {
            format!("type {} {} @ {}", entity.name, fields, location)
        }
    }
}

pub fn entity_kind_name(detail: &ClojureEntityDetail) -> &'static str {
    match detail {
        ClojureEntityDetail::Namespace => "namespace",
        ClojureEntityDetail::Function { .. } => "function",
        ClojureEntityDetail::Macro { .. } => "macro",
        ClojureEntityDetail::Multimethod { .. } => "multimethod",
        ClojureEntityDetail::Method { .. } => "method",
        ClojureEntityDetail::Var { .. } => "var",
        ClojureEntityDetail::Protocol { .. } => "protocol",
        ClojureEntityDetail::Record { .. } => "record",
        ClojureEntityDetail::Type { .. } => "type",
    }
}

fn parse_clojure_file(
    repo: &dyn SourceRepo,
    snapshot_path: &std::path::Path,
) -> Result<ParsedClojureFile> {
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
        "defn" | "defn-" => ClojureEntityDetail::Function {
            signature: clojure_function_signature(source, &elements),
        },
        "defmacro" => ClojureEntityDetail::Macro {
            signature: clojure_function_signature(source, &elements),
        },
        "defmulti" => ClojureEntityDetail::Multimethod {
            body: clojure_form_tail(source, &elements, 2),
        },
        "defmethod" => ClojureEntityDetail::Method {
            signature: clojure_function_signature(source, &elements),
        },
        "def" | "defonce" => ClojureEntityDetail::Var {
            value: clojure_form_tail(source, &elements, 2),
        },
        "defprotocol" => ClojureEntityDetail::Protocol {
            body: clojure_form_tail(source, &elements, 2),
        },
        "defrecord" => ClojureEntityDetail::Record {
            fields: clojure_form_tail(source, &elements, 2),
        },
        "deftype" => ClojureEntityDetail::Type {
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
        detail: EntityDetail::Clojure(detail),
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

fn source_location_bytes(parsed: &ParsedClojureFile, range: Range<usize>) -> SourceLocation {
    debug_assert!(!parsed.repo_path.as_os_str().is_empty());
    source_location_from_offsets(
        parsed.file_path.clone(),
        parsed.snapshot_path.clone(),
        &parsed.line_starts,
        range.start,
        range.end,
    )
}
