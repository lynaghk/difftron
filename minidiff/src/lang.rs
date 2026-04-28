use anyhow::Result;
use ra_ap_syntax::{AstNode, Edition, ast::SourceFile};
use tree_sitter_patched_arborium::{Language as TreeSitterLanguage, Node, Parser};
use tracing::info_span;

use crate::ir::{DisplayToken, TokenRole, classify_token};
use crate::{Language, diff::DisplayLine};

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct SyntaxDocument {
    pub lines: Vec<DisplayLine>,
    pub matched_node_budget: usize,
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

pub fn parse(language: Language, source: &str) -> Result<ParsedDocument> {
    let _span = info_span!(target: crate::logging::TARGET, "minidiff_parse", ?language).entered();

    match language {
        Language::Clojure => parse_clojure(source),
        Language::Rust => parse_rust(source),
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

    Ok(ParsedDocument::SyntaxAware(SyntaxDocument {
        lines: enrich_with_clojure_tokens(source, root),
        matched_node_budget: count_nodes(root),
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

fn enrich_with_clojure_tokens(source: &str, root: Node<'_>) -> Vec<DisplayLine> {
    let mut lines = build_lines(source);
    collect_clojure_tokens(source, root, &mut lines);
    lines
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

fn count_nodes(root: Node<'_>) -> usize {
    let mut count = 1;
    let mut cursor = root.walk();
    for child in root.children(&mut cursor) {
        count += count_nodes(child);
    }
    count
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
