use std::collections::BTreeSet;
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

pub(super) struct DeploymentLock {
    _locks: Vec<FileLock>,
}

pub(super) fn lock(directory: &Path, hosts: &[String]) -> Result<DeploymentLock> {
    // Deduplicate canonical names and acquire in a consistent order. If any
    // target is busy, dropping the partial set releases all earlier locks.
    let locks = hosts
        .iter()
        .collect::<BTreeSet<_>>()
        .into_iter()
        .map(|host| lock_host(directory, host))
        .collect::<Result<Vec<_>>>()?;
    Ok(DeploymentLock { _locks: locks })
}

fn lock_host(directory: &Path, host: &str) -> Result<FileLock> {
    let host_directory = directory.join(host);
    fs::create_dir_all(&host_directory).with_context(|| {
        format!(
            "failed to create deployment state directory {}",
            host_directory.display()
        )
    })?;
    let path = host_directory.join("lock");
    let file = FileLock::open(&path)?;

    match file.try_lock() {
        Ok(()) => Ok(file),
        Err(TryLockError::WouldBlock) => {
            bail!(
                "another deployment is running for {host} (lock: {})",
                path.display()
            )
        }
        Err(TryLockError::Error(error)) => {
            Err(error).with_context(|| format!("failed to lock {}", path.display()))
        }
    }
}

pub(super) fn lock_gc(directory: &Path) -> Result<FileLock> {
    let lock = FileLock::open(&directory.join("gc.lock"))?;
    lock.lock()
        .context("failed to lock local deployment garbage collection")?;
    Ok(lock)
}

#[cfg(test)]
mod tests {
    use std::io::{self, BufRead, Write};
    use std::process::{Command, Stdio};
    use std::sync::mpsc;
    use std::time::Duration;

    use super::*;

    #[test]
    fn lock_is_exclusive_and_released_when_dropped() {
        let directory = tempfile::tempdir().unwrap();
        let hosts = vec!["alpha".to_owned()];
        let held = lock(directory.path(), &hosts).unwrap();

        let error = lock(directory.path(), &hosts).err().unwrap();
        assert!(error.to_string().contains("another deployment is running"));

        drop(held);
        assert!(lock(directory.path(), &hosts).is_ok());
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
        let hosts = vec!["alpha".to_owned(), "beta".to_owned()];
        let competing = lock(directory.path(), &hosts);
        assert!(lock(directory.path(), &["beta".to_owned()]).is_err());
        child.kill().unwrap();
        child.wait().unwrap();

        assert!(competing.is_err());
        assert!(lock(directory.path(), &hosts).is_ok());
    }

    #[test]
    fn lock_holder() {
        let Some(directory) = env::var_os("FLEET_DEPLOY_TEST_LOCK") else {
            return;
        };
        let _held = lock(
            Path::new(&directory),
            &["alpha".to_owned(), "beta".to_owned()],
        )
        .unwrap();
        println!("lock acquired");
        io::stdout().flush().unwrap();
        let mut line = String::new();
        io::stdin().read_line(&mut line).unwrap();
    }

    #[test]
    fn distinct_hosts_can_deploy_concurrently() {
        let directory = tempfile::tempdir().unwrap();
        let _alpha = lock(directory.path(), &["alpha".to_owned()]).unwrap();
        let _beta = lock(directory.path(), &["beta".to_owned()]).unwrap();
    }

    #[test]
    fn overlapping_targets_release_partially_acquired_locks() {
        let directory = tempfile::tempdir().unwrap();
        let _beta = lock(directory.path(), &["beta".to_owned()]).unwrap();
        let error = lock(directory.path(), &["beta".to_owned(), "alpha".to_owned()])
            .err()
            .unwrap();
        assert!(error.to_string().contains("for beta"));
        let _alpha = lock(directory.path(), &["alpha".to_owned()]).unwrap();
    }

    #[test]
    fn repeated_targets_do_not_conflict_with_themselves() {
        let directory = tempfile::tempdir().unwrap();
        let _held = lock(directory.path(), &["alpha".to_owned(), "alpha".to_owned()]).unwrap();
    }

    #[test]
    fn garbage_collection_waits_without_blocking_host_locks() {
        let directory = tempfile::tempdir().unwrap();
        let _alpha = lock(directory.path(), &["alpha".to_owned()]).unwrap();
        let held = lock_gc(directory.path()).unwrap();
        let path = directory.path().to_owned();
        let (sender, receiver) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            let _gc = lock_gc(&path).unwrap();
            sender.send(()).unwrap();
        });

        assert!(matches!(
            receiver.recv_timeout(Duration::from_millis(100)),
            Err(mpsc::RecvTimeoutError::Timeout)
        ));
        let _beta = lock(directory.path(), &["beta".to_owned()]).unwrap();
        drop(held);
        receiver.recv_timeout(Duration::from_secs(10)).unwrap();
        worker.join().unwrap();
    }
}
