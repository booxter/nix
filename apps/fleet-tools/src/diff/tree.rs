use std::collections::HashSet;
use std::fs;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::{Component, Path, PathBuf};

use anyhow::{Context, Result};

use super::normalize_store_paths;

pub(super) fn path_exists(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok()
}

pub(super) fn copy_generated_path(
    source_root: &Path,
    destination_root: &Path,
    relative: &Path,
) -> Result<()> {
    let source = source_root.join(relative);
    if should_skip(&source) {
        return Ok(());
    }
    let destination = destination_root.join(relative);
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)?;
    }
    let parent = match fs::canonicalize(source_root.parent().unwrap_or(source_root)) {
        Ok(root) => root,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => {
            return Err(error).with_context(|| format!("locating {}", source_root.display()))
        }
    };
    let root_path = parent.join(source_root.file_name().unwrap_or_default());
    let root = match resolve(&root_path, &parent)
        .with_context(|| format!("resolving {}", source_root.display()))?
    {
        Resolution::Path(path) => path,
        Resolution::Marker(marker) => {
            fs::write(&destination, normalize_store_paths(&marker))?;
            return Ok(());
        }
        Resolution::Missing => return Ok(()),
    };
    copy_node(
        &root.join(relative),
        &source,
        &destination,
        &root,
        &mut HashSet::new(),
    )
}

pub(super) fn copy_store_path(
    source: &Path,
    destination_root: &Path,
    relative: &Path,
) -> Result<()> {
    if should_skip(source) {
        return Ok(());
    }
    let destination = destination_root.join(relative);
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)?;
    }
    let (root, source) = if source.starts_with("/nix/store") {
        (PathBuf::from("/nix/store"), source.to_path_buf())
    } else {
        let root = match fs::canonicalize(source.parent().unwrap_or(source)) {
            Ok(root) => root,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
            Err(error) => {
                return Err(error).with_context(|| format!("locating {}", source.display()))
            }
        };
        let source = root.join(source.file_name().unwrap_or_default());
        (root, source)
    };
    copy_node(&source, &source, &destination, &root, &mut HashSet::new())
}

fn copy_node(
    source: &Path,
    logical_source: &Path,
    destination: &Path,
    root: &Path,
    ancestors: &mut HashSet<PathBuf>,
) -> Result<()> {
    let source =
        match resolve(source, root).with_context(|| format!("resolving {}", source.display()))? {
            Resolution::Path(path) => path,
            Resolution::Marker(marker) => {
                fs::write(destination, normalize_store_paths(&marker))?;
                return Ok(());
            }
            Resolution::Missing => return Ok(()),
        };
    let metadata = fs::metadata(&source)
        .with_context(|| format!("reading metadata for {}", source.display()))?;
    if metadata.is_dir() {
        if !ancestors.insert(source.clone()) {
            fs::write(
                destination,
                format!("symlink cycle -> {}\n", source.display()),
            )?;
            return Ok(());
        }
        fs::create_dir_all(destination)?;
        let mut entries: Vec<_> = fs::read_dir(&source)
            .with_context(|| format!("reading directory {}", source.display()))?
            .collect::<io::Result<_>>()?;
        entries.sort_by_key(|entry| entry.file_name());
        for entry in entries {
            let logical_child = logical_source.join(entry.file_name());
            if !should_skip(&logical_child) {
                copy_node(
                    &entry.path(),
                    &logical_child,
                    &destination.join(entry.file_name()),
                    root,
                    ancestors,
                )?;
            }
        }
        ancestors.remove(&source);
        return Ok(());
    }

    if !metadata.is_file() {
        return Ok(());
    }

    let bytes = fs::read(&source).with_context(|| format!("reading {}", source.display()))?;
    if !bytes.is_empty() && !bytes.contains(&0) {
        if let Ok(text) = std::str::from_utf8(&bytes) {
            fs::write(destination, normalize_store_paths(text))?;
            let mut permissions = fs::metadata(destination)?.permissions();
            permissions.set_mode(permissions.mode() | 0o200);
            fs::set_permissions(destination, permissions)?;
            return Ok(());
        }
    }
    fs::copy(&source, destination).with_context(|| format!("copying {}", source.display()))?;
    Ok(())
}

// Resolve one component at a time so an intermediate link cannot escape the
// source tree or store before we inspect its target.
enum Resolution {
    Path(PathBuf),
    Marker(String),
    Missing,
}

fn resolve(path: &Path, root: &Path) -> Result<Resolution> {
    let mut pending = path.to_path_buf();
    let mut seen = HashSet::new();
    let mut last_target = None;
    loop {
        let mut current = PathBuf::from("/");
        let components: Vec<_> = pending.components().collect();
        let mut followed = false;
        for (index, component) in components.iter().enumerate() {
            match component {
                Component::RootDir => continue,
                Component::CurDir => continue,
                Component::ParentDir => {
                    current.pop();
                }
                Component::Normal(part) => current.push(part),
                Component::Prefix(_) => unreachable!(),
            }
            // Ancestors are needed to reach an allowed root, but must not be
            // inspected as links themselves.
            if root.starts_with(&current) || Path::new("/nix/store").starts_with(&current) {
                continue;
            }
            if !current.starts_with(root) && !current.starts_with("/nix/store") {
                return Ok(Resolution::Marker(format!(
                    "symlink -> {}\n",
                    last_target.unwrap_or_else(|| current.clone()).display()
                )));
            }
            let metadata = match fs::symlink_metadata(&current) {
                Ok(metadata) => metadata,
                Err(error) if error.kind() == io::ErrorKind::NotFound && last_target.is_some() => {
                    return Ok(Resolution::Marker(format!(
                        "broken symlink -> {}\n",
                        last_target.unwrap().display()
                    )));
                }
                Err(error) if error.kind() == io::ErrorKind::NotFound => {
                    return Ok(Resolution::Missing)
                }
                Err(error) => return Err(error.into()),
            };
            if metadata.file_type().is_symlink() {
                let target = fs::read_link(&current)?;
                if !seen.insert(current.clone()) {
                    return Ok(Resolution::Marker(format!(
                        "symlink cycle -> {}\n",
                        target.display()
                    )));
                }
                last_target = Some(target.clone());
                let mut next = if target.is_absolute() {
                    target
                } else {
                    current.parent().unwrap().join(target)
                };
                for rest in &components[index + 1..] {
                    next.push(rest.as_os_str());
                }
                pending = next;
                followed = true;
                break;
            }
        }
        if !followed {
            if !current.starts_with(root) && !current.starts_with("/nix/store") {
                return Ok(Resolution::Marker(format!(
                    "symlink -> {}\n",
                    last_target.unwrap_or(current).display()
                )));
            }
            return Ok(Resolution::Path(current));
        }
    }
}

fn should_skip(path: &Path) -> bool {
    let path = path.to_string_lossy();
    [
        "/etc/profiles",
        "/share/man",
        "/etc/ssl/trust-source",
        "/etc/terminfo",
        "/etc/zoneinfo",
    ]
    .iter()
    .any(|pattern| at_or_below(&path, pattern))
        || [
            "/etc/pki/tls/certs/ca-bundle.crt",
            "/etc/ssl/certs/ca-bundle.crt",
            "/etc/ssl/certs/ca-certificates.crt",
            "/etc/ssh/moduli",
            "/etc/issue",
            "/etc/issue.net",
            "/etc/os-release",
            "/etc/lsb-release",
        ]
        .iter()
        .any(|pattern| path.ends_with(pattern))
}

fn at_or_below(path: &str, pattern: &str) -> bool {
    path.ends_with(pattern) || path.contains(&format!("{pattern}/"))
}
