use std::fs::File;
use std::path::Path;

use anyhow::{Context, Result};

pub(crate) struct FileLock(File);

impl FileLock {
    pub(crate) fn open(path: &Path) -> Result<Self> {
        // Keep the file in place: unlinking it could let another process lock
        // a different inode while the original owner is still running.
        let file = File::options()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(path)
            .with_context(|| format!("failed to open lock {}", path.display()))?;
        Ok(Self(file))
    }

    pub(crate) fn lock(&self) -> std::io::Result<()> {
        self.0.lock()
    }

    pub(crate) fn try_lock(&self) -> Result<(), std::fs::TryLockError> {
        self.0.try_lock()
    }
}

impl Drop for FileLock {
    fn drop(&mut self) {
        // Unlock explicitly in case a spawned child briefly inherited the
        // descriptor before exec closes it.
        let _ = self.0.unlock();
    }
}
