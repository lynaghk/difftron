use std::{
    fs,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result, anyhow, bail};
use gix::bstr::ByteSlice;

pub trait SourceRepo {
    fn root(&self) -> &Path;
    fn file_path(&self, path: &Path) -> PathBuf;
    fn snapshot_path(&self, path: &Path) -> PathBuf;
    fn read_file(&self, path: &Path) -> Result<Option<String>>;
    fn is_file(&self, path: &Path) -> Result<bool>;
    fn is_dir(&self, path: &Path) -> Result<bool>;
    fn read_dir(&self, path: &Path) -> Result<Vec<PathBuf>>;
}

#[derive(Debug, Clone)]
pub struct FsSourceRepo {
    root: PathBuf,
}

impl FsSourceRepo {
    pub fn new(root: PathBuf) -> Self {
        Self { root }
    }

    fn absolute_path(&self, path: &Path) -> PathBuf {
        if path.as_os_str().is_empty() {
            self.root.clone()
        } else {
            self.root.join(path)
        }
    }
}

impl SourceRepo for FsSourceRepo {
    fn root(&self) -> &Path {
        &self.root
    }

    fn file_path(&self, path: &Path) -> PathBuf {
        self.absolute_path(path)
    }

    fn snapshot_path(&self, path: &Path) -> PathBuf {
        path.to_path_buf()
    }

    fn read_file(&self, path: &Path) -> Result<Option<String>> {
        read_file_if_present(&self.absolute_path(path))
    }

    fn is_file(&self, path: &Path) -> Result<bool> {
        Ok(self.absolute_path(path).is_file())
    }

    fn is_dir(&self, path: &Path) -> Result<bool> {
        Ok(self.absolute_path(path).is_dir())
    }

    fn read_dir(&self, path: &Path) -> Result<Vec<PathBuf>> {
        let absolute_path = self.absolute_path(path);
        read_dir_relative(
            &absolute_path,
            &self.root,
            "directory entries should stay within the source root",
        )
    }
}

#[derive(Debug, Clone)]
pub struct SingleFileSourceRepo {
    file_path: PathBuf,
    base_dir: PathBuf,
    display_base: Option<PathBuf>,
}

impl SingleFileSourceRepo {
    pub fn new(file_path: PathBuf, display_base: Option<PathBuf>) -> Result<Self> {
        let base_dir = file_path
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
            .context("file snapshot has no parent directory")?
            .to_path_buf();
        Ok(Self {
            file_path,
            base_dir,
            display_base,
        })
    }

    fn absolute_path(&self, path: &Path) -> PathBuf {
        if path.as_os_str().is_empty() {
            self.file_path.clone()
        } else if path.is_absolute() {
            path.to_path_buf()
        } else {
            self.base_dir.join(path)
        }
    }
}

impl SourceRepo for SingleFileSourceRepo {
    fn root(&self) -> &Path {
        &self.file_path
    }

    fn file_path(&self, path: &Path) -> PathBuf {
        self.absolute_path(path)
    }

    fn snapshot_path(&self, path: &Path) -> PathBuf {
        let absolute_path = self.absolute_path(path);
        if let Some(display_base) = &self.display_base
            && let Ok(snapshot_path) = absolute_path.strip_prefix(display_base)
        {
            return snapshot_path.to_path_buf();
        }
        absolute_path
    }

    fn read_file(&self, path: &Path) -> Result<Option<String>> {
        read_file_if_present(&self.absolute_path(path))
    }

    fn is_file(&self, path: &Path) -> Result<bool> {
        Ok(self.absolute_path(path).is_file())
    }

    fn is_dir(&self, path: &Path) -> Result<bool> {
        Ok(self.absolute_path(path).is_dir())
    }

    fn read_dir(&self, path: &Path) -> Result<Vec<PathBuf>> {
        let absolute_path = self.absolute_path(path);
        read_dir_relative(
            &absolute_path,
            &self.base_dir,
            "directory entries should stay within the source base",
        )
    }
}

fn read_file_if_present(path: &Path) -> Result<Option<String>> {
    match fs::read_to_string(path) {
        Ok(text) => Ok(Some(text)),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(err) => Err(err).with_context(|| format!("failed to read {}", path.display())),
    }
}

fn read_dir_relative(
    absolute_path: &Path,
    base_dir: &Path,
    strip_prefix_expectation: &'static str,
) -> Result<Vec<PathBuf>> {
    let entries = fs::read_dir(absolute_path)
        .with_context(|| format!("failed to read directory {}", absolute_path.display()))?;
    let mut children = Vec::new();

    for entry in entries {
        let entry = entry
            .with_context(|| format!("failed to read entry in {}", absolute_path.display()))?;
        children.push(
            entry
                .path()
                .strip_prefix(base_dir)
                .expect(strip_prefix_expectation)
                .to_path_buf(),
        );
    }

    children.sort();
    Ok(children)
}

pub struct GitTreeSourceRepo {
    repo_root: PathBuf,
    rev: String,
    repo: gix::Repository,
    tree_id: gix::ObjectId,
}

impl std::fmt::Debug for GitTreeSourceRepo {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("GitTreeSourceRepo")
            .field("repo_root", &self.repo_root)
            .field("rev", &self.rev)
            .field("tree_id", &self.tree_id)
            .finish()
    }
}

impl GitTreeSourceRepo {
    pub fn open(repo_root: PathBuf, rev: String) -> Result<Self> {
        let repo = gix::open(&repo_root)
            .with_context(|| format!("failed to open git repo {}", repo_root.display()))?;
        let tree_id = {
            let object = repo
                .rev_parse_single(rev.as_str())
                .with_context(|| format!("failed to resolve revision {rev}"))?
                .object()
                .with_context(|| format!("failed to load object for revision {rev}"))?;
            let tree = object
                .peel_to_tree()
                .with_context(|| format!("failed to peel revision {rev} to a tree"))?;
            tree.id
        };

        Ok(Self {
            repo_root,
            rev,
            repo,
            tree_id,
        })
    }

    fn root_tree(&self) -> Result<gix::Tree<'_>> {
        self.repo
            .find_tree(self.tree_id)
            .with_context(|| format!("failed to load tree {}", self.tree_id))
    }

    fn lookup_entry(&self, path: &Path) -> Result<Option<gix::object::tree::Entry<'_>>> {
        if path.as_os_str().is_empty() {
            return Ok(None);
        }

        self.root_tree()?
            .lookup_entry_by_path(path)
            .with_context(|| format!("failed to look up {}", path.display()))
    }

    fn tree_for_dir(&self, path: &Path) -> Result<Option<gix::Tree<'_>>> {
        if path.as_os_str().is_empty() {
            return self.root_tree().map(Some);
        }

        let Some(entry) = self.lookup_entry(path)? else {
            return Ok(None);
        };

        let object = entry.object().with_context(|| {
            format!("failed to load git object for directory {}", path.display())
        })?;
        match object.kind {
            gix::object::Kind::Tree => Ok(Some(object.into_tree())),
            _ => Ok(None),
        }
    }
}

impl SourceRepo for GitTreeSourceRepo {
    fn root(&self) -> &Path {
        &self.repo_root
    }

    fn file_path(&self, path: &Path) -> PathBuf {
        self.repo_root.join(path)
    }

    fn snapshot_path(&self, path: &Path) -> PathBuf {
        path.to_path_buf()
    }

    fn read_file(&self, path: &Path) -> Result<Option<String>> {
        let Some(entry) = self.lookup_entry(path)? else {
            return Ok(None);
        };

        let object = entry
            .object()
            .with_context(|| format!("failed to load git object for {}", path.display()))?;
        match object.kind {
            gix::object::Kind::Blob => {
                let mut blob = object.into_blob();
                let text = String::from_utf8(blob.take_data()).map_err(|err| {
                    anyhow!(
                        "failed to decode {} at revision {} as UTF-8: {}",
                        path.display(),
                        self.rev,
                        err
                    )
                })?;
                Ok(Some(text))
            }
            _ => Ok(None),
        }
    }

    fn is_file(&self, path: &Path) -> Result<bool> {
        let Some(entry) = self.lookup_entry(path)? else {
            return Ok(false);
        };
        Ok(matches!(
            entry.mode().kind(),
            gix::object::tree::EntryKind::Blob
        ))
    }

    fn is_dir(&self, path: &Path) -> Result<bool> {
        Ok(self.tree_for_dir(path)?.is_some())
    }

    fn read_dir(&self, path: &Path) -> Result<Vec<PathBuf>> {
        let Some(tree) = self.tree_for_dir(path)? else {
            bail!(
                "{} is not a directory in revision {}",
                path.display(),
                self.rev
            );
        };

        let mut children = Vec::new();
        for entry in tree.iter() {
            let entry = entry.with_context(|| format!("failed to iterate {}", path.display()))?;
            let name = PathBuf::from(
                entry
                    .filename()
                    .to_str()
                    .context("non-UTF-8 path in git tree")?,
            );
            let child = if path.as_os_str().is_empty() {
                name
            } else {
                path.join(name)
            };
            children.push(child);
        }

        children.sort();
        Ok(children)
    }
}
