use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::fmt;
use std::fs;
use std::io::{self, IsTerminal, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Output};
use std::str::FromStr;

use anyhow::{anyhow, bail, Context, Result};
use serde::Deserialize;
use tempfile::TempDir;

use crate::HostInventory;

const TARGET_ALIASES_JSON: &str = env!("DIFF_TARGET_ALIASES_JSON");
const NIX: &str = env!("DIFF_NIX");
const NH: &str = env!("DIFF_NH");
const DIX: &str = env!("DIFF_DIX");
const GNU_DIFF: &str = env!("DIFF_GNU_DIFF");

const DETECT_TARGET_EXPRESSION: &str = include_str!("diff/detect-target.nix");
const HOME_MANAGER_PACKAGE_EXPRESSION: &str = include_str!("diff/home-manager-package.nix");
const HOME_MANAGER_USERS_EXPRESSION: &str = include_str!("diff/home-manager-users.nix");
const HOMEBREW_MANIFEST_EXPRESSION: &str = include_str!("diff/homebrew-manifest.nix");
const NGINX_CONFIG_EXPRESSION: &str = include_str!("diff/nginx-config.nix");

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TargetKind {
    Nixos,
    Darwin,
}

impl TargetKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::Nixos => "nixos",
            Self::Darwin => "darwin",
        }
    }

    fn nh_subcommand(self) -> &'static str {
        match self {
            Self::Nixos => "os",
            Self::Darwin => "darwin",
        }
    }
}

impl fmt::Display for TargetKind {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TargetRequest {
    pub machine: String,
    pub explicit_kind: Option<TargetKind>,
}

impl FromStr for TargetRequest {
    type Err = anyhow::Error;

    fn from_str(value: &str) -> Result<Self> {
        let mut attribute = value;
        if let Some(stripped) = attribute.strip_prefix(".#") {
            attribute = stripped;
        } else if let Some(stripped) = attribute.strip_prefix('#') {
            attribute = stripped;
        } else if let Some(stripped) = attribute.strip_prefix('.') {
            attribute = stripped;
        }

        let (explicit_kind, machine) =
            if let Some(rest) = attribute.strip_prefix("nixosConfigurations.") {
                (Some(TargetKind::Nixos), first_attribute(rest))
            } else if let Some(rest) = attribute.strip_prefix("darwinConfigurations.") {
                (Some(TargetKind::Darwin), first_attribute(rest))
            } else {
                (None, attribute)
            };

        if machine.is_empty() {
            bail!("machine must not be empty");
        }

        Ok(Self {
            machine: machine.to_owned(),
            explicit_kind,
        })
    }
}

fn first_attribute(value: &str) -> &str {
    value.split('.').next().unwrap_or_default()
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GeneratedPath(PathBuf);

impl GeneratedPath {
    pub fn as_path(&self) -> &Path {
        &self.0
    }
}

impl fmt::Display for GeneratedPath {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.display().fmt(formatter)
    }
}

impl FromStr for GeneratedPath {
    type Err = anyhow::Error;

    fn from_str(value: &str) -> Result<Self> {
        let path = PathBuf::from(value);
        if value.is_empty()
            || path.is_absolute()
            || path.components().any(|component| {
                matches!(
                    component,
                    Component::ParentDir | Component::RootDir | Component::Prefix(_)
                )
            })
        {
            bail!("generated path must be a relative path without '..': {value}");
        }
        Ok(Self(path))
    }
}

#[derive(Clone, Debug)]
pub struct DiffOptions {
    pub details: bool,
    pub generated_paths: Vec<GeneratedPath>,
    pub target: TargetRequest,
    pub old_revision: String,
    pub new_revision: String,
}

pub struct GitCheckout {
    repository: gix::Repository,
    root: PathBuf,
}

impl GitCheckout {
    pub fn discover(explicit_root: Option<&Path>) -> Result<Self> {
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

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn resolve_revision(&self, label: &str, revision: &str) -> Result<String> {
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

    pub fn flake_ref(&self, revision: &str) -> String {
        format!("git+file://{}?rev={revision}", self.root.display())
    }
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub enum RevisionSide {
    Old,
    New,
}

impl RevisionSide {
    fn label(self) -> &'static str {
        match self {
            Self::Old => "old",
            Self::New => "new",
        }
    }
}

#[derive(Clone, Debug)]
pub struct Revision {
    side: RevisionSide,
    id: String,
    flake_ref: String,
    machine: String,
}

impl Revision {
    fn environment(&self, kind: TargetKind) -> [(&'static str, &str); 3] {
        [
            ("DIFF_FLAKE_REF", &self.flake_ref),
            ("DIFF_MACHINE", &self.machine),
            ("DIFF_TARGET_KIND", kind.as_str()),
        ]
    }
}

#[derive(Clone, Debug, Default, Deserialize)]
pub struct HomebrewManifest {
    enabled: bool,
    brews: Vec<String>,
    casks: Vec<String>,
    taps: BTreeMap<String, PathBuf>,
}

pub enum RecursiveDiff {
    Identical,
    Different(String),
}

pub trait DiffBackend {
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
pub struct NativeBackend;

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
        checked_output(command, "dix failed to compare the configurations")
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
            Some(1) => Ok(RecursiveDiff::Different(filter_binary_diff_output(
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

pub fn run_with_backend(
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

#[allow(clippy::too_many_arguments)]
fn run_detail_diff(
    backend: &impl DiffBackend,
    kind: TargetKind,
    old: &Revision,
    new: &Revision,
    old_link: &Path,
    new_link: &Path,
    generated_paths: &[GeneratedPath],
    workspace: &Path,
    color: Option<&str>,
    stdout: &mut impl Write,
    stderr: &mut impl Write,
) -> Result<()> {
    let root = workspace.join("details");
    let old_root = root.join("old");
    let new_root = root.join("new");
    fs::create_dir_all(&old_root)?;
    fs::create_dir_all(&new_root)?;

    let mut found = materialize_system_details(
        kind,
        old_link,
        new_link,
        generated_paths,
        &old_root,
        &new_root,
        stderr,
    )?;
    found |= materialize_nginx_details(backend, kind, old, new, &old_root, &new_root)?;
    found |= materialize_homebrew_details(backend, kind, old, new, &old_root, &new_root, stderr)?;
    found |=
        materialize_home_manager_details(backend, kind, old, new, &old_root, &new_root, stderr)?;

    if !found {
        bail!("No generated detail paths found.");
    }

    match backend.recursive_diff(&root, color)? {
        RecursiveDiff::Identical => writeln!(stdout, "No generated config differences.")?,
        RecursiveDiff::Different(output) => stdout.write_all(output.as_bytes())?,
    }
    Ok(())
}

fn materialize_system_details(
    kind: TargetKind,
    old_link: &Path,
    new_link: &Path,
    generated_paths: &[GeneratedPath],
    old_root: &Path,
    new_root: &Path,
    stderr: &mut impl Write,
) -> Result<bool> {
    let artifacts: &[&str] = match kind {
        TargetKind::Nixos => &["activate", "bin/switch-to-configuration"],
        TargetKind::Darwin => &["activate", "activate-user"],
    };
    let mut found = false;
    for generated in generated_paths {
        if path_exists(&old_link.join(generated.as_path()))
            || path_exists(&new_link.join(generated.as_path()))
        {
            found = true;
        } else {
            writeln!(
                stderr,
                "Skipping missing generated path in both revisions: {generated}"
            )?;
        }
    }
    found |= artifacts
        .iter()
        .any(|path| path_exists(&old_link.join(path)) || path_exists(&new_link.join(path)));
    if !found {
        return Ok(false);
    }

    let old_system = old_root.join("system");
    let new_system = new_root.join("system");
    fs::create_dir_all(&old_system)?;
    fs::create_dir_all(&new_system)?;
    for generated in generated_paths {
        copy_generated_path(old_link, &old_system, generated.as_path())?;
        copy_generated_path(new_link, &new_system, generated.as_path())?;
    }
    for artifact in artifacts {
        copy_generated_path(old_link, &old_system, Path::new(artifact))?;
        copy_generated_path(new_link, &new_system, Path::new(artifact))?;
    }
    Ok(true)
}

fn materialize_nginx_details(
    backend: &impl DiffBackend,
    kind: TargetKind,
    old: &Revision,
    new: &Revision,
    old_root: &Path,
    new_root: &Path,
) -> Result<bool> {
    if kind != TargetKind::Nixos {
        return Ok(false);
    }
    let old_config = backend.nginx_config(old)?;
    let new_config = backend.nginx_config(new)?;
    if let Some(path) = &old_config {
        copy_store_path(
            path,
            &old_root.join("system"),
            Path::new("services/nginx.conf"),
        )?;
    }
    if let Some(path) = &new_config {
        copy_store_path(
            path,
            &new_root.join("system"),
            Path::new("services/nginx.conf"),
        )?;
    }
    Ok(old_config.is_some() || new_config.is_some())
}

fn materialize_home_manager_details(
    backend: &impl DiffBackend,
    kind: TargetKind,
    old: &Revision,
    new: &Revision,
    old_root: &Path,
    new_root: &Path,
    stderr: &mut impl Write,
) -> Result<bool> {
    let old_users: BTreeSet<String> = backend.home_manager_users(kind, old)?.into_iter().collect();
    let new_users: BTreeSet<String> = backend.home_manager_users(kind, new)?.into_iter().collect();
    let users: BTreeSet<&String> = old_users.union(&new_users).collect();
    if users.is_empty() {
        return Ok(false);
    }

    for user in users {
        let old_tree = old_root.join("home-manager").join(user);
        let new_tree = new_root.join("home-manager").join(user);
        fs::create_dir_all(&old_tree)?;
        fs::create_dir_all(&new_tree)?;

        if old_users.contains(user) {
            materialize_home_manager_user(backend, kind, old, user, &old_tree)?;
        } else {
            writeln!(
                stderr,
                "Home Manager user {user} is missing in old revision; diffing against an empty tree."
            )?;
        }
        if new_users.contains(user) {
            materialize_home_manager_user(backend, kind, new, user, &new_tree)?;
        } else {
            writeln!(
                stderr,
                "Home Manager user {user} is missing in new revision; diffing against an empty tree."
            )?;
        }
    }
    Ok(true)
}

fn materialize_home_manager_user(
    backend: &impl DiffBackend,
    kind: TargetKind,
    revision: &Revision,
    user: &str,
    destination: &Path,
) -> Result<()> {
    let activation = backend.home_manager_package(kind, revision, user, "activationPackage")?;
    for path in ["activate", "home-files", "LaunchAgents"] {
        copy_generated_path(&activation, destination, Path::new(path))?;
    }
    let session = backend.home_manager_package(kind, revision, user, "sessionVariablesPackage")?;
    copy_store_path(&session, destination, Path::new("session-vars"))
}

fn materialize_homebrew_details(
    backend: &impl DiffBackend,
    kind: TargetKind,
    old: &Revision,
    new: &Revision,
    old_root: &Path,
    new_root: &Path,
    stderr: &mut impl Write,
) -> Result<bool> {
    if kind != TargetKind::Darwin {
        return Ok(false);
    }
    let old_found =
        materialize_homebrew_revision(&backend.homebrew_manifest(old)?, old_root, stderr)?;
    let new_found =
        materialize_homebrew_revision(&backend.homebrew_manifest(new)?, new_root, stderr)?;
    Ok(old_found || new_found)
}

fn materialize_homebrew_revision(
    manifest: &HomebrewManifest,
    destination: &Path,
    stderr: &mut impl Write,
) -> Result<bool> {
    if !manifest.enabled {
        return Ok(false);
    }
    let mut found = false;
    for token in &manifest.brews {
        found |= materialize_homebrew_recipe(manifest, "brew", token, destination, stderr)?;
    }
    for token in &manifest.casks {
        found |= materialize_homebrew_recipe(manifest, "cask", token, destination, stderr)?;
    }
    Ok(found)
}

fn materialize_homebrew_recipe(
    manifest: &HomebrewManifest,
    kind: &str,
    token: &str,
    destination: &Path,
    stderr: &mut impl Write,
) -> Result<bool> {
    if !valid_homebrew_token(token) {
        writeln!(stderr, "Skipping invalid Homebrew {kind} token '{token}'.")?;
        return Ok(false);
    }
    let recipe = token.rsplit('/').next().expect("token is nonempty");
    let qualified_tap = (token.matches('/').count() >= 2)
        .then(|| token.rsplit_once('/').expect("qualified token").0);
    let preferred_tap = match (qualified_tap, kind) {
        (Some(tap), _) => Some(tap),
        (None, "cask") => Some("homebrew/cask"),
        (None, "brew") => Some("homebrew/core"),
        _ => None,
    };

    let recipe_path = find_recipe(manifest, kind, recipe, preferred_tap)
        .or_else(|| preferred_tap.and_then(|_| find_recipe(manifest, kind, recipe, None)));
    let Some(recipe_path) = recipe_path else {
        writeln!(
            stderr,
            "Unable to find Homebrew {kind} recipe '{token}' in Nix-managed taps."
        )?;
        return Ok(false);
    };
    let destination = destination
        .join("homebrew")
        .join(format!("{kind}s"))
        .join(format!("{token}.rb"));
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::copy(recipe_path, destination)?;
    Ok(true)
}

fn find_recipe(
    manifest: &HomebrewManifest,
    kind: &str,
    recipe: &str,
    required_tap: Option<&str>,
) -> Option<PathBuf> {
    let directory = match kind {
        "brew" => "Formula",
        "cask" => "Casks",
        _ => return None,
    };
    for (tap, root) in &manifest.taps {
        if required_tap.is_some_and(|required| canonical_tap(tap) != required) {
            continue;
        }
        let root = root.join(directory);
        for candidate in [
            root.join(recipe.chars().next()?.to_string())
                .join(format!("{recipe}.rb")),
            root.join(format!("{recipe}.rb")),
        ] {
            if candidate.is_file() {
                return Some(candidate);
            }
        }
        if let Some(candidate) = find_file_recursive(&root, &format!("{recipe}.rb")) {
            return Some(candidate);
        }
    }
    None
}

fn canonical_tap(tap: &str) -> String {
    let Some((owner, repository)) = tap.split_once('/') else {
        return tap.to_owned();
    };
    format!(
        "{owner}/{}",
        repository.strip_prefix("homebrew-").unwrap_or(repository)
    )
}

fn valid_homebrew_token(token: &str) -> bool {
    !token.is_empty()
        && !Path::new(token).is_absolute()
        && !Path::new(token).components().any(|component| {
            matches!(
                component,
                Component::ParentDir | Component::RootDir | Component::Prefix(_)
            )
        })
        && token
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || "@+._/-".contains(character))
}

fn find_file_recursive(root: &Path, filename: &str) -> Option<PathBuf> {
    let mut entries: Vec<_> = fs::read_dir(root).ok()?.filter_map(Result::ok).collect();
    entries.sort_by_key(|entry| entry.file_name());
    for entry in entries {
        let path = entry.path();
        if path.is_file() && entry.file_name() == filename {
            return Some(path);
        }
        if path.is_dir() {
            if let Some(found) = find_file_recursive(&path, filename) {
                return Some(found);
            }
        }
    }
    None
}

fn path_exists(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok()
}

fn copy_generated_path(source_root: &Path, destination_root: &Path, relative: &Path) -> Result<()> {
    let source = source_root.join(relative);
    if !path_exists(&source) || should_skip(&source) {
        return Ok(());
    }
    let destination = destination_root.join(relative);
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)?;
    }
    copy_node(&source, &destination)
}

fn copy_store_path(source: &Path, destination_root: &Path, relative: &Path) -> Result<()> {
    if !path_exists(source) || should_skip(source) {
        return Ok(());
    }
    let destination = destination_root.join(relative);
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)?;
    }
    copy_node(source, &destination)
}

fn copy_node(source: &Path, destination: &Path) -> Result<()> {
    let symlink_metadata = fs::symlink_metadata(source)?;
    if symlink_metadata.file_type().is_symlink() && fs::metadata(source).is_err() {
        let target = fs::read_link(source)?;
        fs::write(
            destination,
            normalize_store_paths(&format!("broken symlink -> {}\n", target.display())),
        )?;
        return Ok(());
    }
    if fs::metadata(source)?.is_dir() {
        fs::create_dir_all(destination)?;
        let mut entries: Vec<_> = fs::read_dir(source)?.collect::<io::Result<_>>()?;
        entries.sort_by_key(|entry| entry.file_name());
        for entry in entries {
            let child = entry.path();
            if !should_skip(&child) {
                copy_node(&child, &destination.join(entry.file_name()))?;
            }
        }
        return Ok(());
    }

    let bytes = fs::read(source)?;
    if !bytes.is_empty() && !bytes.contains(&0) {
        if let Ok(text) = std::str::from_utf8(&bytes) {
            fs::write(destination, normalize_store_paths(text))?;
            let mut permissions = fs::metadata(destination)?.permissions();
            permissions.set_mode(permissions.mode() | 0o200);
            fs::set_permissions(destination, permissions)?;
            return Ok(());
        }
    }
    fs::copy(source, destination)?;
    Ok(())
}

fn should_skip(path: &Path) -> bool {
    let path = path.to_string_lossy();
    [
        "/etc/profiles",
        "/share/man",
        "/etc/ssl/trust-source",
        "/etc/terminfo",
        "/etc/zoneinfo",
    ]
    .iter()
    .any(|pattern| at_or_below(&path, pattern))
        || [
            "/etc/pki/tls/certs/ca-bundle.crt",
            "/etc/ssl/certs/ca-bundle.crt",
            "/etc/ssl/certs/ca-certificates.crt",
            "/etc/ssh/moduli",
            "/etc/issue",
            "/etc/issue.net",
            "/etc/os-release",
            "/etc/lsb-release",
        ]
        .iter()
        .any(|pattern| path.ends_with(pattern))
}

fn at_or_below(path: &str, pattern: &str) -> bool {
    path.ends_with(pattern) || path.contains(&format!("{pattern}/"))
}

pub fn filter_dix_output(output: &str) -> String {
    let mut filtered = String::new();
    let mut seen = false;
    for line in output.lines() {
        let plain = strip_ansi(line);
        if plain.starts_with("<<< ") || plain.starts_with(">>> ") {
            continue;
        }
        if let Some(package) = dix_package_name(&plain) {
            if package == "source" || package.starts_with("nixos-system-") {
                continue;
            }
        }
        if !seen && plain.is_empty() {
            continue;
        }
        seen = true;
        filtered.push_str(line);
        filtered.push('\n');
    }
    filtered
}

fn dix_package_name(line: &str) -> Option<&str> {
    let rest = line.strip_prefix('[')?.split_once(']')?.1.trim_start();
    rest.split_whitespace().next()
}

fn strip_ansi(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut output = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == 0x1b && bytes.get(index + 1) == Some(&b'[') {
            let mut end = index + 2;
            while end < bytes.len() && (bytes[end].is_ascii_digit() || bytes[end] == b';') {
                end += 1;
            }
            if bytes.get(end) == Some(&b'm') {
                index = end + 1;
                continue;
            }
        }
        output.push(bytes[index]);
        index += 1;
    }
    String::from_utf8_lossy(&output).into_owned()
}

fn filter_binary_diff_output(output: &str) -> String {
    let mut filtered = String::new();
    for line in output.lines() {
        if line.starts_with("Binary files ") && line.contains(" and ") && line.ends_with(" differ")
        {
            continue;
        }
        filtered.push_str(line);
        filtered.push('\n');
    }
    filtered
}

pub fn normalize_store_paths(value: &str) -> String {
    const PREFIX: &str = "/nix/store/";
    let mut output = String::with_capacity(value.len());
    let mut remaining = value;
    while let Some(position) = remaining.find(PREFIX) {
        output.push_str(&remaining[..position]);
        let candidate = &remaining[position..];
        if let Some(end) = store_path_end(candidate) {
            output.push_str("/nix/store/<path>");
            remaining = &candidate[end..];
        } else {
            output.push_str(PREFIX);
            remaining = &candidate[PREFIX.len()..];
        }
    }
    output.push_str(remaining);
    output
}

fn store_path_end(candidate: &str) -> Option<usize> {
    const PREFIX: &str = "/nix/store/";
    let bytes = candidate.as_bytes();
    let hash_start = PREFIX.len();
    let hash_end = hash_start + 32;
    if bytes.len() <= hash_end
        || !bytes[hash_start..hash_end]
            .iter()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
    {
        return None;
    }
    let name_start = if bytes.get(hash_end) == Some(&b'-') {
        hash_end + 1
    } else if bytes.get(hash_end..hash_end + 2) == Some(b"\\-") {
        hash_end + 2
    } else {
        return None;
    };
    let end = bytes[name_start..]
        .iter()
        .position(|byte| {
            matches!(
                byte,
                b'/' | b' ' | b'\t' | b'\r' | b'\n' | b'\'' | b'"' | b'<' | b'>'
            )
        })
        .map_or(bytes.len(), |offset| name_start + offset);
    (end > name_start).then_some(end)
}

#[cfg(test)]
mod tests {
    use std::cell::{Cell, RefCell};
    use std::collections::BTreeMap;
    use std::fs;
    use std::os::unix::fs::{symlink, PermissionsExt};
    use std::path::{Path, PathBuf};

    use tempfile::TempDir;

    use super::{
        copy_generated_path, filter_binary_diff_output, filter_dix_output,
        materialize_homebrew_revision, normalize_store_paths, run_with_backend, DiffBackend,
        DiffOptions, GeneratedPath, GitCheckout, HomebrewManifest, RecursiveDiff, Revision,
        RevisionSide, TargetKind, TargetRequest,
    };

    struct FakeBackend {
        old_kind: Option<TargetKind>,
        new_kind: Option<TargetKind>,
        builds: RefCell<Vec<(RevisionSide, TargetKind)>>,
        package_diff: String,
        details: bool,
        fixture: TempDir,
        recursive_diff_called: Cell<bool>,
    }

    impl FakeBackend {
        fn new(kind: TargetKind, details: bool) -> Self {
            let fixture = TempDir::new().expect("backend fixture");
            if details {
                for side in [RevisionSide::Old, RevisionSide::New] {
                    let label = side.label();
                    fs::write(
                        fixture.path().join(format!("nginx-{label}.conf")),
                        format!("nginx={label}\n"),
                    )
                    .expect("nginx fixture");
                    let activation = fixture.path().join(format!("activation-{label}"));
                    fs::create_dir_all(activation.join("home-files/.config"))
                        .expect("Home Manager fixture");
                    fs::write(activation.join("activate"), format!("activate={label}\n"))
                        .expect("activation script");
                    fs::write(
                        activation.join("home-files/.config/hm.conf"),
                        format!("home={label}\n"),
                    )
                    .expect("Home Manager config");
                    let session = fixture.path().join(format!("session-{label}"));
                    fs::create_dir_all(session.join("etc/profile.d")).expect("session fixture");
                    fs::write(
                        session.join("etc/profile.d/hm-session-vars.sh"),
                        format!("session={label}\n"),
                    )
                    .expect("session variables");
                }
            }
            Self {
                old_kind: Some(kind),
                new_kind: Some(kind),
                builds: RefCell::new(Vec::new()),
                package_diff: concat!(
                    "<<< old\n",
                    ">>> new\n",
                    "[C.] source +1\n",
                    "[U.] package 1 -> 2\n"
                )
                .to_owned(),
                details,
                fixture,
                recursive_diff_called: Cell::new(false),
            }
        }
    }

    impl DiffBackend for FakeBackend {
        fn detect_target(&self, revision: &Revision) -> anyhow::Result<Option<TargetKind>> {
            Ok(match revision.side {
                RevisionSide::Old => self.old_kind,
                RevisionSide::New => self.new_kind,
            })
        }

        fn build_toplevel(
            &self,
            kind: TargetKind,
            revision: &Revision,
            out_link: &Path,
        ) -> anyhow::Result<()> {
            self.builds.borrow_mut().push((revision.side, kind));
            if self.details {
                fs::create_dir_all(out_link.join("etc/nix"))?;
                fs::create_dir_all(out_link.join("bin"))?;
                let hash = match revision.side {
                    RevisionSide::Old => "11111111111111111111111111111111",
                    RevisionSide::New => "22222222222222222222222222222222",
                };
                fs::write(
                    out_link.join("etc/nix/nix.conf"),
                    format!("store=/nix/store/{hash}-same-package/bin\n"),
                )?;
                fs::write(out_link.join("etc/issue"), "release metadata\n")?;
                fs::write(out_link.join("activate"), format!("activate={hash}\n"))?;
                fs::write(
                    out_link.join("bin/switch-to-configuration"),
                    format!("switch={hash}\n"),
                )?;
            }
            Ok(())
        }

        fn package_diff(
            &self,
            _old_link: &Path,
            _new_link: &Path,
            _color: &str,
        ) -> anyhow::Result<String> {
            Ok(self.package_diff.clone())
        }

        fn nginx_config(&self, revision: &Revision) -> anyhow::Result<Option<PathBuf>> {
            Ok(self.details.then(|| {
                self.fixture
                    .path()
                    .join(format!("nginx-{}.conf", revision.side.label()))
            }))
        }

        fn home_manager_users(
            &self,
            _kind: TargetKind,
            _revision: &Revision,
        ) -> anyhow::Result<Vec<String>> {
            Ok(if self.details {
                vec!["ihrachyshka".to_owned()]
            } else {
                Vec::new()
            })
        }

        fn home_manager_package(
            &self,
            _kind: TargetKind,
            revision: &Revision,
            _user: &str,
            attribute: &str,
        ) -> anyhow::Result<PathBuf> {
            let prefix = match attribute {
                "activationPackage" => "activation",
                "sessionVariablesPackage" => "session",
                _ => anyhow::bail!("unexpected Home Manager attribute: {attribute}"),
            };
            Ok(self
                .fixture
                .path()
                .join(format!("{prefix}-{}", revision.side.label())))
        }

        fn homebrew_manifest(&self, _revision: &Revision) -> anyhow::Result<HomebrewManifest> {
            Ok(HomebrewManifest::default())
        }

        fn recursive_diff(
            &self,
            root: &Path,
            _color: Option<&str>,
        ) -> anyhow::Result<RecursiveDiff> {
            self.recursive_diff_called.set(true);
            assert_eq!(
                fs::read_to_string(root.join("old/system/etc/nix/nix.conf"))?,
                "store=/nix/store/<path>/bin\n"
            );
            assert!(!root.join("old/system/etc/issue").exists());
            assert_eq!(
                fs::read_to_string(root.join("new/system/services/nginx.conf"))?,
                "nginx=new\n"
            );
            assert_eq!(
                fs::read_to_string(
                    root.join("old/home-manager/ihrachyshka/home-files/.config/hm.conf")
                )?,
                "home=old\n"
            );
            assert_eq!(
                fs::read_to_string(root.join(
                    "new/home-manager/ihrachyshka/session-vars/etc/profile.d/hm-session-vars.sh"
                ))?,
                "session=new\n"
            );
            Ok(RecursiveDiff::Different("detail output\n".to_owned()))
        }
    }

    fn test_checkout() -> (TempDir, GitCheckout, String, String) {
        let directory = TempDir::new().expect("temporary repository");
        fs::write(directory.path().join("flake.nix"), "{}\n").expect("flake marker");
        let repository = gix::init(directory.path()).expect("initialize repository");
        let signature = gix::actor::SignatureRef::from_bytes(
            b"Test User <test@example.invalid> 1700000000 +0000",
        )
        .expect("valid signature");
        let tree = repository.empty_tree().id;
        let old = repository
            .commit_as(
                signature,
                signature,
                "HEAD",
                "old",
                tree,
                std::iter::empty::<gix::ObjectId>(),
            )
            .expect("create old commit")
            .detach();
        let new = repository
            .commit_as(signature, signature, "HEAD", "new", tree, [old])
            .expect("create new commit")
            .detach();
        drop(repository);
        let checkout = GitCheckout::discover(Some(directory.path())).expect("discover checkout");
        (directory, checkout, old.to_string(), new.to_string())
    }

    #[test]
    fn target_parser_accepts_short_and_flake_attribute_names() {
        assert_eq!(
            "frame".parse::<TargetRequest>().expect("short target"),
            TargetRequest {
                machine: "frame".to_owned(),
                explicit_kind: None,
            }
        );
        assert_eq!(
            ".#nixosConfigurations.frame.config.system.build.toplevel"
                .parse::<TargetRequest>()
                .expect("NixOS attribute"),
            TargetRequest {
                machine: "frame".to_owned(),
                explicit_kind: Some(TargetKind::Nixos),
            }
        );
        assert_eq!(
            "#darwinConfigurations.mair.system"
                .parse::<TargetRequest>()
                .expect("Darwin attribute"),
            TargetRequest {
                machine: "mair".to_owned(),
                explicit_kind: Some(TargetKind::Darwin),
            }
        );
    }

    #[test]
    fn workflow_builds_both_revisions_and_filters_package_diff() {
        let (_directory, checkout, old, new) = test_checkout();
        let backend = FakeBackend::new(TargetKind::Nixos, false);
        let options = DiffOptions {
            details: false,
            generated_paths: Vec::new(),
            target: "frame".parse().expect("known target"),
            old_revision: old,
            new_revision: new,
        };
        let mut stdout = Vec::new();
        let mut stderr = Vec::new();

        run_with_backend(&options, &checkout, &backend, &mut stdout, &mut stderr)
            .expect("run configuration diff");

        assert_eq!(
            backend.builds.into_inner(),
            [
                (RevisionSide::Old, TargetKind::Nixos),
                (RevisionSide::New, TargetKind::Nixos),
            ]
        );
        assert_eq!(
            String::from_utf8(stdout).expect("UTF-8 output"),
            "[U.] package 1 -> 2\n"
        );
        let stderr = String::from_utf8(stderr).expect("UTF-8 diagnostics");
        assert!(stderr.contains("Building nixos configuration frame at old"));
        assert!(stderr.contains("Building nixos configuration frame at new"));
        assert!(stderr.contains("Diffing nixos configuration frame:"));
    }

    #[test]
    fn workflow_reports_new_only_machine_without_building() {
        let (_directory, checkout, old, new) = test_checkout();
        let mut backend = FakeBackend::new(TargetKind::Nixos, false);
        backend.old_kind = None;
        let options = DiffOptions {
            details: false,
            generated_paths: Vec::new(),
            target: "frame".parse().expect("known target"),
            old_revision: old,
            new_revision: new,
        };
        let mut stdout = Vec::new();
        let mut stderr = Vec::new();

        run_with_backend(&options, &checkout, &backend, &mut stdout, &mut stderr)
            .expect("report new-only target");

        assert!(backend.builds.into_inner().is_empty());
        assert_eq!(
            String::from_utf8(stdout).expect("UTF-8 output"),
            "Machine 'frame' is present only in the new revision; no old configuration exists to diff.\n"
        );
        assert!(stderr.is_empty());
    }

    #[test]
    fn workflow_detects_bare_darwin_target() {
        let (_directory, checkout, old, new) = test_checkout();
        let backend = FakeBackend::new(TargetKind::Darwin, false);
        let options = DiffOptions {
            details: false,
            generated_paths: Vec::new(),
            target: "mair".parse().expect("known target"),
            old_revision: old,
            new_revision: new,
        };

        run_with_backend(
            &options,
            &checkout,
            &backend,
            &mut Vec::new(),
            &mut Vec::new(),
        )
        .expect("run Darwin diff");

        assert_eq!(
            backend.builds.into_inner(),
            [
                (RevisionSide::Old, TargetKind::Darwin),
                (RevisionSide::New, TargetKind::Darwin),
            ]
        );
    }

    #[test]
    fn detailed_workflow_materializes_system_nginx_and_home_manager_data() {
        let (_directory, checkout, old, new) = test_checkout();
        let backend = FakeBackend::new(TargetKind::Nixos, true);
        let options = DiffOptions {
            details: true,
            generated_paths: Vec::new(),
            target: "frame".parse().expect("known target"),
            old_revision: old,
            new_revision: new,
        };
        let mut stdout = Vec::new();

        run_with_backend(&options, &checkout, &backend, &mut stdout, &mut Vec::new())
            .expect("run detailed diff");

        assert!(backend.recursive_diff_called.get());
        assert_eq!(
            String::from_utf8(stdout).expect("UTF-8 output"),
            "[U.] package 1 -> 2\ndetail output\n"
        );
    }

    #[test]
    fn generated_paths_reject_absolute_and_parent_components() {
        for path in ["", "/etc", "..", "../etc", "etc/../secret"] {
            assert!(path.parse::<GeneratedPath>().is_err(), "accepted {path:?}");
        }
        assert_eq!(
            "etc/nix/nix.conf"
                .parse::<GeneratedPath>()
                .expect("relative path")
                .as_path(),
            Path::new("etc/nix/nix.conf")
        );
    }

    #[test]
    fn native_git_checkout_resolves_commits_without_git_cli() {
        let directory = TempDir::new().expect("temporary repository");
        fs::write(directory.path().join("flake.nix"), "{}\n").expect("flake marker");
        let repository = gix::init(directory.path()).expect("initialize repository");
        let signature = gix::actor::SignatureRef::from_bytes(
            b"Test User <test@example.invalid> 1700000000 +0000",
        )
        .expect("valid signature");
        let commit = repository
            .commit_as(
                signature,
                signature,
                "HEAD",
                "initial",
                repository.empty_tree().id,
                std::iter::empty::<gix::ObjectId>(),
            )
            .expect("create commit")
            .detach();
        drop(repository);

        let checkout = GitCheckout::discover(Some(directory.path())).expect("discover checkout");
        assert_eq!(
            checkout
                .resolve_revision("new", "HEAD")
                .expect("resolve HEAD"),
            commit.to_string()
        );
        assert_eq!(
            checkout.flake_ref(&commit.to_string()),
            format!(
                "git+file://{}?rev={commit}",
                directory
                    .path()
                    .canonicalize()
                    .expect("canonical path")
                    .display()
            )
        );
        assert!(checkout.resolve_revision("old", "missing").is_err());
    }

    #[test]
    fn dix_filter_removes_headers_and_redundant_packages() {
        let output = concat!(
            "<<< /tmp/old\n",
            ">>> /tmp/new\n",
            "\n",
            "CHANGED\n",
            "[C.] source +14.8 KiB\n",
            "\u{1b}[31m[C.]\u{1b}[0m \u{1b}[32msource\u{1b}[0m +14.8 KiB\n",
            "[U.] nixos-system-frame 1 -> 2\n",
            "[U.] package 1.0 -> 2.0\n",
            "\n",
            "SIZE: 1 -> 2\n",
        );

        assert_eq!(
            filter_dix_output(output),
            "CHANGED\n[U.] package 1.0 -> 2.0\n\nSIZE: 1 -> 2\n"
        );
    }

    #[test]
    fn store_paths_are_normalized_in_plain_and_roff_text() {
        let hash = "11111111111111111111111111111111";
        assert_eq!(
            normalize_store_paths(&format!(
                "plain=/nix/store/{hash}-same-package/bin roff=/nix/store/{hash}\\-source/modules\n"
            )),
            "plain=/nix/store/<path>/bin roff=/nix/store/<path>/modules\n"
        );
    }

    #[test]
    fn generated_tree_copy_normalizes_text_and_skips_package_noise() {
        let source = TempDir::new().expect("source tree");
        let destination = TempDir::new().expect("destination tree");
        let etc = source.path().join("etc");
        fs::create_dir_all(etc.join("nix")).expect("nix directory");
        fs::create_dir_all(etc.join("ssl/certs")).expect("certificate directory");
        fs::create_dir_all(etc.join("test-links")).expect("link directory");
        let config = etc.join("nix/nix.conf");
        fs::write(
            &config,
            "store=/nix/store/11111111111111111111111111111111-same-package/bin\n",
        )
        .expect("config");
        fs::set_permissions(&config, fs::Permissions::from_mode(0o444)).expect("readonly config");
        fs::write(etc.join("issue"), "release metadata\n").expect("issue");
        fs::write(
            etc.join("ssl/certs/ca-bundle.crt"),
            "generated certificates\n",
        )
        .expect("certificate bundle");
        fs::write(etc.join("test-links/cache.bin"), b"\0binary\n").expect("binary file");
        symlink("missing-target", etc.join("test-links/broken")).expect("broken symlink");

        copy_generated_path(source.path(), destination.path(), Path::new("etc"))
            .expect("copy generated tree");

        assert_eq!(
            fs::read_to_string(destination.path().join("etc/nix/nix.conf"))
                .expect("normalized config"),
            "store=/nix/store/<path>/bin\n"
        );
        assert!(
            fs::metadata(destination.path().join("etc/nix/nix.conf"))
                .expect("config metadata")
                .permissions()
                .mode()
                & 0o200
                != 0
        );
        assert!(!destination.path().join("etc/issue").exists());
        assert!(!destination
            .path()
            .join("etc/ssl/certs/ca-bundle.crt")
            .exists());
        assert_eq!(
            fs::read(destination.path().join("etc/test-links/cache.bin")).expect("binary copy"),
            b"\0binary\n"
        );
        assert_eq!(
            fs::read_to_string(destination.path().join("etc/test-links/broken"))
                .expect("broken link marker"),
            "broken symlink -> missing-target\n"
        );
    }

    #[test]
    fn homebrew_materialization_uses_typed_manifest_and_tap_layout() {
        let tap = TempDir::new().expect("tap");
        let destination = TempDir::new().expect("destination");
        fs::create_dir_all(tap.path().join("Casks/s")).expect("cask directory");
        fs::write(
            tap.path().join("Casks/s/sf-symbols.rb"),
            "cask \"sf-symbols\" do\n  version \"8.0\"\nend\n",
        )
        .expect("cask recipe");
        let manifest = HomebrewManifest {
            enabled: true,
            casks: vec!["sf-symbols".to_owned()],
            taps: BTreeMap::from([("homebrew/homebrew-cask".to_owned(), tap.path().to_owned())]),
            ..HomebrewManifest::default()
        };
        let mut stderr = Vec::new();

        assert!(
            materialize_homebrew_revision(&manifest, destination.path(), &mut stderr)
                .expect("materialize cask")
        );
        assert!(stderr.is_empty());
        assert_eq!(
            fs::read_to_string(destination.path().join("homebrew/casks/sf-symbols.rb"))
                .expect("materialized recipe"),
            "cask \"sf-symbols\" do\n  version \"8.0\"\nend\n"
        );
    }

    #[test]
    fn binary_diff_lines_are_removed_without_hiding_text_changes() {
        assert_eq!(
            filter_binary_diff_output(
                "diff -ruN old/a new/a\nBinary files old/cache and new/cache differ\n-old\n+new\n"
            ),
            "diff -ruN old/a new/a\n-old\n+new\n"
        );
    }

    #[test]
    fn homebrew_tokens_reject_traversal_instead_of_writing_outside_tree() {
        let destination = TempDir::new().expect("destination");
        let manifest = HomebrewManifest {
            enabled: true,
            brews: vec!["../escape".to_owned()],
            ..HomebrewManifest::default()
        };
        let mut stderr = Vec::new();

        assert!(
            !materialize_homebrew_revision(&manifest, destination.path(), &mut stderr)
                .expect("skip invalid token")
        );
        assert!(String::from_utf8(stderr)
            .expect("UTF-8 diagnostic")
            .contains("Skipping invalid Homebrew brew token '../escape'."));
        assert!(!destination.path().join("escape.rb").exists());
    }

    #[test]
    fn canonical_homebrew_tap_names_drop_repository_prefix() {
        assert_eq!(
            super::canonical_tap("homebrew/homebrew-cask"),
            "homebrew/cask"
        );
        assert_eq!(super::canonical_tap("owner/custom"), "owner/custom");
    }

    #[test]
    fn recursive_recipe_search_is_deterministic() {
        let root = TempDir::new().expect("tap");
        fs::create_dir_all(root.path().join("Formula/z/deep")).expect("nested directory");
        let expected = root.path().join("Formula/z/deep/tool.rb");
        fs::write(&expected, "formula\n").expect("recipe");
        let manifest = HomebrewManifest {
            taps: BTreeMap::from([("owner/tap".to_owned(), root.path().to_owned())]),
            ..HomebrewManifest::default()
        };

        assert_eq!(
            super::find_recipe(&manifest, "brew", "tool", None),
            Some(expected)
        );
    }
}
