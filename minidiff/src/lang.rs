use std::{
    collections::{BTreeMap, hash_map::DefaultHasher},
    hash::{Hash, Hasher},
    ops::Range,
};

use anyhow::Result;
use ra_ap_syntax::{AstNode, Edition, ast::SourceFile};
use tracing::info_span;
use tree_sitter_patched_arborium::{Language as TreeSitterLanguage, Node, Parser};

use crate::ir::{DisplayToken, TokenRole, classify_token};
use crate::{Language, diff::DisplayLine};

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct SyntaxDocument {
    pub lines: Vec<DisplayLine>,
    pub matched_node_budget: usize,
    clojure_form: Option<ClojureForm>,
}

impl SyntaxDocument {
    pub fn structural_match_budget(&self, rhs: &Self) -> Option<usize> {
        let lhs = self.clojure_form.as_ref()?;
        let rhs = rhs.clojure_form.as_ref()?;
        Some(
            unique_clojure_hash_matches(lhs, rhs)
                .into_iter()
                .map(|matched| matched.subtree_size)
                .sum::<usize>()
                .max(1),
        )
    }
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct FallbackDocument {
    pub lines: Vec<DisplayLine>,
    pub reason: String,
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub enum ParsedDocument {
    SyntaxAware(SyntaxDocument),
    FallbackText(FallbackDocument),
}

impl ParsedDocument {
    pub fn lines(&self) -> &[DisplayLine] {
        match self {
            ParsedDocument::SyntaxAware(doc) => &doc.lines,
            ParsedDocument::FallbackText(doc) => &doc.lines,
        }
    }
}

#[derive(Debug, Clone, Copy, Eq, PartialEq, Hash)]
enum ClojureFormKind {
    Root,
    List,
    Vector,
    Map,
    Set,
    Atom,
}

#[derive(Debug, Clone, Eq, PartialEq)]
struct ClojureForm {
    kind: ClojureFormKind,
    byte_range: Range<usize>,
    line_range: Range<usize>,
    normalized_hash: u64,
    subtree_size: usize,
    children: Vec<ClojureForm>,
}

#[derive(Debug, Clone, Eq, PartialEq)]
struct ClojureFormMatch {
    lhs_byte_range: Range<usize>,
    rhs_byte_range: Range<usize>,
    subtree_size: usize,
}

impl ClojureForm {
    fn matched_node_budget(&self) -> usize {
        debug_assert!(self.byte_range.start <= self.byte_range.end);
        debug_assert!(self.line_range.start <= self.line_range.end);
        debug_assert!(self.normalized_hash > 0 || self.subtree_size == 0);
        let _kind = self.kind;

        self.subtree_size
    }
}

fn unique_clojure_hash_matches(lhs: &ClojureForm, rhs: &ClojureForm) -> Vec<ClojureFormMatch> {
    let mut lhs_forms = BTreeMap::new();
    let mut rhs_forms = BTreeMap::new();
    collect_forms_by_hash(lhs, &mut lhs_forms);
    collect_forms_by_hash(rhs, &mut rhs_forms);

    let mut matches = Vec::new();
    for (hash, lhs_candidates) in lhs_forms {
        let Some(rhs_candidates) = rhs_forms.get(&hash) else {
            continue;
        };
        if lhs_candidates.len() == 1 && rhs_candidates.len() == 1 {
            let lhs = lhs_candidates[0];
            let rhs = rhs_candidates[0];
            matches.push(ClojureFormMatch {
                lhs_byte_range: lhs.byte_range.clone(),
                rhs_byte_range: rhs.byte_range.clone(),
                subtree_size: lhs.subtree_size.min(rhs.subtree_size),
            });
        }
    }

    matches.sort_by(|lhs, rhs| {
        lhs.lhs_byte_range
            .start
            .cmp(&rhs.lhs_byte_range.start)
            .then_with(|| lhs.rhs_byte_range.start.cmp(&rhs.rhs_byte_range.start))
    });
    matches
}

fn collect_forms_by_hash<'a>(
    form: &'a ClojureForm,
    forms: &mut BTreeMap<u64, Vec<&'a ClojureForm>>,
) {
    if form.kind != ClojureFormKind::Root {
        forms.entry(form.normalized_hash).or_default().push(form);
    }

    for child in &form.children {
        collect_forms_by_hash(child, forms);
    }
}

pub fn parse(language: Language, source: &str) -> Result<ParsedDocument> {
    let _span = info_span!(target: crate::logging::TARGET, "minidiff_parse", ?language).entered();

    match language {
        Language::Clojure => parse_clojure(source),
        Language::Rust => parse_rust(source),
        Language::TypeScript => parse_typescript(source),
    }
}

fn parse_clojure(source: &str) -> Result<ParsedDocument> {
    let mut parser = Parser::new();
    let language = TreeSitterLanguage::from(arborium_clojure::language());
    parser.set_language(&language)?;
    let lines = build_lines(source);
    let Some(tree) = parser.parse(source, None) else {
        return Ok(ParsedDocument::FallbackText(FallbackDocument {
            lines,
            reason: "parser returned no tree".to_owned(),
        }));
    };

    let root = tree.root_node();
    if root.has_error() {
        return Ok(ParsedDocument::FallbackText(FallbackDocument {
            lines,
            reason: "parse errors".to_owned(),
        }));
    }

    let form = build_clojure_form(source, root);
    Ok(ParsedDocument::SyntaxAware(SyntaxDocument {
        lines: enrich_with_clojure_tokens(source, root),
        matched_node_budget: form.matched_node_budget(),
        clojure_form: Some(form),
    }))
}

fn parse_rust(source: &str) -> Result<ParsedDocument> {
    let parse = SourceFile::parse(source, Edition::CURRENT);
    let lines = build_lines(source);
    let errors = parse.errors();
    if !errors.is_empty() {
        return Ok(ParsedDocument::FallbackText(FallbackDocument {
            lines,
            reason: format!("parse errors: {}", errors.len()),
        }));
    }

    let tree = parse.tree();
    let matched_node_budget = tree.syntax().descendants().count();
    Ok(ParsedDocument::SyntaxAware(SyntaxDocument {
        lines: enrich_with_tokens(source, &tree),
        matched_node_budget,
        clojure_form: None,
    }))
}

fn parse_typescript(source: &str) -> Result<ParsedDocument> {
    let mut parser = Parser::new();
    let language = TreeSitterLanguage::from(arborium_typescript::language());
    parser.set_language(&language)?;
    let lines = build_lines(source);
    let Some(tree) = parser.parse(source, None) else {
        return Ok(ParsedDocument::FallbackText(FallbackDocument {
            lines,
            reason: "parser returned no tree".to_owned(),
        }));
    };

    let root = tree.root_node();
    if root.has_error() {
        return Ok(ParsedDocument::FallbackText(FallbackDocument {
            lines,
            reason: "parse errors".to_owned(),
        }));
    }

    Ok(ParsedDocument::SyntaxAware(SyntaxDocument {
        lines: enrich_with_typescript_tokens(source, root),
        matched_node_budget: count_tree_sitter_nodes(root),
        clojure_form: None,
    }))
}

fn enrich_with_tokens(source: &str, tree: &SourceFile) -> Vec<DisplayLine> {
    let mut lines = build_lines(source);
    for token in tree
        .syntax()
        .descendants_with_tokens()
        .filter_map(|element| element.into_token())
    {
        let text = token.text().to_string();
        let role = classify_token(token.kind(), &text);
        let start_offset = usize::from(token.text_range().start());
        let line_index = source[..start_offset]
            .bytes()
            .filter(|byte| *byte == b'\n')
            .count();
        if let Some(line) = lines.get_mut(line_index) {
            line.tokens.push(DisplayToken { text, role });
        }
    }
    lines
}

fn enrich_with_typescript_tokens(source: &str, root: Node<'_>) -> Vec<DisplayLine> {
    let mut lines = build_lines(source);
    collect_typescript_tokens(source, root, &mut lines);
    lines
}

fn enrich_with_clojure_tokens(source: &str, root: Node<'_>) -> Vec<DisplayLine> {
    let mut lines = build_lines(source);
    collect_clojure_tokens(source, root, &mut lines);
    lines
}

fn count_tree_sitter_nodes(node: Node<'_>) -> usize {
    let mut count = 1;
    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        count += count_tree_sitter_nodes(child);
    }
    count
}

fn collect_clojure_tokens(source: &str, node: Node<'_>, lines: &mut [DisplayLine]) {
    if node.child_count() == 0 {
        let text = source[node.byte_range()].to_owned();
        if text.is_empty() {
            return;
        }

        let line_index = source[..node.start_byte()]
            .bytes()
            .filter(|byte| *byte == b'\n')
            .count();
        if let Some(line) = lines.get_mut(line_index) {
            line.tokens.push(DisplayToken {
                role: classify_clojure_token(node.kind(), &text),
                text,
            });
        }
        return;
    }

    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        collect_clojure_tokens(source, child, lines);
    }
}

fn classify_clojure_token(kind: &str, text: &str) -> TokenRole {
    match kind {
        "comment" => TokenRole::Comment,
        "str_lit" | "char_lit" => TokenRole::StringLiteral,
        "num_lit" => TokenRole::Number,
        "kwd_lit" => TokenRole::Keyword,
        "sym_lit" => TokenRole::Identifier,
        _ if text.chars().all(char::is_whitespace) => TokenRole::TriviaLike,
        _ if matches!(text, "(" | ")" | "[" | "]" | "{" | "}") => TokenRole::Delimiter,
        _ if matches!(text, "'" | "`" | "~" | "@" | "~@") => TokenRole::Operator,
        _ => TokenRole::Other,
    }
}

fn collect_typescript_tokens(source: &str, node: Node<'_>, lines: &mut [DisplayLine]) {
    if node.child_count() == 0 {
        let text = source[node.byte_range()].to_owned();
        if text.is_empty() {
            return;
        }

        let line_index = source[..node.start_byte()]
            .bytes()
            .filter(|byte| *byte == b'\n')
            .count();
        if let Some(line) = lines.get_mut(line_index) {
            line.tokens.push(DisplayToken {
                role: classify_typescript_token(node.kind(), &text),
                text,
            });
        }
        return;
    }

    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        collect_typescript_tokens(source, child, lines);
    }
}

fn classify_typescript_token(kind: &str, text: &str) -> TokenRole {
    match kind {
        "comment" => TokenRole::Comment,
        "string" | "template_string" | "regex" => TokenRole::StringLiteral,
        "number" => TokenRole::Number,
        "identifier" | "property_identifier" | "shorthand_property_identifier" => {
            TokenRole::Identifier
        }
        "type_identifier" | "predefined_type" => TokenRole::Type,
        _ if text.chars().all(char::is_whitespace) => TokenRole::TriviaLike,
        _ if matches!(text, "{" | "}" | "(" | ")" | "[" | "]") => TokenRole::Delimiter,
        _ if is_typescript_keyword(text) => TokenRole::Keyword,
        _ if is_typescript_operator(text) => TokenRole::Operator,
        _ => TokenRole::Other,
    }
}

fn is_typescript_keyword(text: &str) -> bool {
    matches!(
        text,
        "abstract"
            | "as"
            | "async"
            | "await"
            | "class"
            | "const"
            | "declare"
            | "else"
            | "enum"
            | "export"
            | "extends"
            | "false"
            | "for"
            | "from"
            | "function"
            | "if"
            | "implements"
            | "import"
            | "interface"
            | "let"
            | "new"
            | "null"
            | "private"
            | "protected"
            | "public"
            | "return"
            | "static"
            | "super"
            | "this"
            | "true"
            | "type"
            | "undefined"
            | "var"
            | "void"
            | "while"
            | "yield"
    )
}

fn is_typescript_operator(text: &str) -> bool {
    matches!(
        text,
        "=" | "=>"
            | "=="
            | "==="
            | "!="
            | "!=="
            | "+"
            | "-"
            | "*"
            | "/"
            | "%"
            | "!"
            | "?"
            | ":"
            | "."
            | ","
            | ";"
            | "<"
            | ">"
            | "<="
            | ">="
            | "&&"
            | "||"
            | "??"
            | "|"
            | "&"
    )
}

fn build_clojure_form(source: &str, node: Node<'_>) -> ClojureForm {
    let byte_range = node.byte_range();
    let start_position = node.start_position();
    let end_position = node.end_position();
    let kind = clojure_form_kind(source, node);
    let children = structural_clojure_children(source, node);
    let subtree_size = 1 + children
        .iter()
        .map(|child| child.subtree_size)
        .sum::<usize>();
    let normalized_hash = clojure_form_hash(source, kind, byte_range.clone(), &children);

    ClojureForm {
        kind,
        byte_range,
        line_range: start_position.row + 1..end_position.row + 2,
        normalized_hash,
        subtree_size,
        children,
    }
}

fn structural_clojure_children(source: &str, node: Node<'_>) -> Vec<ClojureForm> {
    let mut children = Vec::new();
    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        let text = &source[child.byte_range()];
        if text.chars().all(char::is_whitespace) || is_clojure_delimiter(text) {
            continue;
        }
        children.push(build_clojure_form(source, child));
    }
    children
}

fn clojure_form_kind(source: &str, node: Node<'_>) -> ClojureFormKind {
    if node.kind() == "source" {
        return ClojureFormKind::Root;
    }

    let text = source[node.byte_range()].trim_start();
    if text.starts_with("#{") {
        ClojureFormKind::Set
    } else if text.starts_with('(') {
        ClojureFormKind::List
    } else if text.starts_with('[') {
        ClojureFormKind::Vector
    } else if text.starts_with('{') {
        ClojureFormKind::Map
    } else {
        ClojureFormKind::Atom
    }
}

fn clojure_form_hash(
    source: &str,
    kind: ClojureFormKind,
    byte_range: Range<usize>,
    children: &[ClojureForm],
) -> u64 {
    let mut hasher = DefaultHasher::new();
    kind.hash(&mut hasher);
    if children.is_empty() {
        source[byte_range].trim().hash(&mut hasher);
    } else {
        for child in children {
            child.normalized_hash.hash(&mut hasher);
        }
    }
    hasher.finish()
}

fn is_clojure_delimiter(text: &str) -> bool {
    matches!(text, "(" | ")" | "[" | "]" | "{" | "}" | "#{")
}

fn build_lines(source: &str) -> Vec<DisplayLine> {
    let mut lines = Vec::new();
    for (index, line) in source.lines().enumerate() {
        lines.push(DisplayLine {
            line_number: index + 1,
            text: line.to_owned(),
            tokens: Vec::new(),
        });
    }

    if source.ends_with('\n') && source.lines().next().is_none() {
        lines.push(DisplayLine {
            line_number: 1,
            text: String::new(),
            tokens: Vec::new(),
        });
    }

    lines
}

#[cfg(test)]
mod tests {
    use super::*;

    fn clojure_form(source: &str) -> ClojureForm {
        let mut parser = Parser::new();
        let language = TreeSitterLanguage::from(arborium_clojure::language());
        parser.set_language(&language).unwrap();
        let tree = parser.parse(source, None).unwrap();
        assert!(!tree.root_node().has_error());
        build_clojure_form(source, tree.root_node())
    }

    #[test]
    fn clojure_form_ir_records_collection_shapes() {
        let form = clojure_form("(defn meaning [] {:answer 42})\n");

        assert_eq!(form.kind, ClojureFormKind::Root);
        assert_eq!(form.children.len(), 1);
        let list = &form.children[0];
        assert_eq!(list.kind, ClojureFormKind::List);
        assert_eq!(list.line_range, 1..2);
        assert_eq!(
            list.children
                .iter()
                .map(|child| child.kind)
                .collect::<Vec<_>>(),
            vec![
                ClojureFormKind::Atom,
                ClojureFormKind::Atom,
                ClojureFormKind::Vector,
                ClojureFormKind::Map,
            ]
        );
    }

    #[test]
    fn clojure_form_hash_ignores_layout_between_forms() {
        let compact = clojure_form("(defn meaning [] {:answer 42})\n");
        let expanded = clojure_form("(defn meaning\n  []\n  {:answer 42})\n");

        assert_eq!(compact.normalized_hash, expanded.normalized_hash);
    }

    #[test]
    fn clojure_hash_matching_finds_unique_identical_subtrees() {
        let lhs = clojure_form("(defn render [user] {:id (:id user) :name (:name user)})\n");
        let rhs =
            clojure_form("(defn render [user] {:profile {:name (:name user)} :id (:id user)})\n");

        let matches = unique_clojure_hash_matches(&lhs, &rhs);

        assert!(matches.iter().any(|matched| matched.subtree_size > 1));
        assert!(matches.iter().any(|matched| {
            matched.lhs_byte_range == (25..35) && matched.rhs_byte_range == (55..65)
        }));
        assert!(matches.iter().any(|matched| {
            matched.lhs_byte_range == (42..54) && matched.rhs_byte_range == (37..49)
        }));
    }
}
