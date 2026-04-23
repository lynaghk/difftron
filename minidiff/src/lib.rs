mod diff;
mod inline;
mod ir;
mod lang;
mod logging;
mod render;

use anyhow::Result;

pub use diff::{
    ChangeKind, ChangeSide, DiffOptions, DiffResult, DiffRow, DisplayLine, ParseOutcome,
    SyntaxDiff, TextDiff,
};
pub use ir::TokenRole;
pub use render::{OutputStyle, RenderOptions, Wrapping, render_side_by_side};

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum Language {
    Rust,
}

pub fn diff(language: Language, lhs: &str, rhs: &str, options: DiffOptions) -> Result<DiffResult> {
    diff::diff(language, lhs, rhs, options)
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::PathBuf;

    use super::*;

    fn render_options(style: OutputStyle) -> RenderOptions {
        RenderOptions {
            output_style: style,
            wrapping: Wrapping::NoWrap,
            column_width: 48,
        }
    }

    #[test]
    fn syntax_aware_rust_diff_reports_structure_for_valid_items() {
        let lhs = "pub fn meaning() -> u32 { 41 }\n";
        let rhs = "pub fn meaning() -> u32 { 42 }\n";

        let diff_result = diff(Language::Rust, lhs, rhs, DiffOptions::default()).unwrap();

        match diff_result.parse_outcome {
            ParseOutcome::SyntaxAware(summary) => assert!(summary.matched_nodes > 0),
            ParseOutcome::FallbackText(reason) => {
                panic!("expected syntax aware diff, got fallback: {reason:?}")
            }
        }
    }

    #[test]
    fn malformed_rust_snippets_surface_explicit_fallback() {
        let lhs = "fn meaning( { 41 }\n";
        let rhs = "fn meaning() { 42 }\n";

        let diff_result = diff(Language::Rust, lhs, rhs, DiffOptions::default()).unwrap();

        match diff_result.parse_outcome {
            ParseOutcome::FallbackText(reason) => {
                assert!(reason.reason.contains("parse"));
            }
            ParseOutcome::SyntaxAware(summary) => {
                panic!("expected fallback diff, got syntax aware: {summary:?}")
            }
        }
    }

    #[test]
    fn plain_render_includes_line_numbers_and_both_sides() {
        let lhs = "pub fn meaning() -> u32 { 41 }\n";
        let rhs = "pub fn meaning() -> u32 { 42 }\n";
        let diff_result = diff(Language::Rust, lhs, rhs, DiffOptions::default()).unwrap();

        let rendered =
            render_side_by_side(&diff_result, &render_options(OutputStyle::Plain)).unwrap();

        assert!(rendered.contains("L1"));
        assert!(rendered.contains("R1"));
        assert!(rendered.contains("41"));
        assert!(rendered.contains("42"));
    }

    #[test]
    fn ansi_render_highlights_changed_segments() {
        let lhs = "const NOTE: &str = \"alpha beta\";\n";
        let rhs = "const NOTE: &str = \"alpha gamma\";\n";
        let diff_result = diff(Language::Rust, lhs, rhs, DiffOptions::default()).unwrap();

        let rendered =
            render_side_by_side(&diff_result, &render_options(OutputStyle::Ansi)).unwrap();

        assert!(rendered.contains("\u{1b}["));
        assert!(rendered.contains("alpha"));
        assert!(rendered.contains("gamma"));
    }

    #[test]
    fn clojure_quality_fixture_matches_snapshot() {
        let fixture_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("fixtures/clojure");
        let lhs = fs::read_to_string(fixture_dir.join("nested-reshape.lhs.clj")).unwrap();
        let rhs = fs::read_to_string(fixture_dir.join("nested-reshape.rhs.clj")).unwrap();
        let expected = fs::read_to_string(fixture_dir.join("nested-reshape.rendered.txt")).unwrap();

        let diff_result = diff(Language::Rust, &lhs, &rhs, DiffOptions::default()).unwrap();
        let rendered =
            render_side_by_side(&diff_result, &render_options(OutputStyle::Plain)).unwrap();

        assert_eq!(rendered, expected);
    }
}
