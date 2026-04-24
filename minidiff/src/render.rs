use anyhow::Result;
use tracing::info_span;

use crate::presentation::{
    PresentationSegment, PresentationSegmentKind, PresentationSide, StructuredPresentation,
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

pub fn render_side_by_side(
    presentation: &StructuredPresentation,
    options: &RenderOptions,
) -> Result<String> {
    let _span =
        info_span!(target: crate::logging::TARGET, "minidiff_render", rows = presentation.rows.len())
            .entered();

    let mut rendered = String::new();
    for row in &presentation.rows {
        let left = render_side(row.left.as_ref(), true, options);
        let right = render_side(row.right.as_ref(), false, options);
        rendered.push_str(&pad_visible_width(&left, options.column_width));
        rendered.push_str(" | ");
        rendered.push_str(&right);
        rendered.push('\n');
    }
    Ok(rendered)
}

fn render_side(side: Option<&PresentationSide>, is_left: bool, options: &RenderOptions) -> String {
    match side {
        Some(side) => render_segments(&side.segments, is_left, options),
        None => String::new(),
    }
}

fn render_segments(
    segments: &[PresentationSegment],
    is_left: bool,
    options: &RenderOptions,
) -> String {
    let mut rendered = String::new();
    let mut remaining = options.column_width;

    for segment in segments {
        if remaining == 0 && matches!(options.wrapping, Wrapping::Wrap) {
            break;
        }

        let text = truncate_segment(&segment.text, &mut remaining, options.wrapping);
        if text.is_empty() {
            continue;
        }

        match options.output_style {
            OutputStyle::Plain => rendered.push_str(&text),
            OutputStyle::Ansi => match segment.kind {
                PresentationSegmentKind::Context => rendered.push_str(&text),
                PresentationSegmentKind::Novel => {
                    rendered.push_str(if is_left { "\u{1b}[31m" } else { "\u{1b}[32m" });
                    rendered.push_str(&text);
                    rendered.push_str("\u{1b}[0m");
                }
            },
        }
    }
    rendered
}

fn truncate_segment(text: &str, remaining: &mut usize, wrapping: Wrapping) -> String {
    match wrapping {
        Wrapping::NoWrap => text.to_owned(),
        Wrapping::Wrap => {
            let taken: String = text.chars().take(*remaining).collect();
            *remaining = remaining.saturating_sub(taken.chars().count());
            taken
        }
    }
}

fn pad_visible_width(text: &str, width: usize) -> String {
    let visible_width = visible_width(text);
    let padding = width.saturating_sub(visible_width);
    format!("{text}{}", " ".repeat(padding))
}

fn visible_width(text: &str) -> usize {
    let mut width = 0;
    let mut chars = text.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '\u{1b}' && chars.peek() == Some(&'[') {
            chars.next();
            for next in chars.by_ref() {
                if next.is_ascii_alphabetic() {
                    break;
                }
            }
        } else {
            width += 1;
        }
    }
    width
}
