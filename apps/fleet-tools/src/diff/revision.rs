use std::env;
use std::path::{Path, PathBuf};

use anyhow::{anyhow, bail, Context, Result};

use super::TargetKind;

pub(super) struct GitCheckout {
    repository: gix::Repository,
    root: PathBuf,
}

impl GitCheckout {
    pub(super) fn discover(explicit_root: Option<&Path>) -> Result<Self> {
        let start = explicit_root
            .map(Path::to_path_buf)
            .unwrap_or(env::current_dir().context("Unable to read the current directory")?);
        let root = if explicit_root.is_some() {
            start
                .canonicalize()
                .with_context(|| format!("Unable to access repo root: {}", start.display()))?
        } else {
            let repository = gix::discover(&start).map_err(|_| {
                anyhow!(
                    "Unable to find a Git checkout; run from the flake repo or set DIFF_CONFIG_REPO_ROOT."
                )
            })?;
            repository
                .workdir()
                .context("The discovered Git repository has no working tree")?
                .canonicalize()
                .context("Unable to access the discovered repo root")?
        };
        let repository = gix::discover(&root)
            .with_context(|| format!("Unable to open Git repository at {}", root.display()))?;

        if !root.join("flake.nix").is_file() {
            bail!("Repo root does not contain flake.nix: {}", root.display());
        }

        Ok(Self { repository, root })
    }

    pub(super) fn resolve_revision(&self, label: &str, revision: &str) -> Result<String> {
        let commit = self
            .repository
            .rev_parse_single(revision)
            .ok()
            .and_then(|id| id.object().ok())
            .and_then(|object| object.peel_to_commit().ok())
            .ok_or_else(|| {
                anyhow!(
                    "Unable to resolve {label} revision '{revision}' in {}.",
                    self.root.display()
                )
            })?;
        Ok(commit.id().to_string())
    }

    pub(super) fn flake_ref(&self, revision: &str) -> String {
        format!("git+file://{}?rev={revision}", self.root.display())
    }
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub(super) enum RevisionSide {
    Old,
    New,
}

impl RevisionSide {
    pub(super) fn label(self) -> &'static str {
        match self {
            Self::Old => "old",
            Self::New => "new",
        }
    }
}

#[derive(Clone, Debug)]
pub(super) struct Revision {
    pub(super) side: RevisionSide,
    pub(super) id: String,
    pub(super) flake_ref: String,
    pub(super) machine: String,
}

impl Revision {
    pub(super) fn environment(&self, kind: TargetKind) -> [(&'static str, &str); 3] {
        [
            ("DIFF_FLAKE_REF", &self.flake_ref),
            ("DIFF_MACHINE", &self.machine),
            ("DIFF_TARGET_KIND", kind.as_str()),
        ]
    }
}
