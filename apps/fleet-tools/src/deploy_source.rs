use std::fs;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{symlink, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;

use anyhow::{anyhow, bail, Context, Result};
use gix::bstr::ByteSlice;
use gix::object::tree::EntryKind;
use tempfile::TempDir;

pub enum SourceRequest<'a> {
    Local {
        start: &'a Path,
    },
    Remote {
        branch: &'a str,
        merge_master: bool,
        url: &'a str,
    },
}

pub struct PreparedSource {
    _workspace: TempDir,
    revision: String,
    root: PathBuf,
}

impl PreparedSource {
    pub fn revision(&self) -> &str {
        &self.revision
    }

    pub fn root(&self) -> &Path {
        &self.root
    }
}

pub fn prepare_source(request: SourceRequest<'_>) -> Result<PreparedSource> {
    match request {
        SourceRequest::Local { start } => prepare_local(start),
        SourceRequest::Remote {
            branch,
            merge_master,
            url,
        } => prepare_remote(url, branch, merge_master),
    }
}

fn prepare_local(start: &Path) -> Result<PreparedSource> {
    let repository = gix::discover(start).map_err(|_| {
        anyhow!(
            "--local must be run from inside a Git checkout: {}",
            start.display()
        )
    })?;
    let commit = repository
        .head_commit()
        .context("failed to resolve the committed HEAD for --local")?;
    let revision = commit.id().to_string();
    let tree_id = commit.tree()?.id;
    prepare_tree(&repository, tree_id, revision)
}

fn prepare_remote(url: &str, branch: &str, merge_master: bool) -> Result<PreparedSource> {
    let workspace = tempfile::tempdir().context("failed to create deployment workspace")?;
    let repository_path = workspace.path().join("repository.git");
    // Keep the clone bare and its configuration isolated. Loading the user's
    // Git configuration could make gix invoke configured credential or filter
    // helpers, while a checkout would be mutable state we immediately have to
    // discard after an optional in-process merge. Materializing the resulting
    // object tree below keeps deployment input committed and reproducible.
    let mut clone = gix::clone::PrepareFetch::new(
        url,
        &repository_path,
        gix::create::Kind::Bare,
        gix::create::Options::default(),
        gix::open::Options::isolated(),
    )
    .with_context(|| format!("failed to prepare clone from {url}"))?
    .with_ref_name(Some(branch))
    .with_context(|| format!("invalid deployment branch: {branch}"))?;
    let interrupted = AtomicBool::new(false);
    let (repository, _) = clone
        .fetch_only(gix::progress::Discard, &interrupted)
        .with_context(|| format!("failed to clone branch {branch} from {url}"))?;
    let branch_commit = repository
        .head_commit()
        .with_context(|| format!("failed to resolve cloned branch {branch}"))?;
    let revision = branch_commit.id().to_string();
    let tree_id = if merge_master {
        let master = resolve_master(&repository)?;
        merge_tree(&repository, branch_commit.id, master.id)?
    } else {
        branch_commit.tree()?.id
    };

    let root = workspace.path().join("source");
    materialize_tree(&repository.find_tree(tree_id)?, &root)?;
    validate_flake_root(&root)?;
    Ok(PreparedSource {
        _workspace: workspace,
        revision,
        root,
    })
}

fn prepare_tree(
    repository: &gix::Repository,
    tree_id: gix::ObjectId,
    revision: String,
) -> Result<PreparedSource> {
    let workspace = tempfile::tempdir().context("failed to create deployment workspace")?;
    let root = workspace.path().join("source");
    materialize_tree(&repository.find_tree(tree_id)?, &root)?;
    validate_flake_root(&root)?;
    Ok(PreparedSource {
        _workspace: workspace,
        revision,
        root,
    })
}

fn resolve_master(repository: &gix::Repository) -> Result<gix::Commit<'_>> {
    ["refs/remotes/origin/master", "refs/heads/master", "master"]
        .into_iter()
        .find_map(|reference| {
            repository
                .rev_parse_single(reference)
                .ok()?
                .object()
                .ok()?
                .peel_to_commit()
                .ok()
        })
        .context("cloned repository does not contain origin/master")
}

fn merge_tree(
    repository: &gix::Repository,
    branch: gix::ObjectId,
    master: gix::ObjectId,
) -> Result<gix::ObjectId> {
    let merge_base = repository
        .merge_base(branch, master)
        .context("failed to find the merge base with origin/master")?
        .detach();
    if merge_base == master {
        return Ok(repository.find_commit(branch)?.tree()?.id);
    }
    if merge_base == branch {
        return Ok(repository.find_commit(master)?.tree()?.id);
    }

    let labels = gix::merge::blob::builtin_driver::text::Labels {
        ancestor: None,
        current: Some("deployment branch".into()),
        other: Some("origin/master".into()),
    };
    let mut outcome = repository.merge_commits(
        branch,
        master,
        labels,
        repository.tree_merge_options()?.into(),
    )?;
    if outcome
        .tree_merge
        .has_unresolved_conflicts(gix::merge::tree::TreatAsUnresolved::default())
    {
        bail!("deployment branch conflicts with origin/master");
    }
    Ok(outcome.tree_merge.tree.write()?.detach())
}

fn materialize_tree(tree: &gix::Tree<'_>, destination: &Path) -> Result<()> {
    fs::create_dir_all(destination)
        .with_context(|| format!("failed to create {}", destination.display()))?;
    for entry in tree.iter() {
        let entry = entry.context("failed to decode Git tree entry")?;
        let name = entry.filename().as_bytes();
        if name == b"." || name == b".." || name.contains(&b'/') {
            bail!("unsafe Git tree entry name: {}", entry.filename());
        }
        let path = destination.join(std::ffi::OsStr::from_bytes(name));
        match entry.kind() {
            EntryKind::Tree => {
                materialize_tree(&entry.object()?.try_into_tree()?, &path)?;
            }
            EntryKind::Blob | EntryKind::BlobExecutable => {
                let blob = entry.object()?.try_into_blob()?;
                fs::write(&path, &blob.data)
                    .with_context(|| format!("failed to write {}", path.display()))?;
                let mode = if entry.kind() == EntryKind::BlobExecutable {
                    0o755
                } else {
                    0o644
                };
                fs::set_permissions(&path, fs::Permissions::from_mode(mode))?;
            }
            EntryKind::Link => {
                let blob = entry.object()?.try_into_blob()?;
                symlink(std::ffi::OsStr::from_bytes(&blob.data), &path)
                    .with_context(|| format!("failed to create symlink {}", path.display()))?;
            }
            EntryKind::Commit => {
                bail!(
                    "deployment source contains unsupported submodule {}",
                    path.display()
                );
            }
        }
    }
    Ok(())
}

fn validate_flake_root(root: &Path) -> Result<()> {
    if !root.join("flake.nix").is_file() {
        bail!("committed deployment source does not contain flake.nix");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;

    use gix::object::tree::EntryKind;

    use super::*;

    fn signature() -> gix::actor::SignatureRef<'static> {
        gix::actor::SignatureRef::from_bytes(b"Test User <test@example.invalid> 1700000000 +0000")
            .expect("valid signature")
    }

    fn tree(
        repository: &gix::Repository,
        base: Option<gix::ObjectId>,
        files: &[(&str, EntryKind, &[u8])],
    ) -> gix::ObjectId {
        let mut editor = repository
            .edit_tree(base.unwrap_or_else(|| repository.empty_tree().id))
            .expect("tree editor");
        for (path, kind, contents) in files {
            let blob = repository.write_blob(contents).expect("write blob");
            editor
                .upsert(*path, *kind, blob)
                .expect("insert tree entry");
        }
        editor.write().expect("write tree").detach()
    }

    fn commit(
        repository: &gix::Repository,
        reference: &str,
        message: &str,
        tree: gix::ObjectId,
        parents: impl IntoIterator<Item = gix::ObjectId>,
    ) -> gix::ObjectId {
        repository
            .commit_as(signature(), signature(), reference, message, tree, parents)
            .expect("write commit")
            .detach()
    }

    #[test]
    fn local_source_uses_committed_tree_and_preserves_git_modes() {
        let checkout = tempfile::tempdir().expect("temporary checkout");
        let repository = gix::init(checkout.path()).expect("initialize repository");
        let committed = tree(
            &repository,
            None,
            &[
                ("flake.nix", EntryKind::Blob, b"{}\n"),
                ("tracked", EntryKind::Blob, b"committed\n"),
                ("tool", EntryKind::BlobExecutable, b"#!/bin/sh\n"),
                ("link", EntryKind::Link, b"tracked"),
            ],
        );
        let head = commit(
            &repository,
            "HEAD",
            "initial",
            committed,
            std::iter::empty(),
        );
        fs::write(checkout.path().join("tracked"), "dirty\n").expect("dirty tracked file");
        fs::write(checkout.path().join("untracked"), "ignored\n").expect("untracked file");
        drop(repository);

        let prepared = prepare_source(SourceRequest::Local {
            start: checkout.path(),
        })
        .expect("prepare committed source");

        assert_eq!(prepared.revision(), head.to_string());
        assert_eq!(
            fs::read_to_string(prepared.root().join("tracked")).unwrap(),
            "committed\n"
        );
        assert!(!prepared.root().join("untracked").exists());
        assert_eq!(
            fs::read_link(prepared.root().join("link")).unwrap(),
            Path::new("tracked")
        );
        assert_eq!(
            fs::metadata(prepared.root().join("tool"))
                .unwrap()
                .permissions()
                .mode()
                & 0o111,
            0o111
        );
    }

    #[test]
    fn merge_tree_combines_diverged_branch_and_master() {
        let directory = tempfile::tempdir().expect("temporary repository");
        let repository = gix::init_bare(directory.path()).expect("initialize repository");
        let base_tree = tree(
            &repository,
            None,
            &[("flake.nix", EntryKind::Blob, b"{}\n")],
        );
        let base = commit(
            &repository,
            "refs/heads/base",
            "base",
            base_tree,
            std::iter::empty(),
        );
        let branch_tree = tree(
            &repository,
            Some(base_tree),
            &[("feature", EntryKind::Blob, b"feature\n")],
        );
        let branch = commit(
            &repository,
            "refs/heads/feature",
            "feature",
            branch_tree,
            [base],
        );
        let master_tree = tree(
            &repository,
            Some(base_tree),
            &[("master", EntryKind::Blob, b"master\n")],
        );
        let master = commit(
            &repository,
            "refs/heads/master",
            "master",
            master_tree,
            [base],
        );

        let merged = merge_tree(&repository, branch, master).expect("merge trees");
        let output = tempfile::tempdir().expect("materialized tree");
        materialize_tree(&repository.find_tree(merged).unwrap(), output.path())
            .expect("materialize merge");

        assert_eq!(
            fs::read_to_string(output.path().join("feature")).unwrap(),
            "feature\n"
        );
        assert_eq!(
            fs::read_to_string(output.path().join("master")).unwrap(),
            "master\n"
        );
    }
}
