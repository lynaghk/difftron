#[derive(Debug, Clone, Eq, PartialEq)]
pub struct InlineSegment {
    pub text: String,
    pub emphasis: InlineEmphasis,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum InlineEmphasis {
    Context,
    Novel,
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct InlineSegments {
    pub left: Vec<InlineSegment>,
    pub right: Vec<InlineSegment>,
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct BlockInlineSegments {
    pub left: Vec<Vec<InlineSegment>>,
    pub right: Vec<Vec<InlineSegment>>,
}

pub fn emphasize_block(lhs: &[&str], rhs: &[&str]) -> BlockInlineSegments {
    let lhs_tokens = tokenize_lines(lhs);
    let rhs_tokens = tokenize_lines(rhs);
    let matches = lcs_line_token_matches(&lhs_tokens, &rhs_tokens);

    BlockInlineSegments {
        left: build_line_segments(&lhs_tokens, lhs.len(), &matches, Side::Left),
        right: build_line_segments(&rhs_tokens, rhs.len(), &matches, Side::Right),
    }
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
enum Side {
    Left,
    Right,
}

fn tokenize(text: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut current = String::new();
    let mut current_kind = None;

    for ch in text.chars() {
        let kind = if ch.is_whitespace() {
            TokenKind::Whitespace
        } else if ch.is_alphanumeric() || ch == '_' {
            TokenKind::Word
        } else {
            TokenKind::Punctuation
        };

        if current_kind == Some(kind) && kind != TokenKind::Punctuation {
            current.push(ch);
        } else {
            if !current.is_empty() {
                tokens.push(std::mem::take(&mut current));
            }
            current.push(ch);
            current_kind = Some(kind);
            if kind == TokenKind::Punctuation {
                tokens.push(std::mem::take(&mut current));
                current_kind = None;
            }
        }
    }

    if !current.is_empty() {
        tokens.push(current);
    }

    tokens
}

#[derive(Debug, Clone, Eq, PartialEq)]
struct LineToken {
    text: String,
    line: usize,
}

fn tokenize_lines(lines: &[&str]) -> Vec<LineToken> {
    lines
        .iter()
        .enumerate()
        .flat_map(|(line, text)| {
            tokenize(text)
                .into_iter()
                .map(move |token| LineToken { text: token, line })
        })
        .collect()
}

fn lcs_line_token_matches(lhs: &[LineToken], rhs: &[LineToken]) -> Vec<(usize, usize)> {
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

fn build_line_segments(
    tokens: &[LineToken],
    line_count: usize,
    matches: &[(usize, usize)],
    side: Side,
) -> Vec<Vec<InlineSegment>> {
    let matched_indices = matches
        .iter()
        .map(|(left, right)| match side {
            Side::Left => *left,
            Side::Right => *right,
        })
        .collect::<std::collections::BTreeSet<_>>();

    let mut lines = vec![Vec::new(); line_count];
    for (index, token) in tokens.iter().enumerate() {
        let emphasis = if matched_indices.contains(&index) {
            InlineEmphasis::Context
        } else {
            InlineEmphasis::Novel
        };
        push_segment(&mut lines[token.line], &token.text, emphasis);
    }
    lines
}

fn push_segment(segments: &mut Vec<InlineSegment>, text: &str, emphasis: InlineEmphasis) {
    if let Some(segment) = segments
        .last_mut()
        .filter(|segment| segment.emphasis == emphasis)
    {
        segment.text.push_str(text);
    } else {
        segments.push(InlineSegment {
            text: text.to_owned(),
            emphasis,
        });
    }
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
enum TokenKind {
    Word,
    Whitespace,
    Punctuation,
}
