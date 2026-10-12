use std::env;
use std::fs::{self, TryLockError};
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};

use crate::file_lock::FileLock;

pub(super) fn directory() -> Result<PathBuf> {
    let state_home = match env::var_os("XDG_STATE_HOME").filter(|value| !value.is_empty()) {
        Some(path) => PathBuf::from(path),
        None => PathBuf::from(env::var_os("HOME").context("HOME is not set")?).join(".local/state"),
    };
    Ok(state_home.join("fleet-deploy"))
}

pub(super) type DeploymentLock = FileLock;

pub(super) fn lock(directory: &Path) -> Result<DeploymentLock> {
    fs::create_dir_all(directory).with_context(|| {
        format!(
            "failed to create deployment state directory {}",
            directory.display()
        )
    })?;
    let path = directory.join("lock");
    let file = FileLock::open(&path)?;

    match file.try_lock() {
        Ok(()) => Ok(file),
        Err(TryLockError::WouldBlock) => {
            bail!("another deployment is running (lock: {})", path.display())
        }
        Err(TryLockError::Error(error)) => {
            Err(error).with_context(|| format!("failed to lock {}", path.display()))
        }
    }
}

#[cfg(test)]
mod tests {
    use std::io::{self, BufRead, Write};
    use std::process::{Command, Stdio};

    use super::*;

    #[test]
    fn lock_is_exclusive_and_released_when_dropped() {
        let directory = tempfile::tempdir().unwrap();
        let held = lock(directory.path()).unwrap();

        let error = lock(directory.path()).err().unwrap();
        assert!(error.to_string().contains("another deployment is running"));

        drop(held);
        assert!(lock(directory.path()).is_ok());
    }

    #[test]
    fn killing_the_owner_releases_the_lock() {
        let directory = tempfile::tempdir().unwrap();
        let mut child = Command::new(env::current_exe().unwrap())
            .args([
                "--exact",
                "deploy::state::tests::lock_holder",
                "--nocapture",
            ])
            .env("FLEET_DEPLOY_TEST_LOCK", directory.path())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let output = io::BufReader::new(child.stdout.take().unwrap());
        let ready = output
            .lines()
            .any(|line| line.unwrap().ends_with("lock acquired"));

        if !ready {
            let status = child.wait().unwrap();
            panic!("lock holder exited before acquiring its lock: {status}");
        }
        let competing = lock(directory.path());
        child.kill().unwrap();
        child.wait().unwrap();

        assert!(competing.is_err());
        assert!(lock(directory.path()).is_ok());
    }

    #[test]
    fn lock_holder() {
        let Some(directory) = env::var_os("FLEET_DEPLOY_TEST_LOCK") else {
            return;
        };
        let _held = lock(Path::new(&directory)).unwrap();
        println!("lock acquired");
        io::stdout().flush().unwrap();
        let mut line = String::new();
        io::stdin().read_line(&mut line).unwrap();
    }
}
