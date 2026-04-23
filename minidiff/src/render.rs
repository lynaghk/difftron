use anyhow::Result;
use tracing::info_span;

use crate::{
    diff::{ChangeKind, ChangeSide, DiffResult, DisplayLine},
    inline::InlineSegments,
};

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum OutputStyle {
    Ansi,
    Plain,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum Wrapping {
    Wrap,
    NoWrap,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub struct RenderOptions {
    pub output_style: OutputStyle,
    pub wrapping: Wrapping,
    pub column_width: usize,
}

pub fn render_side_by_side(diff: &DiffResult, options: &RenderOptions) -> Result<String> {
    let _span =
        info_span!(target: crate::logging::TARGET, "minidiff_render", rows = diff.rows.len())
            .entered();

    let mut rendered = String::new();
    for row in &diff.rows {
        let left = render_side(
            row.left.as_ref(),
            &row.kind,
            ChangeSide::Left,
            row.inline.as_ref(),
            options,
        );
        let right = render_side(
            row.right.as_ref(),
            &row.kind,
            ChangeSide::Right,
            row.inline.as_ref(),
            options,
        );
        rendered.push_str(&format!(
            "{:<width$} | {}\n",
            left,
            right,
            width = options.column_width
        ));
    }
    Ok(rendered)
}

fn render_side(
    line: Option<&DisplayLine>,
    kind: &ChangeKind,
    side: ChangeSide,
    inline: Option<&InlineSegments>,
    options: &RenderOptions,
) -> String {
    let raw = match line {
        Some(line) => {
            let prefix = format!("{}{} ", side_prefix(side), line.line_number);
            let content = style_content(&line.text, kind, side, inline, options);
            format!("{prefix}{content}")
        }
        None => format!("{}  ", side_prefix(side)),
    };

    match options.wrapping {
        Wrapping::Wrap => raw.chars().take(options.column_width).collect(),
        Wrapping::NoWrap => raw,
    }
}

fn side_prefix(side: ChangeSide) -> &'static str {
    match side {
        ChangeSide::Left => "L",
        ChangeSide::Right => "R",
        ChangeSide::Both => "B",
    }
}

fn style_content(
    text: &str,
    kind: &ChangeKind,
    side: ChangeSide,
    inline: Option<&InlineSegments>,
    options: &RenderOptions,
) -> String {
    match options.output_style {
        OutputStyle::Plain => text.to_owned(),
        OutputStyle::Ansi => {
            let color = match (kind, side) {
                (ChangeKind::Novel(ChangeSide::Left), ChangeSide::Left) => "\u{1b}[31m",
                (ChangeKind::Novel(ChangeSide::Right), ChangeSide::Right) => "\u{1b}[32m",
                (ChangeKind::ReplacedCode, ChangeSide::Left)
                | (ChangeKind::ReplacedComment, ChangeSide::Left)
                | (ChangeKind::ReplacedString, ChangeSide::Left) => "\u{1b}[31m",
                (ChangeKind::ReplacedCode, ChangeSide::Right)
                | (ChangeKind::ReplacedComment, ChangeSide::Right)
                | (ChangeKind::ReplacedString, ChangeSide::Right) => "\u{1b}[32m",
                _ => "\u{1b}[0m",
            };
            let _ = inline;
            format!("{color}{text}\u{1b}[0m")
        }
    }
}
