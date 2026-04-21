use std::{
    collections::{BTreeSet, HashSet},
    path::{Component, Path, PathBuf},
};

use anyhow::{Context, Result, bail};
use serde::Deserialize;

use crate::source_repo::SourceRepo;

#[derive(Debug, Clone, Eq, PartialEq, Ord, PartialOrd)]
pub struct TargetRoot {
    pub crate_name: String,
    pub root_file: PathBuf,
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

pub fn discover_targets(repo: &dyn SourceRepo) -> Result<Vec<TargetRoot>> {
    let root_manifest = PathBuf::from("Cargo.toml");
    if !repo.is_file(&root_manifest)? {
        bail!("expected {} to contain a Cargo.toml", repo.root().display());
    }

    let mut visited_packages = HashSet::new();
    let mut targets = BTreeSet::new();
    discover_manifest(repo, &root_manifest, &mut visited_packages, &mut targets)?;
    Ok(targets.into_iter().collect())
}

fn discover_manifest(
    repo: &dyn SourceRepo,
    manifest_path: &Path,
    visited_packages: &mut HashSet<PathBuf>,
    targets: &mut BTreeSet<TargetRoot>,
) -> Result<()> {
    let manifest = parse_manifest(repo, manifest_path)?;
    let package_dir = manifest_dir(manifest_path);

    if manifest.package.is_some() && visited_packages.insert(package_dir.clone()) {
        targets.extend(targets_for_package(repo, &manifest, &package_dir)?);
    }

    if let Some(workspace) = manifest.workspace {
        for member in workspace.members {
            for member_dir in expand_member_pattern(repo, &package_dir, &member)? {
                let member_manifest = member_dir.join("Cargo.toml");
                if repo.is_file(&member_manifest)? {
                    discover_manifest(repo, &member_manifest, visited_packages, targets)?;
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
) -> Result<Vec<TargetRoot>> {
    let package = manifest
        .package
        .as_ref()
        .expect("package should exist when collecting package targets");
    let package_name = package.name.replace('-', "_");
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
            let crate_name = target
                .name
                .as_deref()
                .map(normalize_crate_name)
                .unwrap_or_else(|| inferred_target_name(path));
            add_target_if_present(
                repo,
                &mut targets,
                package_dir,
                Some(path),
                path,
                crate_name,
            )?;
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
    targets: &mut BTreeSet<TargetRoot>,
    package_dir: &Path,
    entries: &[TargetManifest],
) -> Result<()> {
    for entry in entries {
        let Some(path) = entry.path.as_deref() else {
            continue;
        };
        let crate_name = entry
            .name
            .as_deref()
            .map(normalize_crate_name)
            .unwrap_or_else(|| inferred_target_name(path));
        add_target_if_present(repo, targets, package_dir, Some(path), path, crate_name)?;
    }
    Ok(())
}

fn add_directory_targets(
    repo: &dyn SourceRepo,
    targets: &mut BTreeSet<TargetRoot>,
    dir: &Path,
) -> Result<()> {
    if !repo.is_dir(dir)? {
        return Ok(());
    }

    for child in repo.read_dir(dir)? {
        if repo.is_file(&child)? && child.extension().is_some_and(|ext| ext == "rs") {
            let crate_name = child
                .file_stem()
                .and_then(|stem| stem.to_str())
                .map(normalize_crate_name)
                .unwrap_or_else(|| "bin".to_owned());
            targets.insert(TargetRoot {
                crate_name,
                root_file: child,
            });
        } else if repo.is_dir(&child)? {
            let candidate = child.join("main.rs");
            if repo.is_file(&candidate)? {
                let crate_name = child
                    .file_name()
                    .and_then(|name| name.to_str())
                    .map(normalize_crate_name)
                    .unwrap_or_else(|| "bin".to_owned());
                targets.insert(TargetRoot {
                    crate_name,
                    root_file: candidate,
                });
            }
        }
    }

    Ok(())
}

fn add_target_if_present(
    repo: &dyn SourceRepo,
    targets: &mut BTreeSet<TargetRoot>,
    package_dir: &Path,
    explicit_path: Option<&str>,
    default_path: &str,
    crate_name: String,
) -> Result<()> {
    let relative_path = explicit_path
        .map(|path| normalize_relative(&package_dir.join(path)))
        .unwrap_or_else(|| normalize_relative(&package_dir.join(default_path)));
    if repo.is_file(&relative_path)? {
        targets.insert(TargetRoot {
            crate_name,
            root_file: relative_path,
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
        .map(normalize_crate_name)
        .unwrap_or_else(|| "target".to_owned())
}

fn normalize_crate_name(name: &str) -> String {
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
