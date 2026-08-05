use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

use anyhow::{Context, Result};
use nix::unistd::{fchown, Gid, Uid};
use tempfile::NamedTempFile;

pub(crate) fn write_owned_atomic(
    path: &Path,
    mode: u32,
    uid: Uid,
    gid: Gid,
    write: impl FnOnce(&mut fs::File) -> Result<()>,
) -> Result<()> {
    let directory = path
        .parent()
        .filter(|directory| !directory.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let mut temporary = NamedTempFile::new_in(directory)
        .with_context(|| format!("failed to create temporary file beside {}", path.display()))?;
    temporary
        .as_file()
        .set_permissions(fs::Permissions::from_mode(mode))
        .with_context(|| format!("failed to set permissions for {}", path.display()))?;
    fchown(temporary.as_file(), Some(uid), Some(gid))
        .with_context(|| format!("failed to set ownership for {}", path.display()))?;
    write(temporary.as_file_mut())?;
    temporary
        .as_file()
        .sync_all()
        .with_context(|| format!("failed to sync {}", path.display()))?;
    temporary
        .persist(path)
        .map_err(|error| error.error)
        .with_context(|| format!("failed to install {}", path.display()))?;
    Ok(())
}
