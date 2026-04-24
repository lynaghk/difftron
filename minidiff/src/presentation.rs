use crate::{
    diff::{ChangeKind, ChangeSide, DiffResult, DisplayLine},
    inline::{InlineEmphasis, InlineSegment, InlineSegments},
};

#[derive(Debug, Clone, Copy, Eq, PartialEq, Default)]
pub struct PresentationOptions;

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct StructuredPresentation {
    pub rows: Vec<PresentationRow>,
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct PresentationRow {
    pub kind: PresentationChangeKind,
    pub left: Option<PresentationSide>,
    pub right: Option<PresentationSide>,
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct PresentationSide {
    pub line_number: usize,
    pub text: String,
    pub segments: Vec<PresentationSegment>,
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct PresentationSegment {
    pub text: String,
    pub kind: PresentationSegmentKind,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum PresentationChangeKind {
    Unchanged,
    NovelLeft,
    NovelRight,
    ReplacedCode,
    ReplacedComment,
    ReplacedString,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum PresentationSegmentKind {
    Context,
    Novel,
}

pub fn present_side_by_side(
    diff: &DiffResult,
    _options: &PresentationOptions,
) -> StructuredPresentation {
    StructuredPresentation {
        rows: diff
            .rows
            .iter()
            .map(|row| PresentationRow {
                kind: map_row_kind(&row.kind),
                left: row.left.as_ref().map(|line| {
                    present_side(
                        line,
                        ChangeSide::Left,
                        row.kind.changed_side(ChangeSide::Left),
                        row.inline.as_ref(),
                    )
                }),
                right: row.right.as_ref().map(|line| {
                    present_side(
                        line,
                        ChangeSide::Right,
                        row.kind.changed_side(ChangeSide::Right),
                        row.inline.as_ref(),
                    )
                }),
            })
            .collect(),
    }
}

fn present_side(
    line: &DisplayLine,
    side: ChangeSide,
    changed: bool,
    inline: Option<&InlineSegments>,
) -> PresentationSide {
    let segments = match inline {
        Some(inline) => inline_segments_to_presentation(inline, side),
        None => vec![PresentationSegment {
            text: line.text.clone(),
            kind: if changed {
                PresentationSegmentKind::Novel
            } else {
                PresentationSegmentKind::Context
            },
        }],
    };

    PresentationSide {
        line_number: line.line_number,
        text: line.text.clone(),
        segments,
    }
}

fn inline_segments_to_presentation(
    inline: &InlineSegments,
    side: ChangeSide,
) -> Vec<PresentationSegment> {
    let raw_segments = match side {
        ChangeSide::Left => &inline.left,
        ChangeSide::Right => &inline.right,
        ChangeSide::Both => &inline.left,
    };

    raw_segments.iter().map(map_inline_segment).collect()
}

fn map_inline_segment(segment: &InlineSegment) -> PresentationSegment {
    PresentationSegment {
        text: segment.text.clone(),
        kind: match segment.emphasis {
            InlineEmphasis::Context => PresentationSegmentKind::Context,
            InlineEmphasis::Novel => PresentationSegmentKind::Novel,
        },
    }
}

fn map_row_kind(kind: &ChangeKind) -> PresentationChangeKind {
    match kind {
        ChangeKind::Unchanged => PresentationChangeKind::Unchanged,
        ChangeKind::Novel(ChangeSide::Left) => PresentationChangeKind::NovelLeft,
        ChangeKind::Novel(ChangeSide::Right) => PresentationChangeKind::NovelRight,
        ChangeKind::Novel(ChangeSide::Both) => PresentationChangeKind::Unchanged,
        ChangeKind::ReplacedCode => PresentationChangeKind::ReplacedCode,
        ChangeKind::ReplacedComment => PresentationChangeKind::ReplacedComment,
        ChangeKind::ReplacedString => PresentationChangeKind::ReplacedString,
    }
}

trait PresentationChangeExt {
    fn changed_side(&self, side: ChangeSide) -> bool;
}

impl PresentationChangeExt for ChangeKind {
    fn changed_side(&self, side: ChangeSide) -> bool {
        match (self, side) {
            (ChangeKind::Unchanged, _) => false,
            (ChangeKind::Novel(ChangeSide::Left), ChangeSide::Left) => true,
            (ChangeKind::Novel(ChangeSide::Right), ChangeSide::Right) => true,
            (ChangeKind::Novel(ChangeSide::Both), _) => true,
            (ChangeKind::Novel(_), _) => false,
            (
                ChangeKind::ReplacedCode | ChangeKind::ReplacedComment | ChangeKind::ReplacedString,
                _,
            ) => true,
        }
    }
}
