use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::io::Write;
use std::path::PathBuf;
use std::time::Instant;

use anyhow::{anyhow, bail, Result};

use crate::deploy_remote::DeployAction;
use crate::HostInventory;

use super::{
    ActivationRequest, Backend, DeployArgs, DeploymentTarget, DiskoRequest, HostKind,
    SourceSelection, SystemBackend,
};

pub(super) const REPO_URL: &str = env!("DEPLOY_REPO_URL");

pub fn run(
    arguments: DeployArgs,
    inventory: &HostInventory,
    backend: &mut SystemBackend,
    output: &mut impl Write,
) -> Result<bool> {
    run_with_backend(arguments, inventory, backend, output)
}

pub(super) fn run_with_backend(
    arguments: DeployArgs,
    inventory: &HostInventory,
    backend: &mut impl Backend,
    output: &mut impl Write,
) -> Result<bool> {
    if let Some(values) = &arguments.disko {
        let [host, device] = values.as_slice() else {
            bail!("--disko requires HOST and DEVICE");
        };
        backend.disko(&DiskoRequest {
            device: device.clone(),
            host: host.clone(),
        })?;
        return Ok(true);
    }

    let selected = select_targets(&arguments, inventory, backend)?;
    if arguments.dry_run {
        writeln!(
            output,
            "Dry run: would update {}.",
            display_names(&selected)
        )?;
        return Ok(true);
    }
    if !backend.terminal_available() {
        bail!("no TTY available for sudo; run deploy from a real terminal");
    }

    backend.ensure_local_space(20, 5)?;
    let source_selection = if arguments.local {
        SourceSelection::Local
    } else {
        SourceSelection::Remote {
            branch: arguments.branch.unwrap_or_else(|| "master".to_owned()),
            merge_master: !arguments.no_merge,
            url: REPO_URL.to_owned(),
        }
    };
    let source = backend.stage_source(&source_selection, &env::current_dir()?)?;
    let action = if arguments.boot {
        DeployAction::Boot
    } else if arguments.test {
        DeployAction::DryActivate
    } else {
        DeployAction::Switch
    };
    let local_hostname = backend.hostname()?;
    let started = Instant::now();
    let mut helpers: BTreeMap<String, PathBuf> = BTreeMap::new();
    let mut failed_platforms: BTreeMap<String, String> = BTreeMap::new();
    let mut succeeded = Vec::new();
    let mut failed = Vec::new();

    for target in &selected {
        writeln!(output, "\x1b[1;36m==> {}\x1b[0m", target.host.display_name)?;
        if target.kind == HostKind::Darwin && action != DeployAction::Switch {
            eprintln!(
                "{}: Darwin supports only --switch deployments",
                target.host.display_name
            );
            failed.push(target.clone());
            continue;
        }
        if let Some(error) = failed_platforms.get(&target.host.platform) {
            eprintln!("{}: {error}", target.host.display_name);
            failed.push(target.clone());
            continue;
        }
        let helper = if let Some(helper) = helpers.get(&target.host.platform) {
            helper.clone()
        } else {
            match backend.build_helper(&source.store_path, &target.host.platform) {
                Ok(helper) => {
                    helpers.insert(target.host.platform.clone(), helper.clone());
                    helper
                }
                Err(error) => {
                    let message = format!(
                        "failed to build {} deploy helper: {error:#}",
                        target.host.platform
                    );
                    failed_platforms.insert(target.host.platform.clone(), message.clone());
                    eprintln!("{}: {message}", target.host.display_name);
                    failed.push(target.clone());
                    continue;
                }
            }
        };
        let request = ActivationRequest {
            action,
            config_name: target.config_name.clone(),
            expected_runtime_host: target.host.runtime_host.clone(),
            no_inhibit: arguments.no_inhibit,
        };
        let result = if target.host.runtime_host == local_hostname {
            backend.activate_local(&helper, &source.store_path, &request)
        } else {
            backend.activate_remote(target, &helper, &source.store_path, &request)
        };
        match result {
            Ok(()) => succeeded.push(target.clone()),
            Err(error) => {
                eprintln!("{}: {error:#}", target.host.display_name);
                failed.push(target.clone());
            }
        }
    }

    let elapsed = started.elapsed().as_secs();
    let duration = format!("{}m {}s", elapsed / 60, elapsed % 60);
    if failed.is_empty() {
        writeln!(
            output,
            "\n\x1b[1;32mUpdate complete: {}/{} succeeded in {duration}\x1b[0m",
            succeeded.len(),
            selected.len()
        )?;
        Ok(true)
    } else {
        writeln!(
            output,
            "\n\x1b[1;31mUpdate failed: {}/{} succeeded in {duration}, {} failed; Failed hosts: {}\x1b[0m",
            succeeded.len(),
            selected.len(),
            failed.len(),
            display_names(&failed)
        )?;
        Ok(false)
    }
}

fn select_targets(
    arguments: &DeployArgs,
    inventory: &HostInventory,
    backend: &mut impl Backend,
) -> Result<Vec<DeploymentTarget>> {
    let discovered = arguments.all || (arguments.select && arguments.hosts.is_empty());
    let mut names = if discovered {
        all_host_names(inventory)
    } else if arguments.hosts.is_empty() {
        vec![backend.hostname()?]
    } else {
        arguments.hosts.clone()
    };
    if discovered && !arguments.both {
        let include_work = arguments.work;
        names.retain(|name| {
            find_target(inventory, name).is_ok_and(|target| target.host.is_work == include_work)
        });
    }
    if names.is_empty() {
        let mode = if arguments.work { "work" } else { "personal" };
        bail!("no hosts selected after applying mode '{mode}'");
    }
    if arguments.select {
        names.sort();
        names = backend.select(&names)?;
    }
    names
        .iter()
        .map(|name| find_target(inventory, name))
        .collect()
}

fn find_target(inventory: &HostInventory, requested: &str) -> Result<DeploymentTarget> {
    let canonical = inventory
        .aliases
        .get(requested)
        .ok_or_else(|| anyhow!("unknown host: {requested}"))?;
    if let Some(host) = inventory.nixos.get(canonical) {
        return Ok(DeploymentTarget {
            config_name: canonical.clone(),
            host: host.clone(),
            kind: HostKind::Nixos,
        });
    }
    if let Some(host) = inventory.darwin.get(canonical) {
        return Ok(DeploymentTarget {
            config_name: canonical.clone(),
            host: host.clone(),
            kind: HostKind::Darwin,
        });
    }
    bail!("inventory alias {requested} points to missing host {canonical}")
}

fn all_host_names(inventory: &HostInventory) -> Vec<String> {
    inventory
        .nixos
        .keys()
        .chain(inventory.darwin.keys())
        .cloned()
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect()
}

fn display_names(targets: &[DeploymentTarget]) -> String {
    targets
        .iter()
        .map(|target| target.host.display_name.as_str())
        .collect::<Vec<_>>()
        .join(", ")
}
