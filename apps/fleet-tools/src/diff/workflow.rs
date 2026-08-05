use std::collections::BTreeMap;
use std::env;
use std::io::{self, IsTerminal, Write};
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use tempfile::TempDir;

use crate::HostInventory;

use super::{
    filter_dix_output, run_detail_diff, DiffBackend, DiffOptions, GeneratedPath, GitCheckout,
    NativeBackend, Revision, RevisionSide, TargetKind, TargetRequest,
};

const TARGET_ALIASES_JSON: &str = env!("DIFF_TARGET_ALIASES_JSON");

struct BuildWorkspace {
    directory: Option<TempDir>,
    keep: bool,
}

impl BuildWorkspace {
    fn new() -> Result<Self> {
        Ok(Self {
            directory: Some(tempfile::Builder::new().prefix("diff-config.").tempdir()?),
            keep: env::var("DIFF_CONFIG_KEEP_TMP").is_ok_and(|value| value == "1"),
        })
    }

    fn path(&self) -> &Path {
        self.directory
            .as_ref()
            .expect("workspace is present")
            .path()
    }
}

impl Drop for BuildWorkspace {
    fn drop(&mut self) {
        if self.keep {
            if let Some(directory) = self.directory.take() {
                let path = directory.keep();
                eprintln!("Keeping temporary output links in {}", path.display());
            }
        }
    }
}

pub fn execute(options: &DiffOptions) -> Result<()> {
    let explicit_root = env::var_os("DIFF_CONFIG_REPO_ROOT").map(PathBuf::from);
    let checkout = GitCheckout::discover(explicit_root.as_deref())?;
    let backend = NativeBackend;
    run_with_backend(
        options,
        &checkout,
        &backend,
        &mut io::stdout().lock(),
        &mut io::stderr().lock(),
    )
}

pub(super) fn run_with_backend(
    options: &DiffOptions,
    checkout: &GitCheckout,
    backend: &impl DiffBackend,
    stdout: &mut impl Write,
    stderr: &mut impl Write,
) -> Result<()> {
    let mut target = options.target.clone();
    resolve_known_target(&mut target)?;

    let old_id = checkout.resolve_revision("old", &options.old_revision)?;
    let new_id = checkout.resolve_revision("new", &options.new_revision)?;
    let old = Revision {
        side: RevisionSide::Old,
        flake_ref: checkout.flake_ref(&old_id),
        id: old_id,
        machine: target.machine.clone(),
    };
    let new = Revision {
        side: RevisionSide::New,
        flake_ref: checkout.flake_ref(&new_id),
        id: new_id,
        machine: target.machine.clone(),
    };

    let old_kind = matching_kind(backend.detect_target(&old)?, target.explicit_kind);
    let new_kind = matching_kind(backend.detect_target(&new)?, target.explicit_kind);
    let kind = match (old_kind, new_kind) {
        (None, Some(_)) => {
            writeln!(
                stdout,
                "Machine '{}' is present only in the new revision; no old configuration exists to diff.",
                target.machine
            )?;
            return Ok(());
        }
        (Some(_), None) => {
            writeln!(
                stdout,
                "Machine '{}' is present only in the old revision; no new configuration exists to diff.",
                target.machine
            )?;
            return Ok(());
        }
        (None, None) => bail!("Machine '{}' must exist in at least one revision.", target.machine),
        (Some(old_kind), Some(new_kind)) if old_kind != new_kind => bail!(
            "Machine '{}' changed configuration kind between revisions.\nold revision: {old_kind}; new revision: {new_kind}",
            target.machine
        ),
        (Some(kind), Some(_)) => kind,
    };

    let generated_paths = if options.details {
        if options.generated_paths.is_empty() {
            default_generated_paths(kind)
        } else {
            options.generated_paths.clone()
        }
    } else {
        Vec::new()
    };

    let workspace = BuildWorkspace::new()?;
    let old_link = workspace.path().join("old");
    let new_link = workspace.path().join("new");
    build_revision(backend, kind, &old, &old_link, stderr)?;
    build_revision(backend, kind, &new, &new_link, stderr)?;

    writeln!(
        stderr,
        "Diffing {kind} configuration {}: {} -> {}",
        target.machine, old.id, new.id
    )?;
    let dix_color = env::var("DIFF_CONFIG_DIX_COLOR").unwrap_or_else(|_| {
        if io::stdout().is_terminal() {
            "always".to_owned()
        } else {
            "auto".to_owned()
        }
    });
    stdout.write_all(
        filter_dix_output(&backend.package_diff(&old_link, &new_link, &dix_color)?).as_bytes(),
    )?;

    if options.details {
        let color = env::var("DIFF_CONFIG_DIFF_COLOR")
            .ok()
            .or_else(|| io::stdout().is_terminal().then(|| "always".to_owned()));
        run_detail_diff(
            backend,
            kind,
            &old,
            &new,
            &old_link,
            &new_link,
            &generated_paths,
            workspace.path(),
            color.as_deref(),
            stdout,
            stderr,
        )?;
    }
    Ok(())
}

fn matching_kind(found: Option<TargetKind>, requested: Option<TargetKind>) -> Option<TargetKind> {
    found.filter(|kind| requested.is_none_or(|requested| requested == *kind))
}

fn resolve_known_target(target: &mut TargetRequest) -> Result<()> {
    let inventory = crate::compiled_inventory().context("Compiled fleet inventory is invalid")?;
    let aliases: BTreeMap<String, String> =
        serde_json::from_str(TARGET_ALIASES_JSON).context("Compiled target aliases are invalid")?;
    if !known_machine(&inventory, &aliases, &target.machine) {
        bail!("Unknown machine: {}", target.machine);
    }
    if target.explicit_kind != Some(TargetKind::Darwin) {
        if let Some(resolved) = aliases.get(&target.machine) {
            target.machine.clone_from(resolved);
        }
    }
    Ok(())
}

fn known_machine(
    inventory: &HostInventory,
    aliases: &BTreeMap<String, String>,
    machine: &str,
) -> bool {
    inventory.darwin.contains_key(machine)
        || inventory.nixos.contains_key(machine)
        || aliases.contains_key(machine)
}

fn build_revision(
    backend: &impl DiffBackend,
    kind: TargetKind,
    revision: &Revision,
    out_link: &Path,
    stderr: &mut impl Write,
) -> Result<()> {
    writeln!(
        stderr,
        "Building {kind} configuration {} at {} ({})",
        revision.machine,
        revision.side.label(),
        revision.id
    )?;
    backend.build_toplevel(kind, revision, out_link)
}

fn default_generated_paths(kind: TargetKind) -> Vec<GeneratedPath> {
    let paths: &[&str] = match kind {
        TargetKind::Nixos => &["etc"],
        TargetKind::Darwin => &[
            "etc",
            "Library/LaunchAgents",
            "Library/LaunchDaemons",
            "user/Library/LaunchAgents",
        ],
    };
    paths
        .iter()
        .map(|path| path.parse().expect("default paths are valid"))
        .collect()
}
