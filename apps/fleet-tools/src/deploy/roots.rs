use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use anyhow::{bail, Context, Result};

pub(super) fn source_command(nix: &Path, source: &Path) -> Command {
    let mut command = Command::new(nix);
    // Import and root in the same Nix process so its temporary root protects
    // the source until the persistent output link has been registered.
    // Pass the path through the environment instead of interpolating Nix code.
    command
        .args([
            "build",
            "--impure",
            "--expr",
            r#"builtins.path {
                path = builtins.getEnv "FLEET_DEPLOY_SOURCE";
                name = "fleet-deploy-source";
            }"#,
        ])
        .env("FLEET_DEPLOY_SOURCE", source);
    command
}

pub(super) fn build(command: &mut Command, root: &Path, description: &str) -> Result<PathBuf> {
    let parent = root.parent().context("deployment root has no parent")?;
    fs::create_dir_all(parent).with_context(|| {
        format!(
            "failed to create deployment root directory {}",
            parent.display()
        )
    })?;
    let output = command
        .arg("--out-link")
        .arg(root)
        .args(["--print-build-logs", "--print-out-paths"])
        .stderr(Stdio::inherit())
        .output()
        .with_context(|| format!("failed to start {description}"))?;
    if !output.status.success() {
        bail!("{description} exited with {}", output.status);
    }
    super::system_backend::parse_store_path(&output.stdout, description)
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Store {
        directory: tempfile::TempDir,
        root: PathBuf,
        source: PathBuf,
    }

    impl Store {
        fn new() -> Self {
            let directory = tempfile::tempdir().unwrap();
            let root = directory.path().join("state/source");
            let source = directory.path().join("source with spaces ${literal}");
            fs::create_dir(&source).unwrap();
            Self {
                directory,
                root,
                source,
            }
        }

        fn command(&self) -> Command {
            let mut command = Command::new(env!("DEPLOY_NIX"));
            self.configure(&mut command);
            command
        }

        fn configure(&self, command: &mut Command) {
            command
                .arg("--store")
                .arg(self.directory.path().join("store"))
                .env(
                    "NIX_CONFIG",
                    "experimental-features = nix-command flakes\nsubstituters =\nbuilders =\n",
                );
        }

        fn import(&self, content: &str) -> PathBuf {
            fs::write(self.source.join("content"), content).unwrap();
            let mut command = source_command(Path::new(env!("DEPLOY_NIX")), &self.source);
            self.configure(&mut command);
            build(&mut command, &self.root, "test source import").unwrap()
        }

        fn collect(&self) {
            let output = self.command().args(["store", "gc"]).output().unwrap();
            assert!(
                output.status.success(),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
        }

        fn contains(&self, path: &Path) -> bool {
            // A relocated store uses /nix/store in logical paths and symlinks.
            self.directory
                .path()
                .join("store")
                .join(path.strip_prefix("/").unwrap())
                .exists()
        }
    }

    #[test]
    fn source_survives_gc_until_its_output_link_is_replaced() {
        let store = Store::new();
        let first = store.import("first revision");
        store.collect();
        assert!(store.contains(&first));
        assert_eq!(fs::read_link(&store.root).unwrap(), first);

        let second = store.import("second revision");
        store.collect();
        assert!(store.contains(&second));
        assert!(!store.contains(&first));
        assert_eq!(fs::read_link(&store.root).unwrap(), second);

        fs::remove_file(&store.root).unwrap();
        store.collect();
        assert!(!store.contains(&second));
    }

    #[test]
    fn failed_build_preserves_the_previous_root() {
        let store = Store::new();
        let previous = store.import("previous revision");
        let error = build(
            store
                .command()
                .args(["build", "--expr", "throw \"intentional failure\""]),
            &store.root,
            "test failed build",
        )
        .unwrap_err();

        assert!(error.to_string().contains("test failed build exited"));
        store.collect();
        assert!(store.contains(&previous));
        assert_eq!(fs::read_link(&store.root).unwrap(), previous);
    }
}
