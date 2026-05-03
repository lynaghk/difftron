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
        .expect("failed to run CLI");

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
        .expect("failed to run CLI");

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
fn diff_json_emits_moved_rust_entities() {
    let repo = TestRepo::new();
    repo.write_lib("pub mod old;\n");
    repo.write_file("src/old.rs", "pub fn moved() -> u32 { 42 }\n");
    repo.commit_all("initial");
    repo.write_lib("pub mod new;\n");
    repo.write_file("src/new.rs", "pub fn moved() -> u32 { 42 }\n");
    repo.remove_file("src/old.rs");
    repo.commit_all("move function");

    let output = Command::new(binary_path())
        .current_dir(repo.path())
        .args(["diff", "HEAD~1", "HEAD", "--format", "json"])
        .output()
        .expect("failed to run CLI");

    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let json: Value = serde_json::from_slice(&output.stdout).expect("stdout should be json");
    let moved = json["moved"].as_array().expect("moved should be an array");
    let moved_function = moved
        .iter()
        .find(|entry| entry["rhs"]["name"] == "demo::new::moved")
        .expect("expected moved function entry");

    assert_eq!(moved_function["lhs"]["name"], "demo::old::moved");
    assert_eq!(moved_function["lhs"]["snapshot_path"], "src/old.rs");
    assert_eq!(moved_function["rhs"]["snapshot_path"], "src/new.rs");
    assert!(
        json["added"]
            .as_array()
            .expect("added should be an array")
            .iter()
            .all(|entry| entry["name"] != "demo::new::moved")
    );
    assert!(
        json["deleted"]
            .as_array()
            .expect("deleted should be an array")
            .iter()
            .all(|entry| entry["name"] != "demo::old::moved")
    );
}

#[test]
fn diff_json_emits_moved_modified_rust_entities() {
    let repo = TestRepo::new();
    repo.write_lib("pub mod old;\n");
    repo.write_file("src/old.rs", "pub fn moved() -> u32 { 41 }\n");
    repo.commit_all("initial");
    repo.write_lib("pub mod new;\n");
    repo.write_file("src/new.rs", "pub fn moved() -> u32 { 42 }\n");
    repo.remove_file("src/old.rs");
    repo.commit_all("move and change function");

    let output = Command::new(binary_path())
        .current_dir(repo.path())
        .args(["diff", "HEAD~1", "HEAD", "--format", "json"])
        .output()
        .expect("failed to run CLI");

    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let json: Value = serde_json::from_slice(&output.stdout).expect("stdout should be json");
    let moved_modified = json["moved_modified"]
        .as_array()
        .expect("moved_modified should be an array");
    let moved_function = moved_modified
        .iter()
        .find(|entry| entry["rhs"]["name"] == "demo::new::moved")
        .expect("expected moved-modified function entry");

    assert_eq!(moved_function["lhs"]["name"], "demo::old::moved");
    assert_eq!(moved_function["lhs"]["snapshot_path"], "src/old.rs");
    assert_eq!(moved_function["rhs"]["snapshot_path"], "src/new.rs");
    assert_eq!(
        moved_function["diff"]["rows"][0]["right"]["segments"][1]["text"],
        "42"
    );
    assert!(
        json["added"]
            .as_array()
            .expect("added should be an array")
            .iter()
            .all(|entry| entry["name"] != "demo::new::moved")
    );
    assert!(
        json["deleted"]
            .as_array()
            .expect("deleted should be an array")
            .iter()
            .all(|entry| entry["name"] != "demo::old::moved")
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
        .expect("failed to run CLI");

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
        .expect("failed to run CLI");

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
        .expect("failed to run CLI");

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
        .expect("failed to run CLI");

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
    assert_eq!(
        json["entity_kinds"]["namespace"]["group_label"],
        "Namespaces"
    );
    assert_eq!(json["entity_kinds"]["var"]["group_label"], "Vars");
    assert!(
        json["entity_kind_order"]
            .as_array()
            .expect("entity kind order should be an array")
            .iter()
            .any(|kind| kind == "namespace")
    );
    assert_eq!(json["entities"][0]["kind"], "namespace");
    assert_eq!(json["entities"][1]["kind"], "function");
    assert_eq!(json["entities"][2]["kind"], "var");
}

#[test]
fn diff_json_accepts_single_clojure_files() {
    let dir = tempfile::tempdir().expect("failed to create temp dir");
    let lhs = dir.path().join("lhs.clj");
    let rhs = dir.path().join("rhs.clj");
    fs::write(&lhs, "(ns demo.core)\n\n(defn meaning [] 41)\n").expect("failed to write lhs");
    fs::write(&rhs, "(ns demo.core)\n\n(defn meaning [] 42)\n").expect("failed to write rhs");

    let output = Command::new(binary_path())
        .args([
            "diff",
            lhs.to_str().expect("lhs path should be valid utf-8"),
            rhs.to_str().expect("rhs path should be valid utf-8"),
            "--format",
            "json",
        ])
        .output()
        .expect("failed to run CLI");

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
        .find(|entry| entry["rhs"]["name"] == "demo.core::meaning")
        .expect("expected modified Clojure function");

    assert_eq!(meaning["diff"]["rows"][0]["kind"], "replaced_code");
    assert_eq!(
        meaning["diff"]["rows"][0]["right"]["segments"][1]["text"],
        "42"
    );
}

#[test]
fn list_json_accepts_single_typescript_files() {
    let dir = tempfile::tempdir().expect("failed to create temp dir");
    let source_path = dir.path().join("app.ts");
    fs::write(
        &source_path,
        "export interface User { id: string; }\n\nexport function label(user: User): string {\n  return user.id;\n}\n",
    )
    .expect("failed to write TypeScript file");

    let output = Command::new(binary_path())
        .args([
            "list",
            source_path.to_str().expect("path should be valid utf-8"),
            "--format",
            "json",
        ])
        .output()
        .expect("failed to run CLI");

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

    assert_eq!(names, vec!["file", "file::User", "file::label"]);
    assert_eq!(
        json["entity_kinds"]["interface"]["group_label"],
        "Interfaces"
    );
    assert_eq!(json["entities"][1]["kind"], "interface");
    assert_eq!(json["entities"][2]["kind"], "function");
}

#[test]
fn list_json_collects_typescript_files_with_recoverable_parse_errors() {
    let dir = tempfile::tempdir().expect("failed to create temp dir");
    let source_path = dir.path().join("branchable-repo.ts");
    fs::write(
        &source_path,
        r#"export class BranchedDocHandle<T> {
  readonly #listeners = new Map<string, Set<(...args: unknown[]) => void>>();

  off(ev: string, fn: (...args: unknown[]) => void): this {
    this.#listeners.get(ev)?.delete(fn);
    return this;
  }
}
"#,
    )
    .expect("failed to write TypeScript file");

    let output = Command::new(binary_path())
        .args([
            "list",
            source_path.to_str().expect("path should be valid utf-8"),
            "--format",
            "json",
        ])
        .output()
        .expect("failed to run CLI");

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

    assert!(names.contains(&"file::BranchedDocHandle"));
    assert!(names.contains(&"file::BranchedDocHandle::off"));
}

#[test]
fn diff_json_accepts_pure_typescript_repositories() {
    let repo = TestRepo::new_typescript();
    repo.commit_all("initial");
    repo.write_file(
        "src/app.ts",
        "export function meaning(): number {\n  return 42;\n}\n",
    );
    repo.commit_all("change meaning");

    let output = Command::new(binary_path())
        .current_dir(repo.path())
        .args(["diff", "HEAD~1", "HEAD", "--format", "json"])
        .output()
        .expect("failed to run CLI");

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
        .find(|entry| entry["rhs"]["name"] == "src.app::meaning")
        .expect("expected modified TypeScript function");
    let changed_row = meaning["diff"]["rows"]
        .as_array()
        .expect("rows should be an array")
        .iter()
        .find(|row| row["kind"] == "replaced_code")
        .expect("expected changed TypeScript row");

    assert_eq!(changed_row["right"]["segments"][1]["text"], "42");
}

#[test]
fn diff_json_accepts_pure_clojure_repositories() {
    let repo = TestRepo::new_clojure();
    repo.commit_all("initial");
    repo.write_file(
        "src/windowtron/core.clj",
        "(ns windowtron.core)\n\n(defn meaning [] 42)\n",
    );
    repo.commit_all("change meaning");

    let output = Command::new(binary_path())
        .current_dir(repo.path())
        .args(["diff", "HEAD~1", "HEAD", "--format", "json"])
        .output()
        .expect("failed to run CLI");

    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let json: Value = serde_json::from_slice(&output.stdout).expect("stdout should be json");
    let modified = json["modified"]
        .as_array()
        .expect("modified should be an array");
    assert!(
        modified
            .iter()
            .any(|entry| entry["rhs"]["name"] == "windowtron.core::meaning"),
        "expected modified Clojure function: {modified:?}"
    );
}

#[test]
fn diff_json_emits_moved_clojure_entities() {
    let repo = TestRepo::new_clojure();
    repo.commit_all("initial");
    repo.write_file(
        "src/windowtron/renamed.clj",
        "(ns windowtron.renamed)\n\n(defn meaning [] 41)\n",
    );
    repo.remove_file("src/windowtron/core.clj");
    repo.commit_all("move namespace");

    let output = Command::new(binary_path())
        .current_dir(repo.path())
        .args(["diff", "HEAD~1", "HEAD", "--format", "json"])
        .output()
        .expect("failed to run CLI");

    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let json: Value = serde_json::from_slice(&output.stdout).expect("stdout should be json");
    let moved = json["moved"].as_array().expect("moved should be an array");
    let meaning = moved
        .iter()
        .find(|entry| entry["rhs"]["name"] == "windowtron.renamed::meaning")
        .expect("expected moved Clojure function");

    assert_eq!(meaning["lhs"]["name"], "windowtron.core::meaning");
    assert_eq!(
        meaning["rhs"]["snapshot_path"],
        "src/windowtron/renamed.clj"
    );
}

fn binary_path() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_difftron"))
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

    fn new_clojure() -> Self {
        let dir = tempfile::tempdir().expect("failed to create temp dir");
        let repo = Self { dir };
        repo.write_file("deps.edn", "{:paths [\"src\"]}\n");
        repo.write_file(
            "src/windowtron/core.clj",
            "(ns windowtron.core)\n\n(defn meaning [] 41)\n",
        );
        repo.git(["init"]);
        repo.git(["config", "user.name", "Test User"]);
        repo.git(["config", "user.email", "test@example.com"]);
        repo
    }

    fn new_typescript() -> Self {
        let dir = tempfile::tempdir().expect("failed to create temp dir");
        let repo = Self { dir };
        repo.write_file("package.json", "{\"name\":\"demo\"}\n");
        repo.write_file(
            "src/app.ts",
            "export function meaning(): number {\n  return 41;\n}\n",
        );
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

    fn remove_file(&self, relative_path: &str) {
        fs::remove_file(self.path().join(relative_path)).expect("failed to remove file");
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
