use std::path::{Path, PathBuf};

use anyhow::{anyhow, Context, Result};

pub(crate) fn checkout_root(start: &Path) -> Result<PathBuf> {
    let repository = gix::discover(start)
        .map_err(|_| anyhow!("{} is not inside a Git checkout", start.display()))?;
    repository
        .workdir()
        .map(Path::to_path_buf)
        .context("Git repository is bare and has no checkout")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn discovers_checkout_from_nested_directory() {
        let checkout = tempfile::tempdir().expect("temporary checkout");
        gix::init(checkout.path()).expect("initialize repository");
        let nested = checkout.path().join("one/two");
        std::fs::create_dir_all(&nested).expect("create nested directory");

        assert_eq!(checkout_root(&nested).unwrap(), checkout.path());
    }

    #[test]
    fn rejects_paths_outside_a_checkout() {
        let directory = tempfile::tempdir().expect("temporary directory");

        let error = checkout_root(directory.path()).unwrap_err();

        assert!(error.to_string().contains("is not inside a Git checkout"));
    }

    #[test]
    fn rejects_bare_repositories() {
        let directory = tempfile::tempdir().expect("temporary repository");
        gix::init_bare(directory.path()).expect("initialize bare repository");

        let error = checkout_root(directory.path()).unwrap_err();

        assert!(error.to_string().contains("bare"));
    }
}
