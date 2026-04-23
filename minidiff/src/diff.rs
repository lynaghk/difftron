use anyhow::Result;
use tracing::info_span;

use crate::{
    Language,
    inline::InlineSegments,
    ir::{DisplayToken, TokenRole},
    lang::{ParsedDocument, parse},
};

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum ChangeSide {
    Left,
    Right,
    Both,
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub enum ChangeKind {
    Unchanged,
    Novel(ChangeSide),
    ReplacedCode,
    ReplacedComment,
    ReplacedString,
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct DisplayLine {
    pub line_number: usize,
    pub text: String,
    pub tokens: Vec<DisplayToken>,
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct DiffRow {
    pub kind: ChangeKind,
    pub left: Option<DisplayLine>,
    pub right: Option<DisplayLine>,
    pub inline: Option<InlineSegments>,
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct SyntaxDiff {
    pub matched_nodes: usize,
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct TextDiff {
    pub reason: String,
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub enum ParseOutcome {
    SyntaxAware(SyntaxDiff),
    FallbackText(TextDiff),
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct DiffResult {
    pub parse_outcome: ParseOutcome,
    pub rows: Vec<DiffRow>,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq, Default)]
pub enum DiffOptions {
    #[default]
    Default,
}

pub fn diff(language: Language, lhs: &str, rhs: &str, _options: DiffOptions) -> Result<DiffResult> {
    let _span = info_span!(target: crate::logging::TARGET, "minidiff_diff", ?language).entered();

    let lhs_doc = parse(language, lhs)?;
    let rhs_doc = parse(language, rhs)?;
    let rows = build_rows(&lhs_doc, &rhs_doc);
    let parse_outcome = match (&lhs_doc, &rhs_doc) {
        (ParsedDocument::SyntaxAware(lhs), ParsedDocument::SyntaxAware(rhs)) => {
            ParseOutcome::SyntaxAware(SyntaxDiff {
                matched_nodes: lhs.matched_node_budget.min(rhs.matched_node_budget).max(1),
            })
        }
        (ParsedDocument::FallbackText(lhs), ParsedDocument::FallbackText(rhs)) => {
            ParseOutcome::FallbackText(TextDiff {
                reason: format!(
                    "parse fallback on both sides: {}; {}",
                    lhs.reason, rhs.reason
                ),
            })
        }
        (ParsedDocument::FallbackText(lhs), _) | (_, ParsedDocument::FallbackText(lhs)) => {
            ParseOutcome::FallbackText(TextDiff {
                reason: format!("parse fallback: {}", lhs.reason),
            })
        }
    };

    Ok(DiffResult {
        parse_outcome,
        rows,
    })
}

fn build_rows(lhs: &ParsedDocument, rhs: &ParsedDocument) -> Vec<DiffRow> {
    let lhs_lines = lhs.lines();
    let rhs_lines = rhs.lines();
    let matches = lcs_matches(&lhs_lines, &rhs_lines);

    let mut rows = Vec::new();
    let mut lhs_index = 0;
    let mut rhs_index = 0;

    for (matched_lhs, matched_rhs) in matches {
        flush_changed_block(
            &lhs_lines[lhs_index..matched_lhs],
            &rhs_lines[rhs_index..matched_rhs],
            &mut rows,
        );
        rows.push(DiffRow {
            kind: ChangeKind::Unchanged,
            left: Some(lhs_lines[matched_lhs].clone()),
            right: Some(rhs_lines[matched_rhs].clone()),
            inline: None,
        });
        lhs_index = matched_lhs + 1;
        rhs_index = matched_rhs + 1;
    }

    flush_changed_block(&lhs_lines[lhs_index..], &rhs_lines[rhs_index..], &mut rows);
    rows
}

fn flush_changed_block(lhs: &[DisplayLine], rhs: &[DisplayLine], rows: &mut Vec<DiffRow>) {
    let paired = lhs.len().min(rhs.len());
    for index in 0..paired {
        let left = lhs[index].clone();
        let right = rhs[index].clone();
        let kind = classify_replacement(&left, &right);
        let inline = matches!(
            kind,
            ChangeKind::ReplacedCode | ChangeKind::ReplacedComment | ChangeKind::ReplacedString
        )
        .then(|| crate::inline::emphasize(&left.text, &right.text));
        rows.push(DiffRow {
            kind,
            left: Some(left),
            right: Some(right),
            inline,
        });
    }

    for line in &lhs[paired..] {
        rows.push(DiffRow {
            kind: ChangeKind::Novel(ChangeSide::Left),
            left: Some(line.clone()),
            right: None,
            inline: None,
        });
    }
    for line in &rhs[paired..] {
        rows.push(DiffRow {
            kind: ChangeKind::Novel(ChangeSide::Right),
            left: None,
            right: Some(line.clone()),
            inline: None,
        });
    }
}

fn classify_replacement(left: &DisplayLine, right: &DisplayLine) -> ChangeKind {
    let left_roles = line_roles(left);
    let right_roles = line_roles(right);
    if left_roles.contains(&TokenRole::Comment) || right_roles.contains(&TokenRole::Comment) {
        ChangeKind::ReplacedComment
    } else if left_roles.contains(&TokenRole::StringLiteral)
        || right_roles.contains(&TokenRole::StringLiteral)
    {
        ChangeKind::ReplacedString
    } else {
        ChangeKind::ReplacedCode
    }
}

fn line_roles(line: &DisplayLine) -> Vec<TokenRole> {
    line.tokens.iter().map(|token| token.role).collect()
}

fn lcs_matches(lhs: &[DisplayLine], rhs: &[DisplayLine]) -> Vec<(usize, usize)> {
    let mut dp = vec![vec![0usize; rhs.len() + 1]; lhs.len() + 1];
    for lhs_index in (0..lhs.len()).rev() {
        for rhs_index in (0..rhs.len()).rev() {
            dp[lhs_index][rhs_index] = if lhs[lhs_index].text == rhs[rhs_index].text {
                dp[lhs_index + 1][rhs_index + 1] + 1
            } else {
                dp[lhs_index + 1][rhs_index].max(dp[lhs_index][rhs_index + 1])
            };
        }
    }

    let mut matches = Vec::new();
    let mut lhs_index = 0;
    let mut rhs_index = 0;
    while lhs_index < lhs.len() && rhs_index < rhs.len() {
        if lhs[lhs_index].text == rhs[rhs_index].text {
            matches.push((lhs_index, rhs_index));
            lhs_index += 1;
            rhs_index += 1;
        } else if dp[lhs_index + 1][rhs_index] >= dp[lhs_index][rhs_index + 1] {
            lhs_index += 1;
        } else {
            rhs_index += 1;
        }
    }
    matches
}
