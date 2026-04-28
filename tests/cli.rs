use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

use serde_json::Value;
use tempfile::TempDir;

#[test]
fn list_json_emits_structured_stdout() {
    let repo = TestRepo::new();

    let output = Command::new(binary_path())
        .current_dir(repo.path())
        .args(["list", ".", "--format", "json"])
        .output()
        .expect("failed to run rust_dive");

    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let json: Value = serde_json::from_slice(&output.stdout).expect("stdout should be json");
    assert_eq!(json["command"], "list");
    assert_eq!(json["snapshot"]["kind"], "directory");
    assert_eq!(json["entities"][0]["name"], "demo");
    assert_eq!(json["entities"][1]["name"], "demo::meaning");
}

#[test]
fn diff_json_emits_modified_entities() {
    let repo = TestRepo::new();
    repo.commit_all("initial");
    repo.write_lib("pub fn meaning() -> u32 { 42 }\n");
    repo.commit_all("change meaning");

    let output = Command::new(binary_path())
        .current_dir(repo.path())
        .args(["diff", "HEAD~1", "HEAD", "--format", "json"])
        .output()
        .expect("failed to run rust_dive");

    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let json: Value = serde_json::from_slice(&output.stdout).expect("stdout should be json");
    assert_eq!(json["command"], "diff");
    assert_eq!(json["lhs"]["rev"], "HEAD~1");
    assert_eq!(json["rhs"]["rev"], "HEAD");
    assert_eq!(json["lhs"]["summary"], "initial");
    assert_eq!(json["rhs"]["summary"], "change meaning");
    let modified = json["modified"]
        .as_array()
        .expect("modified should be an array");
    assert!(!modified.is_empty());
    let meaning = modified
        .iter()
        .find(|entry| entry["lhs"]["name"] == "demo::meaning")
        .expect("expected a modified function entry");
    assert!(meaning.get("diff_display").is_none());
    let diff = &meaning["diff"];
    assert_eq!(diff["rows"][0]["kind"], "replaced_code");
    assert_eq!(
        diff["rows"][0]["left"]["text"],
        "pub fn meaning() -> u32 { 41 }"
    );
    assert_eq!(diff["rows"][0]["right"]["segments"][1]["text"], "42");
    assert_eq!(diff["rows"][0]["right"]["segments"][1]["kind"], "novel");
    assert_eq!(
        meaning["rhs"]["source_text"],
        "pub fn meaning() -> u32 { 42 }"
    );
}

#[test]
fn diff_width_changes_rendered_layout() {
    let repo = TestRepo::new();
    repo.commit_all("initial");
    repo.write_lib("pub fn meaning() -> u32 { 42 }\n");
    repo.commit_all("change meaning");

    let output = Command::new(binary_path())
        .current_dir(repo.path())
        .args([
            "diff", "HEAD~1", "HEAD", "--format", "json", "--width", "60",
        ])
        .output()
        .expect("failed to run rust_dive");

    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let json: Value = serde_json::from_slice(&output.stdout).expect("stdout should be json");
    let modified = json["modified"]
        .as_array()
        .expect("modified should be an array");
    let meaning = modified
        .iter()
        .find(|entry| entry["lhs"]["name"] == "demo::meaning")
        .expect("expected a modified function entry");
    let left_text = meaning["diff"]["rows"][0]["left"]["text"]
        .as_str()
        .expect("left text should be present");
    let right_text = meaning["diff"]["rows"][0]["right"]["text"]
        .as_str()
        .expect("right text should be present");
    assert!(left_text.contains("pub fn meaning"));
    assert!(right_text.contains("42"));
}

#[test]
fn diff_json_accepts_single_files() {
    let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let lhs = repo_root.join("example-diffs/parent-child-changes/lhs.rs");
    let rhs = repo_root.join("example-diffs/parent-child-changes/rhs.rs");
    let output = Command::new(binary_path())
        .current_dir(&repo_root)
        .args([
            "diff",
            lhs.to_str().expect("lhs path should be valid utf-8"),
            rhs.to_str().expect("rhs path should be valid utf-8"),
            "--format",
            "json",
        ])
        .output()
        .expect("failed to run rust_dive");

    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let json: Value = serde_json::from_slice(&output.stdout).expect("stdout should be json");
    assert_eq!(json["command"], "diff");
    assert_eq!(json["lhs"]["kind"], "file");
    assert_eq!(json["rhs"]["kind"], "file");
    assert!(
        json["modified"]
            .as_array()
            .expect("modified should be an array")
            .iter()
            .any(|entry| entry["rhs"]["name"] == "file::demo::compute")
    );
}

#[test]
fn diff_json_suppresses_redundant_parent_entries_for_single_files() {
    let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let lhs = repo_root.join("example-diffs/parent-child-changes/lhs.rs");
    let rhs = repo_root.join("example-diffs/parent-child-changes/rhs.rs");
    let output = Command::new(binary_path())
        .current_dir(&repo_root)
        .args([
            "diff",
            lhs.to_str().expect("lhs path should be valid utf-8"),
            rhs.to_str().expect("rhs path should be valid utf-8"),
            "--format",
            "json",
        ])
        .output()
        .expect("failed to run rust_dive");

    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let json: Value = serde_json::from_slice(&output.stdout).expect("stdout should be json");
    let modified = json["modified"]
        .as_array()
        .expect("modified should be an array");
    let added = json["added"].as_array().expect("added should be an array");

    assert!(
        modified
            .iter()
            .any(|entry| entry["rhs"]["name"] == "file::demo"),
        "expected module change to remain: {modified:?}"
    );
    assert!(
        modified
            .iter()
            .any(|entry| entry["rhs"]["name"] == "file::demo::compute"),
        "expected function change to remain: {modified:?}"
    );
    assert!(
        !modified.iter().any(|entry| entry["rhs"]["name"] == "file"),
        "redundant root entry should be suppressed: {modified:?}"
    );
    assert!(
        added
            .iter()
            .any(|entry| entry["name"] == "file::demo::render"),
        "expected added child entry to remain: {added:?}"
    );
}

#[test]
fn list_json_accepts_single_clojure_files() {
    let dir = tempfile::tempdir().expect("failed to create temp dir");
    let source_path = dir.path().join("core.clj");
    fs::write(
        &source_path,
        "(ns demo.core)\n\n(defn meaning [] 41)\n(def message \"hello\")\n",
    )
    .expect("failed to write Clojure file");

    let output = Command::new(binary_path())
        .args([
            "list",
            source_path.to_str().expect("path should be valid utf-8"),
            "--format",
            "json",
        ])
        .output()
        .expect("failed to run rust_dive");

    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let json: Value = serde_json::from_slice(&output.stdout).expect("stdout should be json");
    let names = json["entities"]
        .as_array()
        .expect("entities should be an array")
        .iter()
        .map(|entity| entity["name"].as_str().unwrap())
        .collect::<Vec<_>>();

    assert_eq!(
        names,
        vec!["demo.core", "demo.core::meaning", "demo.core::message"]
    );
    assert_eq!(json["entities"][1]["kind"], "function");
}

fn binary_path() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_rust_dive"))
}

struct TestRepo {
    dir: TempDir,
}

impl TestRepo {
    fn new() -> Self {
        let dir = tempfile::tempdir().expect("failed to create temp dir");
        let repo = Self { dir };
        repo.write_file(
            "Cargo.toml",
            "[package]\nname = \"demo\"\nversion = \"0.1.0\"\nedition = \"2024\"\n",
        );
        repo.write_lib("pub fn meaning() -> u32 { 41 }\n");
        repo.git(["init"]);
        repo.git(["config", "user.name", "Test User"]);
        repo.git(["config", "user.email", "test@example.com"]);
        repo
    }

    fn path(&self) -> &Path {
        self.dir.path()
    }

    fn write_lib(&self, contents: &str) {
        self.write_file("src/lib.rs", contents);
    }

    fn write_file(&self, relative_path: &str, contents: &str) {
        let absolute_path = self.path().join(relative_path);
        if let Some(parent) = absolute_path.parent() {
            fs::create_dir_all(parent).expect("failed to create parent directories");
        }
        fs::write(absolute_path, contents).expect("failed to write file");
    }

    fn commit_all(&self, message: &str) {
        self.git(["add", "."]);
        self.git(["commit", "-m", message]);
    }

    fn git<I, S>(&self, args: I)
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        let output = Command::new("git")
            .current_dir(self.path())
            .args(args.into_iter().map(|arg| arg.as_ref().to_owned()))
            .output()
            .expect("failed to run git");

        assert!(
            output.status.success(),
            "git failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
}
