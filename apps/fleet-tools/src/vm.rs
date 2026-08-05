use std::collections::BTreeMap;
use std::path::PathBuf;
use std::process::Command;

use anyhow::{bail, Context, Result};
use clap::Parser;

const NIX_PROGRAM: &str = match option_env!("VM_NIX") {
    Some(path) => path,
    None => "nix",
};
const RUNNER_NIX: &str = env!("VM_RUNNER_NIX");
const TARGETS_JSON: &str = env!("VM_TARGETS_JSON");

#[derive(Debug, Parser)]
#[command(
    version,
    about = "Run a local VM for a NixOS fleet host",
    after_help = env!("VM_HELP")
)]
pub struct VmArgs {
    /// Enable VM graphics.
    #[arg(long)]
    pub gui: bool,

    /// Inventory host whose NixOS VM variant should run.
    #[arg(value_name = "TARGET_HOST")]
    pub target_host: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VmRequest {
    pub target_config: String,
    pub gui: bool,
}

pub trait VmRunner {
    fn run(&self, request: &VmRequest) -> Result<i32>;
}

pub struct NativeVmRunner {
    nix: PathBuf,
    repo_root: PathBuf,
    runner_nix: PathBuf,
}

impl NativeVmRunner {
    pub fn from_current_checkout() -> Result<Self> {
        let current_directory =
            std::env::current_dir().context("failed to resolve current directory")?;
        Ok(Self {
            nix: PathBuf::from(NIX_PROGRAM),
            repo_root: crate::repository::checkout_root(&current_directory)?,
            runner_nix: PathBuf::from(RUNNER_NIX),
        })
    }
}

impl VmRunner for NativeVmRunner {
    fn run(&self, request: &VmRequest) -> Result<i32> {
        let status = Command::new(&self.nix)
            .args([
                "run",
                "--impure",
                "--file",
                self.runner_nix
                    .to_str()
                    .context("VM runner path is not UTF-8")?,
                "-L",
                "--show-trace",
            ])
            .env("VM_REPO_ROOT", &self.repo_root)
            .env("VM_TARGET_CONFIG", &request.target_config)
            .env("VM_GUI", if request.gui { "1" } else { "0" })
            .status()
            .with_context(|| format!("failed to start {}", self.nix.display()))?;
        status
            .code()
            .context("Nix VM runner terminated without an exit status")
    }
}

pub fn compiled_targets() -> Result<BTreeMap<String, String>> {
    serde_json::from_str(TARGETS_JSON).context("compiled VM target inventory is invalid")
}

pub fn run(arguments: VmArgs, runner: &impl VmRunner) -> Result<i32> {
    let targets = compiled_targets()?;
    let Some(target_config) = targets.get(&arguments.target_host) else {
        let known = targets.keys().cloned().collect::<Vec<_>>().join(", ");
        bail!(
            "unknown target host: {}; available target hosts: {known}",
            arguments.target_host
        );
    };
    runner.run(&VmRequest {
        target_config: target_config.clone(),
        gui: arguments.gui,
    })
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;

    use anyhow::Result;
    use clap::{CommandFactory, Parser};

    use super::{compiled_targets, run, VmArgs, VmRequest, VmRunner};

    struct FakeRunner {
        exit_code: i32,
        requests: RefCell<Vec<VmRequest>>,
    }

    impl VmRunner for FakeRunner {
        fn run(&self, request: &VmRequest) -> Result<i32> {
            self.requests.borrow_mut().push(request.clone());
            Ok(self.exit_code)
        }
    }

    #[test]
    fn help_lists_available_inventory_targets() {
        let help = VmArgs::command().render_long_help().to_string();

        for target in ["builder1", "srvarr", "beast", "prx1-lab"] {
            assert!(help.lines().any(|line| line.trim() == target));
        }
    }

    #[test]
    fn passes_resolved_target_and_gui_selection_to_runner() {
        let runner = FakeRunner {
            exit_code: 7,
            requests: RefCell::new(Vec::new()),
        };

        let code = run(
            VmArgs {
                gui: true,
                target_host: "builder1".to_owned(),
            },
            &runner,
        )
        .expect("known target should run");

        assert_eq!(code, 7);
        assert_eq!(
            *runner.requests.borrow(),
            [VmRequest {
                target_config: compiled_targets().expect("targets should parse")["builder1"]
                    .clone(),
                gui: true,
            }]
        );
    }

    #[test]
    fn rejects_unknown_target_without_running_nix() {
        let runner = FakeRunner {
            exit_code: 0,
            requests: RefCell::new(Vec::new()),
        };

        let error = run(
            VmArgs {
                gui: false,
                target_host: "does-not-exist".to_owned(),
            },
            &runner,
        )
        .expect_err("unknown target should fail");

        assert!(error
            .to_string()
            .contains("unknown target host: does-not-exist"));
        assert!(runner.requests.borrow().is_empty());
    }

    #[test]
    fn clap_rejects_missing_target_and_unknown_options() {
        assert!(VmArgs::try_parse_from(["vm"]).is_err());
        assert!(VmArgs::try_parse_from(["vm", "--unknown", "builder1"]).is_err());
    }
}
