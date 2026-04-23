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

pub fn emphasize(lhs: &str, rhs: &str) -> InlineSegments {
    let lhs_tokens = tokenize(lhs);
    let rhs_tokens = tokenize(rhs);
    let matches = lcs_matches(&lhs_tokens, &rhs_tokens);

    InlineSegments {
        left: build_segments(&lhs_tokens, &matches, Side::Left),
        right: build_segments(&rhs_tokens, &matches, Side::Right),
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

fn lcs_matches(lhs: &[String], rhs: &[String]) -> Vec<(usize, usize)> {
    let mut dp = vec![vec![0usize; rhs.len() + 1]; lhs.len() + 1];
    for lhs_index in (0..lhs.len()).rev() {
        for rhs_index in (0..rhs.len()).rev() {
            dp[lhs_index][rhs_index] = if lhs[lhs_index] == rhs[rhs_index] {
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
        if lhs[lhs_index] == rhs[rhs_index] {
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

fn build_segments(tokens: &[String], matches: &[(usize, usize)], side: Side) -> Vec<InlineSegment> {
    let matched_indices = matches
        .iter()
        .map(|(left, right)| match side {
            Side::Left => *left,
            Side::Right => *right,
        })
        .collect::<std::collections::BTreeSet<_>>();

    let mut segments = Vec::new();
    let mut current_text = String::new();
    let mut current_emphasis = None;

    for (index, token) in tokens.iter().enumerate() {
        let emphasis = if matched_indices.contains(&index) {
            InlineEmphasis::Context
        } else {
            InlineEmphasis::Novel
        };

        if current_emphasis == Some(emphasis) {
            current_text.push_str(token);
        } else {
            if let Some(previous) = current_emphasis {
                segments.push(InlineSegment {
                    text: std::mem::take(&mut current_text),
                    emphasis: previous,
                });
            }
            current_text.push_str(token);
            current_emphasis = Some(emphasis);
        }
    }

    if let Some(emphasis) = current_emphasis {
        segments.push(InlineSegment {
            text: current_text,
            emphasis,
        });
    }

    segments
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
enum TokenKind {
    Word,
    Whitespace,
    Punctuation,
}
