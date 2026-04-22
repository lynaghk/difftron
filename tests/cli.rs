use std::{
    fs,
    os::unix::fs::PermissionsExt,
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

    assert!(output.status.success(), "stderr: {}", String::from_utf8_lossy(&output.stderr));

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
    let mock_difft = repo.write_executable("mock-difft", "#!/usr/bin/env bash\nprintf 'mock difftastic output'\n");

    let output = Command::new(binary_path())
        .current_dir(repo.path())
        .env("RUST_DIVE_DIFFT_PATH", &mock_difft)
        .args(["diff", "HEAD~1", "HEAD", "--format", "json"])
        .output()
        .expect("failed to run rust_dive");

    assert!(output.status.success(), "stderr: {}", String::from_utf8_lossy(&output.stderr));

    let json: Value = serde_json::from_slice(&output.stdout).expect("stdout should be json");
    assert_eq!(json["command"], "diff");
    assert_eq!(json["lhs"]["rev"], "HEAD~1");
    assert_eq!(json["rhs"]["rev"], "HEAD");
    let modified = json["modified"].as_array().expect("modified should be an array");
    assert!(modified.len() >= 1);
    let meaning = modified
        .iter()
        .find(|entry| entry["lhs"]["name"] == "demo::meaning")
        .expect("expected a modified function entry");
    assert_eq!(meaning["difftastic_display"], "mock difftastic output");
    assert_eq!(
        meaning["rhs"]["source_text"],
        "pub fn meaning() -> u32 { 42 }"
    );
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

    fn write_executable(&self, relative_path: &str, contents: &str) -> PathBuf {
        let absolute_path = self.path().join(relative_path);
        if let Some(parent) = absolute_path.parent() {
            fs::create_dir_all(parent).expect("failed to create parent directories");
        }
        fs::write(&absolute_path, contents).expect("failed to write file");
        let mut permissions = fs::metadata(&absolute_path).expect("failed to stat file").permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&absolute_path, permissions).expect("failed to set permissions");
        absolute_path
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
