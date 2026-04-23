use anyhow::Result;
use ra_ap_syntax::{AstNode, Edition, ast::SourceFile};
use tracing::info_span;

use crate::ir::{DisplayToken, classify_token};
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
    pub fn lines(&self) -> Vec<DisplayLine> {
        match self {
            ParsedDocument::SyntaxAware(doc) => doc.lines.clone(),
            ParsedDocument::FallbackText(doc) => doc.lines.clone(),
        }
    }
}

pub fn parse(language: Language, source: &str) -> Result<ParsedDocument> {
    let _span = info_span!(target: crate::logging::TARGET, "minidiff_parse", ?language).entered();

    match language {
        Language::Rust => parse_rust(source),
    }
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
