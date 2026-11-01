use std::collections::BTreeMap;
use std::env;
use std::ffi::OsStr;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{bail, Context, Result};
use clap::ValueEnum;
use rustix::fs::statvfs;
use rustix::system::uname;
use rustix::termios::{self, LocalModes, OptionalActions, Termios};

const GIB: u64 = 1024 * 1024 * 1024;
const DEPLOY_NH: &str = env!("DEPLOY_NH");
const DEPLOY_NIX: &str = env!("DEPLOY_NIX");
const DEPLOY_NIX_COLLECT_GARBAGE: &str = env!("DEPLOY_NIX_COLLECT_GARBAGE");
const DEPLOY_NIX_STORE: &str = env!("DEPLOY_NIX_STORE");
const NIXOS_REBUILD: &str = "/run/current-system/sw/bin/nixos-rebuild";
const NIX_STORE: &str = "/nix/store";

#[cfg(target_os = "macos")]
const SUDO: &str = "/usr/bin/sudo";
#[cfg(target_os = "linux")]
const SUDO: &str = "/run/wrappers/bin/sudo";

#[derive(Clone, Copy, Debug, Eq, PartialEq, ValueEnum)]
pub enum DeployAction {
    Switch,
    Boot,
    DryActivate,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TargetOs {
    Darwin,
    Linux,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DeployRequest {
    pub action: DeployAction,
    pub config_name: String,
    pub expected_runtime_host: String,
    pub gc_headroom_gib: u64,
    pub min_free_gib: u64,
    pub no_inhibit: bool,
    pub source: PathBuf,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CommandSpec {
    pub args: Vec<String>,
    pub cwd: Option<PathBuf>,
    pub env: BTreeMap<String, String>,
    pub program: PathBuf,
}

impl CommandSpec {
    fn new(program: impl Into<PathBuf>) -> Self {
        Self {
            args: Vec::new(),
            cwd: None,
            env: BTreeMap::new(),
            program: program.into(),
        }
    }

    fn args(mut self, args: impl IntoIterator<Item = impl Into<String>>) -> Self {
        self.args.extend(args.into_iter().map(Into::into));
        self
    }

    fn cwd(mut self, path: &Path) -> Self {
        self.cwd = Some(path.to_path_buf());
        self
    }

    fn env(mut self, name: &str, value: &str) -> Self {
        self.env.insert(name.to_owned(), value.to_owned());
        self
    }
}

pub trait Backend {
    fn available_bytes(&mut self, path: &Path) -> Result<u64>;
    fn current_exe(&self) -> Result<PathBuf>;
    fn hostname(&self) -> Result<String>;
    fn read_link(&self, path: &Path) -> Result<PathBuf>;
    fn run(&mut self, command: CommandSpec) -> Result<()>;
    fn target_os(&self) -> TargetOs;
    fn use_sudo_askpass(&self) -> bool;
}

pub struct SystemBackend;

impl Backend for SystemBackend {
    fn available_bytes(&mut self, path: &Path) -> Result<u64> {
        let status = statvfs(path)
            .with_context(|| format!("failed to inspect free space on {}", path.display()))?;
        status
            .f_bavail
            .checked_mul(status.f_frsize)
            .context("available disk size overflowed u64")
    }

    fn current_exe(&self) -> Result<PathBuf> {
        env::current_exe().context("failed to locate the deploy helper executable")
    }

    fn hostname(&self) -> Result<String> {
        let system = uname();
        let hostname = system.nodename().to_string_lossy();
        Ok(hostname.split('.').next().unwrap_or(&hostname).to_owned())
    }

    fn read_link(&self, path: &Path) -> Result<PathBuf> {
        fs::read_link(path)
            .with_context(|| format!("failed to resolve output link {}", path.display()))
    }

    fn run(&mut self, command: CommandSpec) -> Result<()> {
        let mut process = Command::new(&command.program);
        process.args(&command.args).envs(&command.env);
        if let Some(cwd) = &command.cwd {
            process.current_dir(cwd);
        }
        let status = process
            .status()
            .with_context(|| format!("failed to execute {}", command.program.display()))?;
        if !status.success() {
            bail!(
                "{} exited with {status}",
                format_command(&command.program, &command.args)
            );
        }
        Ok(())
    }

    fn target_os(&self) -> TargetOs {
        if cfg!(target_os = "macos") {
            TargetOs::Darwin
        } else {
            TargetOs::Linux
        }
    }

    fn use_sudo_askpass(&self) -> bool {
        self.target_os() == TargetOs::Darwin
            && env::var_os("SSH_CONNECTION").is_some()
            && io::stdin().is_terminal()
            && io::stdout().is_terminal()
            && Path::new("/etc/pam.d/sudo_ssh_password").is_file()
    }
}

pub fn deploy(backend: &mut impl Backend, request: &DeployRequest) -> Result<()> {
    validate_request(backend, request)?;
    let _gc_roots = protect_deployment_paths(backend, &request.source)?;
    ensure_free_space(backend, request.min_free_gib, request.gc_headroom_gib)?;

    match backend.target_os() {
        TargetOs::Darwin => deploy_darwin(backend, request),
        TargetOs::Linux => deploy_linux(backend, request),
    }
}

fn protect_deployment_paths(
    backend: &mut impl Backend,
    source: &Path,
) -> Result<tempfile::TempDir> {
    let directory = tempfile::tempdir().context("failed to create deployment GC root directory")?;
    let executable = backend.current_exe()?;
    let helper = enclosing_store_path(&executable).with_context(|| {
        format!(
            "deploy helper executable {} is not in the Nix store",
            executable.display()
        )
    })?;
    add_gc_root(backend, &directory, "helper", &helper)?;
    if source.starts_with(NIX_STORE) {
        add_gc_root(backend, &directory, "source", source)?;
    }
    Ok(directory)
}

fn add_gc_root(
    backend: &mut impl Backend,
    directory: &tempfile::TempDir,
    name: &str,
    path: &Path,
) -> Result<()> {
    backend.run(CommandSpec::new(DEPLOY_NIX_STORE).args([
        "--add-root".to_owned(),
        directory.path().join(name).display().to_string(),
        "--indirect".to_owned(),
        "--realise".to_owned(),
        path.display().to_string(),
    ]))
}

fn enclosing_store_path(path: &Path) -> Option<PathBuf> {
    path.ancestors()
        .find(|ancestor| ancestor.parent() == Some(Path::new(NIX_STORE)))
        .map(Path::to_path_buf)
}

pub fn activate_darwin(backend: &mut impl Backend, system_config: &Path) -> Result<()> {
    if backend.target_os() != TargetOs::Darwin {
        bail!("Darwin activation is only supported on macOS");
    }
    if !system_config.is_absolute() {
        bail!("Darwin system configuration must be an absolute store path");
    }

    backend.run(CommandSpec::new(DEPLOY_NIX).args([
        "build".to_owned(),
        "--no-link".to_owned(),
        "--profile".to_owned(),
        "/nix/var/nix/profiles/system".to_owned(),
        system_config.display().to_string(),
    ]))?;
    backend.run(CommandSpec::new(system_config.join("sw/bin/darwin-rebuild")).args(["activate"]))
}

pub fn askpass(prompt: &OsStr) -> Result<()> {
    let mut tty = OpenOptions::new()
        .read(true)
        .write(true)
        .open("/dev/tty")
        .context("failed to open /dev/tty for the sudo password prompt")?;
    write!(tty, "{}", prompt.to_string_lossy())?;
    tty.flush()?;

    let saved = termios::tcgetattr(&tty).context("failed to read terminal settings")?;
    let mut hidden = saved.clone();
    hidden.local_modes.remove(LocalModes::ECHO);
    termios::tcsetattr(&tty, OptionalActions::Now, &hidden)
        .context("failed to disable terminal echo")?;
    let guard = TerminalGuard { saved, tty: &tty };

    let mut password = String::new();
    BufReader::new(tty.try_clone()?)
        .read_line(&mut password)
        .context("failed to read the sudo password")?;
    drop(guard);
    writeln!(tty)?;
    print!("{password}");
    io::stdout().flush()?;
    Ok(())
}

struct TerminalGuard<'a> {
    saved: Termios,
    tty: &'a File,
}

impl Drop for TerminalGuard<'_> {
    fn drop(&mut self) {
        let _ = termios::tcsetattr(self.tty, OptionalActions::Now, &self.saved);
    }
}

fn validate_request(backend: &impl Backend, request: &DeployRequest) -> Result<()> {
    if !request.source.join("flake.nix").is_file() {
        bail!(
            "deployment source {} does not contain flake.nix",
            request.source.display()
        );
    }

    let actual = backend.hostname()?;
    if actual != request.expected_runtime_host {
        bail!(
            "refusing to deploy {}: SSH landed on {actual}, expected {}",
            request.config_name,
            request.expected_runtime_host
        );
    }

    if backend.target_os() == TargetOs::Darwin && request.action != DeployAction::Switch {
        bail!("unsupported deploy action on Darwin; use --action switch");
    }
    Ok(())
}

fn ensure_free_space(
    backend: &mut impl Backend,
    min_free_gib: u64,
    gc_headroom_gib: u64,
) -> Result<()> {
    let store = Path::new("/nix/store");
    let mut available = backend.available_bytes(store)?;
    eprintln!(
        "Available disk on {}: {:.1} GiB",
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
    eprintln!(
        "Low disk space (<{min_free_gib} GiB). Running bounded garbage collection for {:.1} GiB.",
        gib(target)
    );
    run_sudo(
        backend,
        CommandSpec::new(DEPLOY_NIX_COLLECT_GARBAGE).args([
            "-d".to_owned(),
            "--max-freed".to_owned(),
            format!("{}K", bytes_to_kib(target)),
        ]),
    )?;

    available = backend.available_bytes(store)?;
    eprintln!("Available disk after cleanup: {:.1} GiB", gib(available));
    if available < minimum {
        eprintln!("Bounded garbage collection was insufficient; running full cleanup.");
        run_sudo(
            backend,
            CommandSpec::new(DEPLOY_NIX_COLLECT_GARBAGE).args(["-d"]),
        )?;
    }
    Ok(())
}

fn deploy_linux(backend: &mut impl Backend, request: &DeployRequest) -> Result<()> {
    let flake = format!("path:.#{}", request.config_name);
    match request.action {
        DeployAction::DryActivate => {
            let mut command = CommandSpec::new(NIXOS_REBUILD)
                .args(["dry-activate", "--flake", &flake, "-L", "--show-trace"])
                .cwd(&request.source);
            if request.no_inhibit {
                command = command.env("NIXOS_NO_CHECK", "1");
            }
            run_sudo(backend, command)
        }
        DeployAction::Switch | DeployAction::Boot => {
            let action = match request.action {
                DeployAction::Switch => "switch",
                DeployAction::Boot => "boot",
                DeployAction::DryActivate => unreachable!(),
            };
            let mut command = CommandSpec::new(DEPLOY_NH)
                .args([
                    "os",
                    action,
                    "--hostname",
                    &request.config_name,
                    "--print-build-logs",
                    "--show-trace",
                    "path:.#",
                ])
                .cwd(&request.source);
            if request.no_inhibit {
                command = command.env("NIXOS_NO_CHECK", "1");
            }
            backend.run(command)
        }
    }
}

fn deploy_darwin(backend: &mut impl Backend, request: &DeployRequest) -> Result<()> {
    let temporary = tempfile::tempdir().context("failed to create Darwin build directory")?;
    let out_link = temporary.path().join("system");
    backend.run(
        CommandSpec::new(DEPLOY_NH)
            .args([
                "darwin".to_owned(),
                "build".to_owned(),
                "--hostname".to_owned(),
                request.config_name.clone(),
                "--out-link".to_owned(),
                out_link.display().to_string(),
                "--diff".to_owned(),
                "auto".to_owned(),
                "--print-build-logs".to_owned(),
                "--show-trace".to_owned(),
                "path:.#".to_owned(),
            ])
            .cwd(&request.source),
    )?;
    let system_config = backend.read_link(&out_link)?;
    run_sudo(
        backend,
        CommandSpec::new(backend.current_exe()?).args([
            "activate-darwin".to_owned(),
            "--system-config".to_owned(),
            system_config.display().to_string(),
        ]),
    )
}

fn run_sudo(backend: &mut impl Backend, command: CommandSpec) -> Result<()> {
    let mut sudo = CommandSpec::new(SUDO);
    if backend.use_sudo_askpass() {
        sudo.args.push("-A".to_owned());
        sudo.env.insert(
            "SUDO_ASKPASS".to_owned(),
            backend.current_exe()?.display().to_string(),
        );
        sudo.env
            .insert("FLEET_DEPLOY_ASKPASS".to_owned(), "1".to_owned());
    }
    for (name, value) in command.env {
        sudo.args.push(format!("{name}={value}"));
    }
    sudo.args.push(command.program.display().to_string());
    sudo.args.extend(command.args);
    sudo.cwd = command.cwd;
    backend.run(sudo)
}

fn bytes_to_kib(bytes: u64) -> u64 {
    bytes.div_ceil(1024)
}

fn gib(bytes: u64) -> f64 {
    bytes as f64 / GIB as f64
}

fn format_command(program: &Path, args: &[String]) -> String {
    std::iter::once(program.display().to_string())
        .chain(args.iter().cloned())
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;

    use super::*;

    struct FakeBackend {
        available: VecDeque<u64>,
        commands: Vec<CommandSpec>,
        current_exe: PathBuf,
        hostname: String,
        os: TargetOs,
        output_link: PathBuf,
        use_askpass: bool,
    }

    impl FakeBackend {
        fn new(os: TargetOs) -> Self {
            Self {
                available: VecDeque::from([40 * GIB]),
                commands: Vec::new(),
                current_exe: PathBuf::from("/nix/store/deploy/bin/fleet-deploy-remote"),
                hostname: "beast".to_owned(),
                os,
                output_link: PathBuf::from("/nix/store/system"),
                use_askpass: false,
            }
        }
    }

    impl Backend for FakeBackend {
        fn available_bytes(&mut self, _path: &Path) -> Result<u64> {
            self.available
                .pop_front()
                .context("test did not provide enough disk readings")
        }

        fn current_exe(&self) -> Result<PathBuf> {
            Ok(self.current_exe.clone())
        }

        fn hostname(&self) -> Result<String> {
            Ok(self.hostname.clone())
        }

        fn read_link(&self, _path: &Path) -> Result<PathBuf> {
            Ok(self.output_link.clone())
        }

        fn run(&mut self, command: CommandSpec) -> Result<()> {
            self.commands.push(command);
            Ok(())
        }

        fn target_os(&self) -> TargetOs {
            self.os
        }

        fn use_sudo_askpass(&self) -> bool {
            self.use_askpass
        }
    }

    fn source() -> tempfile::TempDir {
        let directory = tempfile::tempdir().expect("temporary source should be created");
        File::create(directory.path().join("flake.nix")).expect("fixture flake should be created");
        directory
    }

    fn request(source: &Path) -> DeployRequest {
        DeployRequest {
            action: DeployAction::Switch,
            config_name: "beast".to_owned(),
            expected_runtime_host: "beast".to_owned(),
            gc_headroom_gib: 5,
            min_free_gib: 30,
            no_inhibit: false,
            source: source.to_path_buf(),
        }
    }

    #[test]
    fn rejects_a_mismatched_runtime_host_before_running_commands() {
        let source = source();
        let mut backend = FakeBackend::new(TargetOs::Linux);
        backend.hostname = "other".to_owned();

        let error = deploy(&mut backend, &request(source.path())).unwrap_err();

        assert!(error.to_string().contains("SSH landed on other"));
        assert!(backend.commands.is_empty());
    }

    #[test]
    fn runs_bounded_then_full_gc_when_space_stays_low() {
        let source = source();
        let mut backend = FakeBackend::new(TargetOs::Linux);
        backend.available = VecDeque::from([10 * GIB, 20 * GIB]);

        deploy(&mut backend, &request(source.path())).expect("deployment should succeed");

        assert_eq!(backend.commands[0].program, Path::new(DEPLOY_NIX_STORE));
        assert_eq!(backend.commands[1].program, Path::new(SUDO));
        assert!(backend.commands[1].args.contains(&"--max-freed".to_owned()));
        assert_eq!(backend.commands[2].args.last().unwrap(), "-d");
        assert_eq!(backend.commands[3].program, Path::new(DEPLOY_NH));
    }

    #[test]
    fn runs_nixos_switch_with_pinned_nh_and_inhibitor_override() {
        let source = source();
        let mut backend = FakeBackend::new(TargetOs::Linux);
        let mut request = request(source.path());
        request.no_inhibit = true;

        deploy(&mut backend, &request).expect("deployment should succeed");

        assert_eq!(backend.commands.len(), 2);
        assert_eq!(backend.commands[1].program, Path::new(DEPLOY_NH));
        assert_eq!(backend.commands[1].args[0..2], ["os", "switch"]);
        assert_eq!(backend.commands[1].env["NIXOS_NO_CHECK"], "1");
        assert_eq!(backend.commands[1].cwd.as_deref(), Some(source.path()));
    }

    #[test]
    fn dry_activation_uses_sudo_and_preserves_the_override() {
        let source = source();
        let mut backend = FakeBackend::new(TargetOs::Linux);
        let mut request = request(source.path());
        request.action = DeployAction::DryActivate;
        request.no_inhibit = true;

        deploy(&mut backend, &request).expect("deployment should succeed");

        assert_eq!(backend.commands[1].program, Path::new(SUDO));
        assert_eq!(backend.commands[1].args[0], "NIXOS_NO_CHECK=1");
        assert_eq!(backend.commands[1].args[1], NIXOS_REBUILD);
        assert!(backend.commands[1]
            .args
            .contains(&"path:.#beast".to_owned()));
    }

    #[test]
    fn rejects_non_switch_actions_on_darwin() {
        let source = source();
        let mut backend = FakeBackend::new(TargetOs::Darwin);
        let mut request = request(source.path());
        request.action = DeployAction::Boot;

        let error = deploy(&mut backend, &request).unwrap_err();

        assert!(error.to_string().contains("unsupported deploy action"));
        assert!(backend.commands.is_empty());
    }

    #[test]
    fn darwin_builds_then_activates_once_through_sudo_askpass() {
        let source = source();
        let mut backend = FakeBackend::new(TargetOs::Darwin);
        backend.hostname = "mair".to_owned();
        backend.use_askpass = true;
        let mut request = request(source.path());
        request.config_name = "mair".to_owned();
        request.expected_runtime_host = "mair".to_owned();

        deploy(&mut backend, &request).expect("deployment should succeed");

        assert_eq!(backend.commands.len(), 3);
        assert_eq!(backend.commands[1].args[0..2], ["darwin", "build"]);
        assert_eq!(backend.commands[2].program, Path::new(SUDO));
        assert_eq!(backend.commands[2].args[0], "-A");
        assert_eq!(
            backend.commands[2].env["SUDO_ASKPASS"],
            backend.current_exe.display().to_string()
        );
        assert!(backend.commands[2]
            .args
            .contains(&"activate-darwin".to_owned()));
    }

    #[test]
    fn finds_the_enclosing_nix_store_path() {
        assert_eq!(
            enclosing_store_path(Path::new(
                "/nix/store/abc-fleet-tools/bin/.fleet-deploy-remote-wrapped"
            )),
            Some(PathBuf::from("/nix/store/abc-fleet-tools"))
        );
        assert_eq!(enclosing_store_path(Path::new("/tmp/helper")), None);
    }

    #[test]
    fn protects_the_helper_and_source_with_indirect_gc_roots() {
        let mut backend = FakeBackend::new(TargetOs::Linux);

        let _roots = protect_deployment_paths(&mut backend, Path::new("/nix/store/source"))
            .expect("deployment paths should be protected");

        assert_eq!(backend.commands.len(), 2);
        assert!(backend
            .commands
            .iter()
            .all(|command| command.program == Path::new(DEPLOY_NIX_STORE)));
        assert!(backend
            .commands
            .iter()
            .all(|command| command.args.contains(&"--indirect".to_owned())));
        assert_eq!(
            backend.commands[0].args.last().unwrap(),
            "/nix/store/deploy"
        );
        assert_eq!(
            backend.commands[1].args.last().unwrap(),
            "/nix/store/source"
        );
    }

    #[test]
    fn privileged_darwin_activation_updates_profile_then_activates() {
        let mut backend = FakeBackend::new(TargetOs::Darwin);
        let system = Path::new("/nix/store/system");

        activate_darwin(&mut backend, system).expect("activation should succeed");

        assert_eq!(backend.commands.len(), 2);
        assert_eq!(backend.commands[0].program, Path::new(DEPLOY_NIX));
        assert_eq!(
            backend.commands[1].program,
            system.join("sw/bin/darwin-rebuild")
        );
        assert_eq!(backend.commands[1].args, ["activate"]);
    }
}
