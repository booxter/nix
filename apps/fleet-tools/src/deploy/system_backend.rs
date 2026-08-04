use std::env;
use std::io::{self, IsTerminal, Write};
use std::net::Ipv4Addr;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

use anyhow::{bail, Context, Result};
use rustix::fs::statvfs;
use rustix::process::getuid;
use rustix::system::uname;

use crate::deploy_remote::DeployAction;
use crate::deploy_source::{prepare_source, SourceRequest};
use crate::HostInventory;

use super::{
    ActivationRequest, Backend, DeploymentTarget, DiskoRequest, SourceSelection, StagedSource,
};

const DIG: &str = env!("DEPLOY_DIG");
const FZF: &str = env!("DEPLOY_FZF");
const NIX: &str = env!("DEPLOY_NIX");
const NIX_COLLECT_GARBAGE: &str = env!("DEPLOY_NIX_COLLECT_GARBAGE");
const REPO_ROOT: &str = env!("DEPLOY_REPO_ROOT");
const SSH: &str = env!("DEPLOY_SSH");
const GIB: u64 = 1024 * 1024 * 1024;

#[cfg(target_os = "macos")]
const SUDO: &str = "/usr/bin/sudo";
#[cfg(target_os = "linux")]
const SUDO: &str = "/run/wrappers/bin/sudo";

pub struct SystemBackend {
    dig: PathBuf,
    fzf: PathBuf,
    lan_dns_server: String,
    lan_domain: String,
    nix: PathBuf,
    nix_collect_garbage: PathBuf,
    ssh: PathBuf,
    ssh_options: Vec<String>,
}

impl SystemBackend {
    pub fn from_environment(inventory: &HostInventory) -> Result<Self> {
        let ssh_options = env::var("SSH_OPTS")
            .ok()
            .map(|value| shell_words::split(&value).context("SSH_OPTS contains invalid quoting"))
            .transpose()?
            .unwrap_or_default();
        Ok(Self {
            dig: DIG.into(),
            fzf: FZF.into(),
            lan_dns_server: inventory.lan_dns_server.clone(),
            lan_domain: inventory.lan_domain.clone(),
            nix: NIX.into(),
            nix_collect_garbage: NIX_COLLECT_GARBAGE.into(),
            ssh: SSH.into(),
            ssh_options,
        })
    }

    fn checked_output(&self, command: &mut Command, description: &str) -> Result<Output> {
        let output = command
            .output()
            .with_context(|| format!("failed to start {description}"))?;
        if !output.status.success() {
            bail!("{description} exited with {}", output.status);
        }
        Ok(output)
    }

    fn checked_status(&self, command: &mut Command, description: &str) -> Result<()> {
        let status = command
            .status()
            .with_context(|| format!("failed to start {description}"))?;
        if !status.success() {
            bail!("{description} exited with {status}");
        }
        Ok(())
    }

    fn run_privileged(
        &self,
        program: &Path,
        arguments: &[String],
        description: &str,
    ) -> Result<()> {
        if getuid().as_raw() == 0 {
            self.checked_status(Command::new(program).args(arguments), description)
        } else {
            let mut command = Command::new(SUDO);
            command.arg(program).args(arguments);
            self.checked_status(&mut command, description)
        }
    }

    fn resolve_connection(&self, target: &DeploymentTarget) -> Result<SshConnection> {
        let mut destination = target.host.ssh_host.clone();
        if target.host.is_work && is_bare_hostname(&destination) {
            destination.push_str(".local");
        }

        let mut ssh_config = Command::new(&self.ssh);
        ssh_config
            .arg("-G")
            .args(&self.ssh_options)
            .arg(&destination);
        let has_proxy = ssh_config
            .output()
            .ok()
            .filter(|output| output.status.success())
            .and_then(|output| String::from_utf8(output.stdout).ok())
            .is_some_and(|config| config_uses_proxy(&config));
        let mut resolved_options = Vec::new();
        if !has_proxy {
            for candidate in dns_candidates(&destination, &self.lan_domain) {
                let server = format!("@{}", self.lan_dns_server);
                let mut command = Command::new(&self.dig);
                command.args(["+short", "+time=1", "+tries=1", &server, &candidate, "A"]);
                let Ok(output) = command.output() else {
                    break;
                };
                if !output.status.success() {
                    continue;
                }
                let Some(address) = String::from_utf8_lossy(&output.stdout)
                    .lines()
                    .find_map(|line| line.trim().parse::<Ipv4Addr>().ok())
                else {
                    continue;
                };
                resolved_options.extend([
                    "-o".to_owned(),
                    format!("HostName={address}"),
                    "-o".to_owned(),
                    format!("HostKeyAlias={destination}"),
                ]);
                break;
            }
        }
        Ok(SshConnection {
            destination,
            resolved_options,
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct SshConnection {
    destination: String,
    resolved_options: Vec<String>,
}

impl Backend for SystemBackend {
    fn activate_local(
        &mut self,
        helper: &Path,
        source: &Path,
        request: &ActivationRequest,
    ) -> Result<()> {
        let executable = helper.join("bin/fleet-deploy-remote");
        self.checked_status(
            Command::new(&executable).args(activation_arguments(source, request)),
            &format!("local activation for {}", request.config_name),
        )
    }

    fn activate_remote(
        &mut self,
        target: &DeploymentTarget,
        helper: &Path,
        source: &Path,
        request: &ActivationRequest,
    ) -> Result<()> {
        let connection = self.resolve_connection(target)?;
        let mut nix_ssh_options = self.ssh_options.clone();
        nix_ssh_options.extend(connection.resolved_options.clone());
        let mut copy = Command::new(&self.nix);
        copy.args([
            "copy",
            "--to",
            &format!("ssh-ng://{}", connection.destination),
        ])
        .arg(helper)
        .arg(source)
        .env("NIX_SSHOPTS", shell_words::join(&nix_ssh_options));
        self.checked_status(
            &mut copy,
            &format!("Nix copy to {}", target.host.display_name),
        )?;

        let mut remote_arguments =
            vec![helper.join("bin/fleet-deploy-remote").display().to_string()];
        remote_arguments.extend(activation_arguments(source, request));
        // OpenSSH's remote-command protocol is a shell string, not an argv
        // vector. Quote each typed argument here at that unavoidable boundary.
        let remote_command = shell_words::join(remote_arguments);
        let mut ssh = Command::new(&self.ssh);
        ssh.args(&self.ssh_options)
            .args(&connection.resolved_options)
            .arg("-tt")
            .arg(&connection.destination)
            .arg(remote_command);
        self.checked_status(
            &mut ssh,
            &format!("remote activation for {}", target.host.display_name),
        )
    }

    fn build_helper(&mut self, source: &Path, platform: &str) -> Result<PathBuf> {
        let attribute = format!(
            "{}#packages.{platform}.fleet-tools",
            source.to_string_lossy()
        );
        let output = self.checked_output(
            Command::new(&self.nix).args([
                "build",
                "--no-link",
                "--print-build-logs",
                "--print-out-paths",
                &attribute,
            ]),
            &format!("fleet deploy helper build for {platform}"),
        )?;
        parse_store_path(&output.stdout, "fleet deploy helper build")
    }

    fn disko(&mut self, request: &DiskoRequest) -> Result<()> {
        let repo = Path::new(REPO_ROOT);
        let arguments = vec![
            "--extra-experimental-features".to_owned(),
            "nix-command flakes".to_owned(),
            "run".to_owned(),
            "-L".to_owned(),
            "--show-trace".to_owned(),
            format!("{}#disko-install", repo.display()),
            "--".to_owned(),
            "--flake".to_owned(),
            format!("{}#{}", repo.display(), request.host),
            "--disk".to_owned(),
            "main".to_owned(),
            request.device.clone(),
        ];
        let nix = self.nix.clone();
        self.run_privileged(&nix, &arguments, "disko install")
    }

    fn ensure_local_space(&mut self, min_free_gib: u64, gc_headroom_gib: u64) -> Result<()> {
        let store = Path::new("/nix/store");
        let mut available = available_bytes(store)?;
        eprintln!(
            "Local available disk on {}: {:.1} GiB",
            store.display(),
            gib(available)
        );
        let minimum = min_free_gib.saturating_mul(GIB);
        if available >= minimum {
            return Ok(());
        }
        let target = minimum
            .saturating_sub(available)
            .saturating_add(gc_headroom_gib.saturating_mul(GIB));
        let bounded = vec![
            "-d".to_owned(),
            "--max-freed".to_owned(),
            format!("{}K", target / 1024),
        ];
        let collector = self.nix_collect_garbage.clone();
        self.run_privileged(&collector, &bounded, "bounded local Nix garbage collection")?;
        available = available_bytes(store)?;
        if available < minimum {
            self.run_privileged(
                &collector,
                &["-d".to_owned()],
                "full local Nix garbage collection",
            )?;
        }
        Ok(())
    }

    fn hostname(&self) -> Result<String> {
        let system = uname();
        let hostname = system.nodename().to_string_lossy();
        Ok(hostname.split('.').next().unwrap_or(&hostname).to_owned())
    }

    fn select(&mut self, candidates: &[String]) -> Result<Vec<String>> {
        if candidates.is_empty() {
            bail!("no hosts available for selection");
        }
        let mut child = Command::new(&self.fzf)
            .args(["--multi", "--layout=reverse", "--prompt=Deploy hosts> "])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .context("failed to start fzf host selector")?;
        let mut stdin = child.stdin.take().context("fzf stdin was not available")?;
        for candidate in candidates {
            writeln!(stdin, "{candidate}")?;
        }
        drop(stdin);
        let output = child
            .wait_with_output()
            .context("failed to wait for fzf host selector")?;
        if !output.status.success() {
            bail!("selection canceled");
        }
        let selected = String::from_utf8(output.stdout).context("fzf output is not UTF-8")?;
        let hosts = selected
            .lines()
            .filter(|line| !line.is_empty())
            .map(str::to_owned)
            .collect::<Vec<_>>();
        if hosts.is_empty() {
            bail!("no selection made");
        }
        Ok(hosts)
    }

    fn stage_source(&mut self, source: &SourceSelection, cwd: &Path) -> Result<StagedSource> {
        let prepared = match source {
            SourceSelection::Local => prepare_source(SourceRequest::Local { start: cwd })?,
            SourceSelection::Remote {
                branch,
                merge_master,
                url,
            } => prepare_source(SourceRequest::Remote {
                branch,
                merge_master: *merge_master,
                url,
            })?,
        };
        let revision = prepared.revision().to_owned();
        let output = self.checked_output(
            Command::new(&self.nix)
                .args(["store", "add-path", "--name", "fleet-deploy-source"])
                .arg(prepared.root()),
            "adding deployment source to the Nix store",
        )?;
        let store_path = parse_store_path(&output.stdout, "Nix store add-path")?;
        eprintln!(
            "Using committed deployment source {revision} at {}.",
            store_path.display()
        );
        Ok(StagedSource {
            revision,
            store_path,
        })
    }

    fn terminal_available(&self) -> bool {
        io::stdin().is_terminal() && io::stdout().is_terminal()
    }
}

fn activation_arguments(source: &Path, request: &ActivationRequest) -> Vec<String> {
    let action = match request.action {
        DeployAction::Switch => "switch",
        DeployAction::Boot => "boot",
        DeployAction::DryActivate => "dry-activate",
    };
    let mut arguments = vec![
        "deploy".to_owned(),
        "--action".to_owned(),
        action.to_owned(),
        "--config-name".to_owned(),
        request.config_name.clone(),
        "--expected-runtime-host".to_owned(),
        request.expected_runtime_host.clone(),
        "--gc-headroom-gib".to_owned(),
        "5".to_owned(),
        "--min-free-gib".to_owned(),
        "30".to_owned(),
        "--source".to_owned(),
        source.display().to_string(),
    ];
    if request.no_inhibit {
        arguments.push("--no-inhibit".to_owned());
    }
    arguments
}

pub(super) fn parse_store_path(stdout: &[u8], operation: &str) -> Result<PathBuf> {
    let output = String::from_utf8(stdout.to_vec())
        .with_context(|| format!("{operation} output is not UTF-8"))?;
    let path = output
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .context("Nix returned no store path")?;
    let path = PathBuf::from(path);
    if !path.is_absolute() || !path.starts_with("/nix/store") {
        bail!("{operation} returned a non-store path: {}", path.display());
    }
    Ok(path)
}

fn available_bytes(path: &Path) -> Result<u64> {
    let status = statvfs(path)
        .with_context(|| format!("failed to inspect free space on {}", path.display()))?;
    status
        .f_bavail
        .checked_mul(status.f_frsize)
        .context("available disk size overflowed u64")
}

fn gib(bytes: u64) -> f64 {
    bytes as f64 / GIB as f64
}

pub(super) fn config_uses_proxy(config: &str) -> bool {
    config.lines().any(|line| {
        let mut fields = line.split_whitespace();
        matches!(fields.next(), Some("proxyjump" | "proxycommand"))
            && fields.next().is_some_and(|value| value != "none")
    })
}

fn is_bare_hostname(host: &str) -> bool {
    !host.contains('.') && host.parse::<Ipv4Addr>().is_err()
}

pub(super) fn dns_candidates(destination: &str, lan_domain: &str) -> Vec<String> {
    let mut candidates = vec![destination.to_owned()];
    if is_bare_hostname(destination) && !lan_domain.is_empty() {
        candidates.push(format!("{destination}.{lan_domain}"));
    }
    candidates
}
