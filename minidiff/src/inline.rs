#[derive(Debug, Clone, Eq, PartialEq)]
pub struct InlineSegments {
    pub common_prefix_len: usize,
    pub common_suffix_len: usize,
}

pub fn emphasize(lhs: &str, rhs: &str) -> InlineSegments {
    let prefix = lhs
        .chars()
        .zip(rhs.chars())
        .take_while(|(left, right)| left == right)
        .count();

    let lhs_remaining = lhs.chars().count().saturating_sub(prefix);
    let rhs_remaining = rhs.chars().count().saturating_sub(prefix);
    let suffix = lhs
        .chars()
        .rev()
        .zip(rhs.chars().rev())
        .take(lhs_remaining.min(rhs_remaining))
        .take_while(|(left, right)| left == right)
        .count();

    InlineSegments {
        common_prefix_len: prefix,
        common_suffix_len: suffix,
    }
}
