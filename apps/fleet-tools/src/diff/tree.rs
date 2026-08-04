use std::fs;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

use anyhow::Result;

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
    if !path_exists(&source) || should_skip(&source) {
        return Ok(());
    }
    let destination = destination_root.join(relative);
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)?;
    }
    copy_node(&source, &destination)
}

pub(super) fn copy_store_path(
    source: &Path,
    destination_root: &Path,
    relative: &Path,
) -> Result<()> {
    if !path_exists(source) || should_skip(source) {
        return Ok(());
    }
    let destination = destination_root.join(relative);
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)?;
    }
    copy_node(source, &destination)
}

fn copy_node(source: &Path, destination: &Path) -> Result<()> {
    let symlink_metadata = fs::symlink_metadata(source)?;
    if symlink_metadata.file_type().is_symlink() && fs::metadata(source).is_err() {
        let target = fs::read_link(source)?;
        fs::write(
            destination,
            normalize_store_paths(&format!("broken symlink -> {}\n", target.display())),
        )?;
        return Ok(());
    }
    if fs::metadata(source)?.is_dir() {
        fs::create_dir_all(destination)?;
        let mut entries: Vec<_> = fs::read_dir(source)?.collect::<io::Result<_>>()?;
        entries.sort_by_key(|entry| entry.file_name());
        for entry in entries {
            let child = entry.path();
            if !should_skip(&child) {
                copy_node(&child, &destination.join(entry.file_name()))?;
            }
        }
        return Ok(());
    }

    let bytes = fs::read(source)?;
    if !bytes.is_empty() && !bytes.contains(&0) {
        if let Ok(text) = std::str::from_utf8(&bytes) {
            fs::write(destination, normalize_store_paths(text))?;
            let mut permissions = fs::metadata(destination)?.permissions();
            permissions.set_mode(permissions.mode() | 0o200);
            fs::set_permissions(destination, permissions)?;
            return Ok(());
        }
    }
    fs::copy(source, destination)?;
    Ok(())
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
