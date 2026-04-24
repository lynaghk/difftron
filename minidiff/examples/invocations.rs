use anyhow::Result;
use minidiff::{DiffOptions, Language, OutputStyle, PresentationOptions, RenderOptions, Wrapping};

fn main() -> Result<()> {
    render_structural_change()?;
    render_inline_change()?;
    render_parse_fallback()?;
    Ok(())
}

fn render_structural_change() -> Result<()> {
    let lhs = r#"#[derive(Debug, Clone)]
pub struct Snapshot {
    pub entities: Vec<Entity>,
}
"#;

    let rhs = r#"#[derive(Debug)]
pub struct Snapshot {
    pub arena: Arena<Entity>,
    pub entities: Vec<EntityId>,
}
"#;

    let diff = minidiff::diff(Language::Rust, lhs, rhs, DiffOptions::default())?;
    let presentation = minidiff::present_side_by_side(&diff, &PresentationOptions::default());
    let rendered = minidiff::render_side_by_side(&presentation, &plain_options())?;

    println!("== Structural Change ==");
    println!("{rendered}");
    Ok(())
}

fn render_inline_change() -> Result<()> {
    let lhs = r#"const NOTE: &str = "alpha beta";
"#;

    let rhs = r#"const NOTE: &str = "alpha gamma";
"#;

    let diff = minidiff::diff(Language::Rust, lhs, rhs, DiffOptions::default())?;
    let presentation = minidiff::present_side_by_side(&diff, &PresentationOptions::default());
    let rendered = minidiff::render_side_by_side(&presentation, &ansi_options())?;

    println!("== Inline Change ==");
    println!("{rendered}");
    Ok(())
}

fn render_parse_fallback() -> Result<()> {
    let lhs = "fn broken( { 41 }\n";
    let rhs = "fn broken() { 42 }\n";

    let diff = minidiff::diff(Language::Rust, lhs, rhs, DiffOptions::default())?;
    let presentation = minidiff::present_side_by_side(&diff, &PresentationOptions::default());
    let rendered = minidiff::render_side_by_side(&presentation, &plain_options())?;

    println!("== Parse Fallback ==");
    println!("parse outcome: {:?}", diff.parse_outcome);
    println!("{rendered}");
    Ok(())
}

fn plain_options() -> RenderOptions {
    RenderOptions {
        output_style: OutputStyle::Plain,
        wrapping: Wrapping::NoWrap,
        column_width: 64,
    }
}

fn ansi_options() -> RenderOptions {
    RenderOptions {
        output_style: OutputStyle::Ansi,
        wrapping: Wrapping::NoWrap,
        column_width: 64,
    }
}
