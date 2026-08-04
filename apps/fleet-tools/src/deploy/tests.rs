use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use anyhow::{bail, Result};
use clap::Parser;

use crate::{Host, HostInventory};

use super::run_with_backend as run;
use super::*;

#[derive(Default)]
struct FakeBackend {
    activations: Vec<(String, ActivationRequest, bool)>,
    builds: Vec<String>,
    diskos: Vec<DiskoRequest>,
    ensure_calls: usize,
    fail_hosts: BTreeSet<String>,
    hostname: String,
    selected_candidates: Vec<String>,
    selection: Vec<String>,
    selection_canceled: bool,
    source_requests: Vec<SourceSelection>,
    stage_calls: usize,
    terminal: bool,
}

impl Backend for FakeBackend {
    fn activate_local(
        &mut self,
        _helper: &Path,
        _source: &Path,
        request: &ActivationRequest,
    ) -> Result<()> {
        self.activations
            .push((request.config_name.clone(), request.clone(), true));
        if self.fail_hosts.contains(&request.config_name) {
            bail!("injected activation failure");
        }
        Ok(())
    }

    fn activate_remote(
        &mut self,
        _target: &DeploymentTarget,
        _helper: &Path,
        _source: &Path,
        request: &ActivationRequest,
    ) -> Result<()> {
        self.activations
            .push((request.config_name.clone(), request.clone(), false));
        if self.fail_hosts.contains(&request.config_name) {
            bail!("injected activation failure");
        }
        Ok(())
    }

    fn build_helper(&mut self, _source: &Path, platform: &str) -> Result<PathBuf> {
        self.builds.push(platform.to_owned());
        Ok(PathBuf::from(format!("/nix/store/helper-{platform}")))
    }

    fn disko(&mut self, request: &DiskoRequest) -> Result<()> {
        self.diskos.push(request.clone());
        Ok(())
    }

    fn ensure_local_space(&mut self, _min_free_gib: u64, _gc_headroom_gib: u64) -> Result<()> {
        self.ensure_calls += 1;
        Ok(())
    }

    fn hostname(&self) -> Result<String> {
        Ok(self.hostname.clone())
    }

    fn select(&mut self, candidates: &[String]) -> Result<Vec<String>> {
        self.selected_candidates = candidates.to_vec();
        if self.selection_canceled {
            bail!("selection canceled");
        }
        Ok(self.selection.clone())
    }

    fn stage_source(&mut self, source: &SourceSelection, _cwd: &Path) -> Result<StagedSource> {
        self.stage_calls += 1;
        self.source_requests.push(source.clone());
        Ok(StagedSource {
            revision: "deadbeef".to_owned(),
            store_path: "/nix/store/source".into(),
        })
    }

    fn terminal_available(&self) -> bool {
        self.terminal
    }
}

fn host(name: &str, platform: &str, runtime: &str, is_work: bool) -> Host {
    Host {
        display_name: name.to_owned(),
        is_work,
        platform: platform.to_owned(),
        runtime_host: runtime.to_owned(),
        ssh_host: name.to_owned(),
    }
}

fn inventory() -> HostInventory {
    HostInventory {
        aliases: BTreeMap::from([
            ("alpha".to_owned(), "alpha".to_owned()),
            ("alpha-alias".to_owned(), "alpha".to_owned()),
            ("beta".to_owned(), "beta".to_owned()),
            ("controller".to_owned(), "controller".to_owned()),
            ("mair".to_owned(), "mair".to_owned()),
            ("work".to_owned(), "work".to_owned()),
        ]),
        darwin: BTreeMap::from([(
            "mair".to_owned(),
            host("mair", "aarch64-darwin", "mair", false),
        )]),
        lan_dns_server: "192.0.2.53".to_owned(),
        lan_domain: "example.test".to_owned(),
        nixos: BTreeMap::from([
            (
                "alpha".to_owned(),
                host("alpha", "x86_64-linux", "alpha", false),
            ),
            (
                "beta".to_owned(),
                host("beta", "x86_64-linux", "beta", false),
            ),
            (
                "controller".to_owned(),
                host("controller", "x86_64-linux", "controller", false),
            ),
            (
                "work".to_owned(),
                host("work", "x86_64-linux", "work", true),
            ),
        ]),
    }
}

fn args(values: &[&str]) -> DeployArgs {
    DeployArgs::try_parse_from(std::iter::once("deploy").chain(values.iter().copied()))
        .expect("valid deploy arguments")
}

#[test]
fn clap_rejects_conflicting_source_and_host_discovery_options() {
    assert!(DeployArgs::try_parse_from(["deploy", "--local", "--branch", "feature"]).is_err());
    assert!(DeployArgs::try_parse_from(["deploy", "--all", "alpha"]).is_err());
    assert!(DeployArgs::try_parse_from(["deploy", "--boot", "--test", "alpha"]).is_err());
}

#[test]
fn dry_run_defaults_to_current_host_without_side_effects() {
    let mut backend = FakeBackend {
        hostname: "controller".to_owned(),
        ..Default::default()
    };
    let mut output = Vec::new();

    assert!(run(
        args(&["--dry-run"]),
        &inventory(),
        &mut backend,
        &mut output
    )
    .unwrap());

    assert_eq!(
        String::from_utf8(output).unwrap(),
        "Dry run: would update controller.\n"
    );
    assert_eq!(backend.ensure_calls, 0);
    assert_eq!(backend.stage_calls, 0);
    assert!(backend.activations.is_empty());
}

#[test]
fn selector_receives_sorted_personal_hosts_and_accepts_multiple_results() {
    let mut backend = FakeBackend {
        hostname: "controller".to_owned(),
        selection: vec!["mair".to_owned(), "alpha".to_owned()],
        ..Default::default()
    };
    let mut output = Vec::new();

    assert!(run(
        args(&["--select", "--dry-run"]),
        &inventory(),
        &mut backend,
        &mut output,
    )
    .unwrap());

    assert_eq!(
        backend.selected_candidates,
        ["alpha", "beta", "controller", "mair"]
    );
    assert!(String::from_utf8(output).unwrap().contains("mair, alpha"));
}

#[test]
fn canceled_selection_stops_before_deployment_side_effects() {
    let mut backend = FakeBackend {
        hostname: "controller".to_owned(),
        selection_canceled: true,
        terminal: true,
        ..Default::default()
    };

    let error = run(
        args(&["--select"]),
        &inventory(),
        &mut backend,
        &mut Vec::new(),
    )
    .unwrap_err();

    assert!(error.to_string().contains("selection canceled"));
    assert_eq!(backend.ensure_calls, 0);
    assert_eq!(backend.stage_calls, 0);
    assert!(backend.activations.is_empty());
}

#[test]
fn explicit_aliases_skip_mode_filtering() {
    let mut backend = FakeBackend::default();
    let mut output = Vec::new();

    assert!(run(
        args(&["--work", "--dry-run", "alpha-alias"]),
        &inventory(),
        &mut backend,
        &mut output,
    )
    .unwrap());

    assert!(String::from_utf8(output).unwrap().contains("alpha"));
}

#[test]
fn deployment_stages_requested_source_and_caches_helpers_by_platform() {
    let mut backend = FakeBackend {
        hostname: "controller".to_owned(),
        terminal: true,
        ..Default::default()
    };
    let mut output = Vec::new();

    assert!(run(
        args(&[
            "--branch",
            "feature",
            "--no-merge",
            "--no-inhibit",
            "controller",
            "alpha",
            "mair"
        ]),
        &inventory(),
        &mut backend,
        &mut output,
    )
    .unwrap());

    assert_eq!(backend.ensure_calls, 1);
    assert_eq!(backend.stage_calls, 1);
    assert_eq!(
        backend.source_requests,
        [SourceSelection::Remote {
            branch: "feature".to_owned(),
            merge_master: false,
            url: REPO_URL.to_owned(),
        }]
    );
    assert_eq!(backend.builds, ["x86_64-linux", "aarch64-darwin"]);
    assert_eq!(backend.activations.len(), 3);
    assert!(backend.activations[0].2);
    assert!(!backend.activations[1].2);
    assert!(backend
        .activations
        .iter()
        .all(|(_, request, _)| request.no_inhibit));
}

#[test]
fn activation_failures_are_aggregated_after_all_hosts_are_attempted() {
    let mut backend = FakeBackend {
        fail_hosts: BTreeSet::from(["alpha".to_owned(), "beta".to_owned()]),
        hostname: "controller".to_owned(),
        terminal: true,
        ..Default::default()
    };
    let mut output = Vec::new();

    assert!(!run(
        args(&["--local", "alpha", "beta"]),
        &inventory(),
        &mut backend,
        &mut output,
    )
    .unwrap());

    assert_eq!(backend.activations.len(), 2);
    let output = String::from_utf8(output).unwrap();
    assert!(output.contains("Update failed: 0/2 succeeded"));
    assert!(output.contains("Failed hosts: alpha, beta"));
    assert_eq!(backend.source_requests, [SourceSelection::Local]);
}

#[test]
fn deployment_requires_a_terminal_before_staging_source() {
    let mut backend = FakeBackend {
        hostname: "controller".to_owned(),
        ..Default::default()
    };
    let error = run(
        args(&["controller"]),
        &inventory(),
        &mut backend,
        &mut Vec::new(),
    )
    .unwrap_err();

    assert!(error.to_string().contains("no TTY"));
    assert_eq!(backend.ensure_calls, 0);
    assert_eq!(backend.stage_calls, 0);
}

#[test]
fn disko_is_a_typed_separate_operation() {
    let mut backend = FakeBackend::default();

    assert!(run(
        args(&["--disko", "frame", "/dev/sda"]),
        &inventory(),
        &mut backend,
        &mut Vec::new(),
    )
    .unwrap());

    assert_eq!(
        backend.diskos,
        [DiskoRequest {
            device: "/dev/sda".to_owned(),
            host: "frame".to_owned(),
        }]
    );
    assert_eq!(backend.stage_calls, 0);
}

#[test]
fn proxy_detection_ignores_explicit_none_values() {
    assert!(!config_uses_proxy("proxyjump none\nproxycommand none\n"));
    assert!(config_uses_proxy("proxyjump bastion\nproxycommand none\n"));
}

#[test]
fn lan_dns_candidates_add_the_domain_only_to_bare_names() {
    assert_eq!(
        dns_candidates("alpha", "example.test"),
        ["alpha", "alpha.example.test"]
    );
    assert_eq!(
        dns_candidates("alpha.example.test", "example.test"),
        ["alpha.example.test"]
    );
    assert_eq!(dns_candidates("192.0.2.1", "example.test"), ["192.0.2.1"]);
}

#[test]
fn store_output_must_be_an_absolute_nix_store_path() {
    assert_eq!(
        parse_store_path(b"/nix/store/abc-source\n", "test").unwrap(),
        Path::new("/nix/store/abc-source")
    );
    assert!(parse_store_path(b"relative\n", "test").is_err());
}
