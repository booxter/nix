use std::path::{Path, PathBuf};

use anyhow::Result;
use clap::{ArgGroup, Parser};

use crate::deploy_remote::DeployAction;
use crate::Host;

#[derive(Debug, Parser)]
#[command(
    version,
    about = "Deploy committed fleet configurations to local or remote hosts",
    after_help = "GitHub branch deployments merge origin/master by default.\n\
                  SSH_OPTS may contain additional shell-quoted OpenSSH options.",
    group(ArgGroup::new("mode").args(["personal", "work", "both"])),
    group(ArgGroup::new("action").args(["switch", "boot", "test"]))
)]
pub struct DeployArgs {
    /// Deploy all hosts allowed by the selected fleet mode.
    #[arg(short = 'A', long, conflicts_with = "hosts")]
    pub all: bool,

    /// Interactively select multiple hosts with fzf.
    #[arg(long)]
    pub select: bool,

    /// Include only personal hosts during fleet discovery (default).
    #[arg(long)]
    pub personal: bool,

    /// Include only work hosts during fleet discovery.
    #[arg(long)]
    pub work: bool,

    /// Include personal and work hosts during fleet discovery.
    #[arg(long)]
    pub both: bool,

    /// Deploy this GitHub branch instead of master.
    #[arg(long, value_name = "BRANCH", conflicts_with = "local")]
    pub branch: Option<String>,

    /// Deploy committed HEAD from the current checkout.
    #[arg(long, conflicts_with = "branch")]
    pub local: bool,

    /// Do not merge origin/master into a GitHub branch deployment.
    #[arg(long)]
    pub no_merge: bool,

    /// Bypass NixOS pre-switch checks and switch inhibitors.
    #[arg(long)]
    pub no_inhibit: bool,

    /// Switch into the new configuration immediately (default).
    #[arg(long)]
    pub switch: bool,

    /// Stage the new NixOS configuration for the next boot.
    #[arg(long)]
    pub boot: bool,

    /// Build and dry-activate a NixOS configuration.
    #[arg(long)]
    pub test: bool,

    /// Print selected hosts without building, copying, or connecting.
    #[arg(long)]
    pub dry_run: bool,

    /// Provision HOST on DEVICE with the repository disko configuration.
    #[arg(
        long,
        num_args = 2,
        value_names = ["HOST", "DEVICE"],
        conflicts_with_all = [
            "all", "select", "personal", "work", "both", "branch", "local",
            "no_merge", "no_inhibit", "switch", "boot", "test", "dry_run", "hosts"
        ]
    )]
    pub disko: Option<Vec<String>>,

    /// Explicit inventory hosts to deploy.
    #[arg(value_name = "HOST", conflicts_with = "all")]
    pub hosts: Vec<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum HostKind {
    Darwin,
    Nixos,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct DeploymentTarget {
    pub config_name: String,
    pub host: Host,
    pub kind: HostKind,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) enum SourceSelection {
    Local,
    Remote {
        branch: String,
        merge_master: bool,
        url: String,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct StagedSource {
    pub revision: String,
    pub store_path: PathBuf,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct ActivationRequest {
    pub action: DeployAction,
    pub config_name: String,
    pub expected_runtime_host: String,
    pub no_inhibit: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct DiskoRequest {
    pub device: String,
    pub host: String,
}

pub(super) trait Backend {
    fn activate_local(
        &mut self,
        helper: &Path,
        source: &Path,
        request: &ActivationRequest,
    ) -> Result<()>;
    fn activate_remote(
        &mut self,
        target: &DeploymentTarget,
        source: &Path,
        request: &ActivationRequest,
    ) -> Result<()>;
    fn build_helper(&mut self, source: &Path, platform: &str) -> Result<PathBuf>;
    fn disko(&mut self, request: &DiskoRequest) -> Result<()>;
    fn ensure_local_space(&mut self, min_free_gib: u64, gc_headroom_gib: u64) -> Result<()>;
    fn hostname(&self) -> Result<String>;
    fn select(&mut self, candidates: &[String]) -> Result<Vec<String>>;
    fn stage_source(&mut self, source: &SourceSelection, cwd: &Path) -> Result<StagedSource>;
    fn terminal_available(&self) -> bool;
}
