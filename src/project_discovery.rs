use std::{
    collections::{BTreeSet, HashSet},
    path::{Component, Path, PathBuf},
};

use anyhow::{Context, Result, bail};
use minidiff::Language;
use serde::Deserialize;

use crate::source_repo::SourceRepo;

#[derive(Debug, Clone, Eq, PartialEq, Ord, PartialOrd)]
pub struct SourceTarget {
    pub root_name: String,
    pub root_file: PathBuf,
    pub language: Language,
}

#[derive(Debug, Deserialize)]
struct Manifest {
    package: Option<PackageManifest>,
    workspace: Option<WorkspaceManifest>,
    lib: Option<TargetManifest>,
    #[serde(default)]
    bin: Vec<TargetManifest>,
    #[serde(default)]
    example: Vec<TargetManifest>,
    #[serde(default)]
    test: Vec<TargetManifest>,
    #[serde(default)]
    bench: Vec<TargetManifest>,
}

#[derive(Debug, Deserialize)]
struct PackageManifest {
    name: String,
}

#[derive(Debug, Deserialize)]
struct WorkspaceManifest {
    #[serde(default)]
    members: Vec<String>,
}

#[derive(Debug, Deserialize, Default)]
struct TargetManifest {
    name: Option<String>,
    path: Option<String>,
}

pub fn discover_targets(repo: &dyn SourceRepo) -> Result<Vec<SourceTarget>> {
    let mut targets = BTreeSet::new();
    collect_file_targets(repo, Path::new(""), &mut targets)?;
    collect_rust_targets(repo, &mut targets)?;

    Ok(targets.into_iter().collect())
}

fn collect_rust_targets(repo: &dyn SourceRepo, targets: &mut BTreeSet<SourceTarget>) -> Result<()> {
    let root_manifest = PathBuf::from("Cargo.toml");
    if !repo.is_file(&root_manifest)? {
        return Ok(());
    }

    let mut visited_manifests = HashSet::new();
    let mut visited_packages = HashSet::new();
    discover_manifest(
        repo,
        &root_manifest,
        &mut visited_manifests,
        &mut visited_packages,
        targets,
    )
}

fn collect_file_targets(
    repo: &dyn SourceRepo,
    dir: &Path,
    targets: &mut BTreeSet<SourceTarget>,
) -> Result<()> {
    if !repo.is_dir(dir)? {
        return Ok(());
    }

    for child in repo.read_dir(dir)? {
        if repo.is_dir(&child)? {
            if should_skip_source_dir(&child) {
                continue;
            }
            collect_file_targets(repo, &child, targets)?;
        } else if repo.is_file(&child)? && is_clojure_code_file(&child) {
            targets.insert(SourceTarget {
                root_name: path_root_name(&child),
                root_file: child,
                language: Language::Clojure,
            });
        } else if repo.is_file(&child)? && is_typescript_code_file(&child) {
            targets.insert(SourceTarget {
                root_name: path_root_name(&child),
                root_file: child,
                language: Language::TypeScript,
            });
        }
    }

    Ok(())
}

fn should_skip_source_dir(path: &Path) -> bool {
    path.file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| {
            matches!(
                name,
                ".git"
                    | ".clj-kondo"
                    | ".cpcache"
                    | ".next"
                    | ".shadow-cljs"
                    | "build"
                    | "coverage"
                    | "dist"
                    | "node_modules"
                    | "target"
            )
        })
}

fn is_clojure_code_file(path: &Path) -> bool {
    matches!(
        path.extension().and_then(|extension| extension.to_str()),
        Some("clj" | "cljs" | "cljc")
    )
}

fn is_typescript_code_file(path: &Path) -> bool {
    path.extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| extension == "ts")
        && !is_typescript_declaration_file(path)
}

fn is_typescript_declaration_file(path: &Path) -> bool {
    path.file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| name.ends_with(".d.ts"))
}

fn path_root_name(path: &Path) -> String {
    let parts = path
        .with_extension("")
        .components()
        .filter_map(|component| match component {
            Component::Normal(part) => part.to_str().map(normalize_root_name),
            _ => None,
        })
        .collect::<Vec<_>>();
    if parts.is_empty() {
        "source".to_owned()
    } else {
        parts.join(".")
    }
}

fn discover_manifest(
    repo: &dyn SourceRepo,
    manifest_path: &Path,
    visited_manifests: &mut HashSet<PathBuf>,
    visited_packages: &mut HashSet<PathBuf>,
    targets: &mut BTreeSet<SourceTarget>,
) -> Result<()> {
    let manifest_path = normalize_relative(manifest_path);
    if !visited_manifests.insert(manifest_path.clone()) {
        return Ok(());
    }

    let manifest = parse_manifest(repo, &manifest_path)?;
    let package_dir = manifest_dir(&manifest_path);

    if manifest.package.is_some() && visited_packages.insert(package_dir.clone()) {
        targets.extend(targets_for_package(repo, &manifest, &package_dir)?);
    }

    if let Some(workspace) = manifest.workspace {
        for member in workspace.members {
            for member_dir in expand_member_pattern(repo, &package_dir, &member)? {
                let member_manifest = member_dir.join("Cargo.toml");
                if repo.is_file(&member_manifest)? {
                    discover_manifest(
                        repo,
                        &member_manifest,
                        visited_manifests,
                        visited_packages,
                        targets,
                    )?;
                }
            }
        }
    }

    Ok(())
}

fn parse_manifest(repo: &dyn SourceRepo, manifest_path: &Path) -> Result<Manifest> {
    let manifest_text = repo
        .read_file(manifest_path)?
        .with_context(|| format!("missing {}", manifest_path.display()))?;
    toml::from_str(&manifest_text)
        .with_context(|| format!("failed to parse {}", manifest_path.display()))
}

fn targets_for_package(
    repo: &dyn SourceRepo,
    manifest: &Manifest,
    package_dir: &Path,
) -> Result<Vec<SourceTarget>> {
    let package = manifest
        .package
        .as_ref()
        .expect("package should exist when collecting package targets");
    let package_name = normalize_root_name(&package.name);
    let mut targets = BTreeSet::new();

    add_target_if_present(
        repo,
        &mut targets,
        package_dir,
        manifest
            .lib
            .as_ref()
            .and_then(|target| target.path.as_deref()),
        "src/lib.rs",
        package_name.clone(),
    )?;
    add_target_if_present(
        repo,
        &mut targets,
        package_dir,
        None,
        "src/main.rs",
        package_name.clone(),
    )?;

    for target in &manifest.bin {
        if let Some(path) = target.path.as_deref() {
            let root_name = target
                .name
                .as_deref()
                .map(normalize_root_name)
                .unwrap_or_else(|| inferred_target_name(path));
            add_target_if_present(repo, &mut targets, package_dir, Some(path), path, root_name)?;
        }
    }

    add_directory_targets(repo, &mut targets, &package_dir.join("src/bin"))?;
    add_explicit_targets(repo, &mut targets, package_dir, &manifest.example)?;
    add_explicit_targets(repo, &mut targets, package_dir, &manifest.test)?;
    add_explicit_targets(repo, &mut targets, package_dir, &manifest.bench)?;

    Ok(targets.into_iter().collect())
}

fn add_explicit_targets(
    repo: &dyn SourceRepo,
    targets: &mut BTreeSet<SourceTarget>,
    package_dir: &Path,
    entries: &[TargetManifest],
) -> Result<()> {
    for entry in entries {
        let Some(path) = entry.path.as_deref() else {
            continue;
        };
        let root_name = entry
            .name
            .as_deref()
            .map(normalize_root_name)
            .unwrap_or_else(|| inferred_target_name(path));
        add_target_if_present(repo, targets, package_dir, Some(path), path, root_name)?;
    }
    Ok(())
}

fn add_directory_targets(
    repo: &dyn SourceRepo,
    targets: &mut BTreeSet<SourceTarget>,
    dir: &Path,
) -> Result<()> {
    if !repo.is_dir(dir)? {
        return Ok(());
    }

    for child in repo.read_dir(dir)? {
        if repo.is_file(&child)? && child.extension().is_some_and(|ext| ext == "rs") {
            let root_name = child
                .file_stem()
                .and_then(|stem| stem.to_str())
                .map(normalize_root_name)
                .unwrap_or_else(|| "bin".to_owned());
            targets.insert(SourceTarget {
                root_name,
                root_file: child,
                language: Language::Rust,
            });
        } else if repo.is_dir(&child)? {
            let candidate = child.join("main.rs");
            if repo.is_file(&candidate)? {
                let root_name = child
                    .file_name()
                    .and_then(|name| name.to_str())
                    .map(normalize_root_name)
                    .unwrap_or_else(|| "bin".to_owned());
                targets.insert(SourceTarget {
                    root_name,
                    root_file: candidate,
                    language: Language::Rust,
                });
            }
        }
    }

    Ok(())
}

fn add_target_if_present(
    repo: &dyn SourceRepo,
    targets: &mut BTreeSet<SourceTarget>,
    package_dir: &Path,
    explicit_path: Option<&str>,
    default_path: &str,
    root_name: String,
) -> Result<()> {
    let relative_path = explicit_path
        .map(|path| normalize_relative(&package_dir.join(path)))
        .unwrap_or_else(|| normalize_relative(&package_dir.join(default_path)));
    if repo.is_file(&relative_path)? {
        targets.insert(SourceTarget {
            root_name,
            root_file: relative_path,
            language: Language::Rust,
        });
    }
    Ok(())
}

fn expand_member_pattern(
    repo: &dyn SourceRepo,
    base_dir: &Path,
    pattern: &str,
) -> Result<Vec<PathBuf>> {
    let pattern = normalize_relative(&base_dir.join(pattern));
    if !has_wildcards(&pattern) {
        return Ok(vec![pattern]);
    }

    let mut results = Vec::new();
    expand_pattern_recursive(repo, Path::new(""), &pattern, &mut results)?;
    results.sort();
    results.dedup();
    Ok(results)
}

fn expand_pattern_recursive(
    repo: &dyn SourceRepo,
    current: &Path,
    pattern: &Path,
    results: &mut Vec<PathBuf>,
) -> Result<()> {
    let mut components = pattern.components();
    let Some(component) = components.next() else {
        results.push(current.to_path_buf());
        return Ok(());
    };
    let rest = components.as_path();

    match component {
        Component::Normal(segment) => {
            let segment = segment
                .to_str()
                .context("workspace member path must be valid UTF-8")?;
            if segment.contains('*') {
                if !repo.is_dir(current)? {
                    return Ok(());
                }

                for child in repo.read_dir(current)? {
                    let Some(name) = child.file_name().and_then(|name| name.to_str()) else {
                        continue;
                    };
                    if wildcard_matches(segment, name) {
                        expand_pattern_recursive(repo, &child, rest, results)?;
                    }
                }
            } else {
                expand_pattern_recursive(repo, &current.join(segment), rest, results)?;
            }
        }
        _ => bail!("workspace members must be relative paths"),
    }

    Ok(())
}

fn has_wildcards(path: &Path) -> bool {
    path.components().any(|component| match component {
        Component::Normal(segment) => segment
            .to_str()
            .is_some_and(|segment| segment.contains('*')),
        _ => false,
    })
}

fn wildcard_matches(pattern: &str, value: &str) -> bool {
    if !pattern.contains('*') {
        return pattern == value;
    }

    let parts = pattern.split('*').collect::<Vec<_>>();
    let starts_with_wildcard = pattern.starts_with('*');
    let ends_with_wildcard = pattern.ends_with('*');
    let mut remainder = value;

    for (index, part) in parts.iter().enumerate() {
        if part.is_empty() {
            continue;
        }

        if index == 0 && !starts_with_wildcard {
            let Some(stripped) = remainder.strip_prefix(part) else {
                return false;
            };
            remainder = stripped;
            continue;
        }

        if index == parts.len() - 1 && !ends_with_wildcard {
            return remainder.ends_with(part);
        }

        let Some(position) = remainder.find(part) else {
            return false;
        };
        remainder = &remainder[position + part.len()..];
    }

    true
}

fn manifest_dir(manifest_path: &Path) -> PathBuf {
    manifest_path
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_default()
}

fn inferred_target_name(path: &str) -> String {
    Path::new(path)
        .file_stem()
        .or_else(|| Path::new(path).parent().and_then(Path::file_name))
        .and_then(|name| name.to_str())
        .map(normalize_root_name)
        .unwrap_or_else(|| "target".to_owned())
}

fn normalize_root_name(name: &str) -> String {
    name.replace('-', "_")
}

fn normalize_relative(path: &Path) -> PathBuf {
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            Component::Normal(part) => normalized.push(part),
            Component::RootDir | Component::Prefix(_) => {}
        }
    }
    normalized
}

#[cfg(test)]
mod tests {
    use std::collections::{BTreeMap, BTreeSet};

    use super::*;
    use crate::source_repo::SourceRepo;

    #[derive(Debug)]
    struct TestRepo {
        files: BTreeMap<PathBuf, String>,
        dirs: BTreeSet<PathBuf>,
    }

    impl TestRepo {
        fn new(files: &[(&str, &str)]) -> Self {
            let mut repo = Self {
                files: BTreeMap::new(),
                dirs: BTreeSet::from([PathBuf::new()]),
            };

            for (path, contents) in files {
                let path = PathBuf::from(path);
                repo.add_parent_dirs(&path);
                repo.files.insert(path, (*contents).to_owned());
            }

            repo
        }

        fn add_parent_dirs(&mut self, path: &Path) {
            let mut current = PathBuf::new();
            for component in path
                .components()
                .take(path.components().count().saturating_sub(1))
            {
                current.push(component.as_os_str());
                self.dirs.insert(current.clone());
            }
        }
    }

    impl SourceRepo for TestRepo {
        fn root(&self) -> &Path {
            Path::new("/test")
        }

        fn file_path(&self, path: &Path) -> PathBuf {
            self.root().join(path)
        }

        fn snapshot_path(&self, path: &Path) -> PathBuf {
            path.to_path_buf()
        }

        fn read_file(&self, path: &Path) -> Result<Option<String>> {
            Ok(self.files.get(path).cloned())
        }

        fn is_file(&self, path: &Path) -> Result<bool> {
            Ok(self.files.contains_key(path))
        }

        fn is_dir(&self, path: &Path) -> Result<bool> {
            Ok(self.dirs.contains(path))
        }

        fn read_dir(&self, path: &Path) -> Result<Vec<PathBuf>> {
            let mut children = BTreeSet::new();
            for dir in &self.dirs {
                if let Ok(suffix) = dir.strip_prefix(path)
                    && suffix.components().count() == 1
                    && !suffix.as_os_str().is_empty()
                {
                    children.insert(dir.clone());
                }
            }
            for file in self.files.keys() {
                if let Some(parent) = file.parent()
                    && parent == path
                {
                    children.insert(file.clone());
                }
            }
            Ok(children.into_iter().collect())
        }
    }

    #[test]
    fn discover_targets_handles_workspace_self_member_without_recursing() {
        let repo = TestRepo::new(&[
            (
                "Cargo.toml",
                r#"
                [workspace]
                members = [".", "minidiff"]

                [package]
                name = "root_crate"

                [lib]
                path = "src/lib.rs"
                "#,
            ),
            ("src/lib.rs", "pub fn root() {}\n"),
            (
                "minidiff/Cargo.toml",
                r#"
                [package]
                name = "minidiff"

                [lib]
                path = "src/lib.rs"
                "#,
            ),
            ("minidiff/src/lib.rs", "pub fn nested() {}\n"),
        ]);

        let targets = discover_targets(&repo).unwrap();

        assert_eq!(
            targets,
            vec![
                SourceTarget {
                    root_name: "minidiff".to_owned(),
                    root_file: PathBuf::from("minidiff/src/lib.rs"),
                    language: Language::Rust,
                },
                SourceTarget {
                    root_name: "root_crate".to_owned(),
                    root_file: PathBuf::from("src/lib.rs"),
                    language: Language::Rust,
                },
            ]
        );
    }

    #[test]
    fn discover_targets_merges_file_targets_with_cargo_targets() {
        let repo = TestRepo::new(&[
            (
                "Cargo.toml",
                r#"
                [package]
                name = "demo-crate"
                "#,
            ),
            ("src/lib.rs", "pub fn rust() {}\n"),
            ("src/app.ts", "export function render() { return 42; }\n"),
            (
                "src/app.d.ts",
                "export declare function render(): number;\n",
            ),
            ("src/windowtron/core.clj", "(ns windowtron.core)\n"),
            ("target/generated/ignored.clj", "(ns generated.ignored)\n"),
        ]);

        let targets = discover_targets(&repo).unwrap();

        assert_eq!(
            targets,
            vec![
                SourceTarget {
                    root_name: "demo_crate".to_owned(),
                    root_file: PathBuf::from("src/lib.rs"),
                    language: Language::Rust,
                },
                SourceTarget {
                    root_name: "src.app".to_owned(),
                    root_file: PathBuf::from("src/app.ts"),
                    language: Language::TypeScript,
                },
                SourceTarget {
                    root_name: "src.windowtron.core".to_owned(),
                    root_file: PathBuf::from("src/windowtron/core.clj"),
                    language: Language::Clojure,
                },
            ]
        );
    }

    #[test]
    fn discover_targets_collects_clojure_sources_without_cargo_manifest() {
        let repo = TestRepo::new(&[
            ("deps.edn", "{:paths [\"src\"]}\n"),
            ("src/windowtron/core.clj", "(ns windowtron.core)\n"),
            ("src/windowtron/ui.cljs", "(ns windowtron.ui)\n"),
            ("target/generated/ignored.clj", "(ns generated.ignored)\n"),
        ]);

        let targets = discover_targets(&repo).unwrap();

        assert_eq!(
            targets,
            vec![
                SourceTarget {
                    root_name: "src.windowtron.core".to_owned(),
                    root_file: PathBuf::from("src/windowtron/core.clj"),
                    language: Language::Clojure,
                },
                SourceTarget {
                    root_name: "src.windowtron.ui".to_owned(),
                    root_file: PathBuf::from("src/windowtron/ui.cljs"),
                    language: Language::Clojure,
                },
            ]
        );
    }

    #[test]
    fn discover_targets_collects_typescript_sources_without_cargo_manifest() {
        let repo = TestRepo::new(&[
            ("package.json", "{\"name\":\"demo\"}\n"),
            ("src/app.ts", "export function render() { return 42; }\n"),
            (
                "src/app.d.ts",
                "export declare function render(): number;\n",
            ),
            (
                "node_modules/pkg/index.ts",
                "export const ignored = true;\n",
            ),
        ]);

        let targets = discover_targets(&repo).unwrap();

        assert_eq!(
            targets,
            vec![SourceTarget {
                root_name: "src.app".to_owned(),
                root_file: PathBuf::from("src/app.ts"),
                language: Language::TypeScript,
            }]
        );
    }

    #[test]
    fn discover_targets_returns_empty_for_unsupported_directories() {
        let repo = TestRepo::new(&[("src/lib.rs", "pub fn orphan() {}\n")]);

        let targets = discover_targets(&repo).unwrap();

        assert!(targets.is_empty());
    }
}
