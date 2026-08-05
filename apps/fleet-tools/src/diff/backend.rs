use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use anyhow::{anyhow, bail, Context, Result};
use serde::Deserialize;

use super::{filter_binary_diff_output, Revision, TargetKind};

const NIX: &str = env!("DIFF_NIX");
const NH: &str = env!("DIFF_NH");
const DIX: &str = env!("DIFF_DIX");
const GNU_DIFF: &str = env!("DIFF_GNU_DIFF");

const DETECT_TARGET_EXPRESSION: &str = include_str!("detect-target.nix");
const HOME_MANAGER_PACKAGE_EXPRESSION: &str = include_str!("home-manager-package.nix");
const HOME_MANAGER_USERS_EXPRESSION: &str = include_str!("home-manager-users.nix");
const HOMEBREW_MANIFEST_EXPRESSION: &str = include_str!("homebrew-manifest.nix");
const NGINX_CONFIG_EXPRESSION: &str = include_str!("nginx-config.nix");

#[derive(Clone, Debug, Default, Deserialize)]
pub(super) struct HomebrewManifest {
    pub(super) enabled: bool,
    pub(super) brews: Vec<String>,
    pub(super) casks: Vec<String>,
    pub(super) taps: BTreeMap<String, PathBuf>,
}

pub(super) enum RecursiveDiff {
    Identical,
    Different(String),
}

pub(super) trait DiffBackend {
    fn detect_target(&self, revision: &Revision) -> Result<Option<TargetKind>>;

    fn build_toplevel(&self, kind: TargetKind, revision: &Revision, out_link: &Path) -> Result<()>;

    fn package_diff(&self, old_link: &Path, new_link: &Path, color: &str) -> Result<String>;

    fn nginx_config(&self, revision: &Revision) -> Result<Option<PathBuf>>;

    fn home_manager_users(&self, kind: TargetKind, revision: &Revision) -> Result<Vec<String>>;

    fn home_manager_package(
        &self,
        kind: TargetKind,
        revision: &Revision,
        user: &str,
        attribute: &str,
    ) -> Result<PathBuf>;

    fn homebrew_manifest(&self, revision: &Revision) -> Result<HomebrewManifest>;

    fn recursive_diff(&self, root: &Path, color: Option<&str>) -> Result<RecursiveDiff>;
}

#[derive(Default)]
pub(super) struct NativeBackend;

impl NativeBackend {
    fn nix_eval(
        &self,
        expression: &str,
        json: bool,
        environment: &[(&str, &str)],
        description: &str,
    ) -> Result<String> {
        let mut command = nix_command("eval");
        command.arg("--impure");
        command.arg(if json { "--json" } else { "--raw" });
        command.args(["--expr", expression]);
        set_environment(&mut command, environment);
        checked_output(command, description)
    }

    fn nix_build(
        &self,
        expression: &str,
        environment: &[(&str, &str)],
        description: &str,
    ) -> Result<PathBuf> {
        let mut command = nix_command("build");
        command.args([
            "--impure",
            "--no-link",
            "--print-out-paths",
            "--expr",
            expression,
        ]);
        set_environment(&mut command, environment);
        let output = checked_output(command, description)?;
        let mut paths = output.lines().filter(|line| !line.is_empty());
        let path = paths
            .next()
            .with_context(|| format!("{description} produced no store path"))?;
        if paths.next().is_some() {
            bail!("{description} produced multiple store paths");
        }
        Ok(PathBuf::from(path))
    }
}

impl DiffBackend for NativeBackend {
    fn detect_target(&self, revision: &Revision) -> Result<Option<TargetKind>> {
        let value = self.nix_eval(
            DETECT_TARGET_EXPRESSION,
            false,
            &[
                ("DIFF_FLAKE_REF", &revision.flake_ref),
                ("DIFF_MACHINE", &revision.machine),
            ],
            &format!(
                "Unable to inspect {} revision for machine '{}'",
                revision.side.label(),
                revision.machine
            ),
        )?;
        match value.trim() {
            "nixos" => Ok(Some(TargetKind::Nixos)),
            "darwin" => Ok(Some(TargetKind::Darwin)),
            "missing" => Ok(None),
            other => bail!("Nix returned an unsupported target kind: {other}"),
        }
    }

    fn build_toplevel(&self, kind: TargetKind, revision: &Revision, out_link: &Path) -> Result<()> {
        let status = Command::new(NH)
            .args([
                kind.nh_subcommand(),
                "build",
                "--no-nom",
                "--diff",
                "never",
                "--hostname",
            ])
            .arg(&revision.machine)
            .arg("--out-link")
            .arg(out_link)
            .args(["--print-build-logs", "--show-trace"])
            .arg(&revision.flake_ref)
            .status()
            .with_context(|| format!("Unable to start {NH}"))?;
        if !status.success() {
            bail!(
                "Unable to build the {} {} configuration (exit status {status})",
                revision.side.label(),
                kind
            );
        }
        Ok(())
    }

    fn package_diff(&self, old_link: &Path, new_link: &Path, color: &str) -> Result<String> {
        let mut command = Command::new(DIX);
        command
            .arg("--color")
            .arg(color)
            .arg(old_link)
            .arg(new_link);
        let output = command
            .output()
            .with_context(|| format!("Unable to start {DIX}"))?;
        match output.status.code() {
            Some(0) | Some(1) => {
                String::from_utf8(output.stdout).with_context(|| "dix returned non-UTF-8 output")
            }
            _ => Err(command_error(
                "dix failed to compare the configurations",
                &output,
            )),
        }
    }

    fn nginx_config(&self, revision: &Revision) -> Result<Option<PathBuf>> {
        let value = self.nix_eval(
            NGINX_CONFIG_EXPRESSION,
            false,
            &[
                ("DIFF_FLAKE_REF", &revision.flake_ref),
                ("DIFF_MACHINE", &revision.machine),
            ],
            &format!(
                "Unable to inspect rendered nginx configuration in {} revision",
                revision.side.label()
            ),
        )?;
        let value = value.trim();
        Ok((!value.is_empty()).then(|| PathBuf::from(value)))
    }

    fn home_manager_users(&self, kind: TargetKind, revision: &Revision) -> Result<Vec<String>> {
        let value = self.nix_eval(
            HOME_MANAGER_USERS_EXPRESSION,
            true,
            &revision.environment(kind),
            &format!(
                "Unable to inspect Home Manager users in {} revision for machine '{}'",
                revision.side.label(),
                revision.machine
            ),
        )?;
        serde_json::from_str(&value).context("Nix returned invalid Home Manager user JSON")
    }

    fn home_manager_package(
        &self,
        kind: TargetKind,
        revision: &Revision,
        user: &str,
        attribute: &str,
    ) -> Result<PathBuf> {
        let mut environment = revision.environment(kind).to_vec();
        environment.push(("DIFF_HOME_MANAGER_USER", user));
        environment.push(("DIFF_HOME_MANAGER_ATTRIBUTE", attribute));
        self.nix_build(
            HOME_MANAGER_PACKAGE_EXPRESSION,
            &environment,
            &format!(
                "Unable to build Home Manager {attribute} for {user} in {} revision",
                revision.side.label()
            ),
        )
    }

    fn homebrew_manifest(&self, revision: &Revision) -> Result<HomebrewManifest> {
        let value = self.nix_eval(
            HOMEBREW_MANIFEST_EXPRESSION,
            true,
            &[
                ("DIFF_FLAKE_REF", &revision.flake_ref),
                ("DIFF_MACHINE", &revision.machine),
            ],
            &format!(
                "Unable to inspect Homebrew configuration in {} revision for machine '{}'",
                revision.side.label(),
                revision.machine
            ),
        )?;
        serde_json::from_str(&value).context("Nix returned invalid Homebrew manifest JSON")
    }

    fn recursive_diff(&self, root: &Path, color: Option<&str>) -> Result<RecursiveDiff> {
        let mut command = Command::new(GNU_DIFF);
        if let Some(color) = color.filter(|_| diff_supports_color()) {
            command.arg(format!("--color={color}"));
        }
        let output = command
            .args(["-ruN", "old", "new"])
            .current_dir(root)
            .env("LC_ALL", "C")
            .output()
            .with_context(|| format!("Unable to start {GNU_DIFF}"))?;

        match output.status.code() {
            Some(0) => Ok(RecursiveDiff::Identical),
            Some(1 | 2) => Ok(RecursiveDiff::Different(filter_binary_diff_output(
                &String::from_utf8_lossy(&output.stdout),
            ))),
            _ => Err(command_error(
                "diff failed to compare generated configuration",
                &output,
            )),
        }
    }
}

fn nix_command(subcommand: &str) -> Command {
    let mut command = Command::new(NIX);
    command.args([
        "--extra-experimental-features",
        "nix-command flakes",
        subcommand,
    ]);
    command
}

fn set_environment(command: &mut Command, environment: &[(&str, &str)]) {
    for (name, value) in environment {
        command.env(name, value);
    }
}

fn checked_output(mut command: Command, description: &str) -> Result<String> {
    let output = command
        .output()
        .with_context(|| format!("Unable to start {:?}", command.get_program()))?;
    if !output.status.success() {
        return Err(command_error(description, &output));
    }
    String::from_utf8(output.stdout)
        .with_context(|| format!("{description} returned non-UTF-8 output"))
}

fn command_error(description: &str, output: &Output) -> anyhow::Error {
    let stderr = String::from_utf8_lossy(&output.stderr);
    let stderr = stderr.trim();
    if stderr.is_empty() {
        anyhow!("{description} (exit status {})", output.status)
    } else {
        anyhow!("{description} (exit status {}): {stderr}", output.status)
    }
}

fn diff_supports_color() -> bool {
    Command::new(GNU_DIFF)
        .args(["--color=never", "-q", "/dev/null", "/dev/null"])
        .status()
        .is_ok_and(|status| status.success())
}
