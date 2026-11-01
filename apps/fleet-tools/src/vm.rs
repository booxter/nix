use std::collections::BTreeMap;
use std::path::PathBuf;
use std::process::Command;

use anyhow::{bail, Context, Result};
use clap::Parser;
use serde::Deserialize;

const NIX_PROGRAM: &str = match option_env!("VM_NIX") {
    Some(path) => path,
    None => "nix",
};
const RUNNER_NIX: &str = env!("VM_RUNNER_NIX");
const TARGETS_JSON: &str = env!("VM_TARGETS_JSON");
const MACOS_RUNNER: &str = env!("VM_MACOS_RUNNER");

#[derive(Debug, Parser)]
#[command(
    version,
    about = "Run a local NixOS or Darwin configuration, or a plain macOS VM",
    after_help = env!("VM_HELP")
)]
pub struct VmArgs {
    /// Enable VM graphics.
    #[arg(long)]
    pub gui: bool,

    /// Recreate the macOS working disk from its cached base (discards guest changes).
    #[arg(long)]
    pub reset: bool,

    /// NixOS or Darwin configuration, or macos for a plain macOS VM.
    #[arg(value_name = "TARGET")]
    pub target_host: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum VmTarget {
    Nixos(String),
    Darwin(String),
    Macos,
}

#[derive(Deserialize)]
pub struct VmTargets {
    pub nixos: BTreeMap<String, String>,
    pub darwin: BTreeMap<String, String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VmRequest {
    pub target: VmTarget,
    pub gui: bool,
    pub reset: bool,
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
        match &request.target {
            VmTarget::Nixos(configuration) => {
                self.run_configuration("nixos", configuration, request)
            }
            VmTarget::Darwin(configuration) => {
                self.run_configuration("darwin", configuration, request)
            }
            VmTarget::Macos => self.run_macos(request),
        }
    }
}

impl NativeVmRunner {
    fn run_macos(&self, request: &VmRequest) -> Result<i32> {
        // Replace this dispatcher so signals reach the lifecycle owner directly.
        use std::os::unix::process::CommandExt;

        let mut command = Command::new(MACOS_RUNNER);
        command.arg("--checkout").arg(&self.repo_root);
        if request.gui {
            command.arg("--gui");
        }
        if request.reset {
            command.arg("--reset");
        }
        Err(command.exec()).context("failed to start the macOS VM runner")
    }

    fn run_configuration(
        &self,
        kind: &str,
        configuration: &str,
        request: &VmRequest,
    ) -> Result<i32> {
        let mut command = Command::new(&self.nix);
        command
            .args([
                "run",
                "--option",
                "min-free",
                "0",
                "--impure",
                "--file",
                self.runner_nix
                    .to_str()
                    .context("VM runner path is not UTF-8")?,
                "-L",
                "--show-trace",
            ])
            .env("VM_REPO_ROOT", &self.repo_root)
            .env("VM_TARGET_CONFIG", configuration)
            .env("VM_TARGET_KIND", kind)
            .env("VM_GUI", if request.gui { "1" } else { "0" });

        if kind == "darwin" {
            use std::os::unix::process::CommandExt;

            // With --file, select the root value before passing program arguments.
            command
                .arg("")
                .arg("--")
                .arg("--checkout")
                .arg(&self.repo_root);
            if request.gui {
                command.arg("--gui");
            }
            if request.reset {
                command.arg("--reset");
            }
            // Keep the terminal attached to the lifecycle owner during shutdown.
            return Err(command.exec()).context("failed to start the Darwin VM runner");
        }

        let status = command
            .status()
            .with_context(|| format!("failed to start {}", self.nix.display()))?;
        status
            .code()
            .context("Nix VM runner terminated without an exit status")
    }
}

pub fn compiled_targets() -> Result<VmTargets> {
    serde_json::from_str(TARGETS_JSON).context("compiled VM target inventory is invalid")
}

pub fn run(arguments: VmArgs, runner: &impl VmRunner) -> Result<i32> {
    let targets = compiled_targets()?;
    let target = if arguments.target_host == "macos" {
        VmTarget::Macos
    } else if let Some(configuration) = targets.darwin.get(&arguments.target_host) {
        VmTarget::Darwin(configuration.clone())
    } else if let Some(configuration) = targets.nixos.get(&arguments.target_host) {
        if arguments.reset {
            bail!("--reset is supported only for macOS VMs");
        }
        VmTarget::Nixos(configuration.clone())
    } else {
        let known = targets
            .nixos
            .keys()
            .chain(targets.darwin.keys())
            .cloned()
            .collect::<Vec<_>>()
            .join(", ");
        bail!(
            "unknown target: {}; available targets: macos, {known}",
            arguments.target_host
        );
    };
    runner.run(&VmRequest {
        target,
        gui: arguments.gui,
        reset: arguments.reset,
    })
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;

    use anyhow::Result;
    use clap::{CommandFactory, Parser};

    use super::{compiled_targets, run, VmArgs, VmRequest, VmRunner, VmTarget};

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

        for target in ["builder1", "srvarr", "beast", "prx1-lab", "macos"] {
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
                reset: false,
                target_host: "builder1".to_owned(),
            },
            &runner,
        )
        .expect("known target should run");

        assert_eq!(code, 7);
        assert_eq!(
            *runner.requests.borrow(),
            [VmRequest {
                target: VmTarget::Nixos(
                    compiled_targets().expect("targets should parse").nixos["builder1"].clone()
                ),
                gui: true,
                reset: false,
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
                reset: false,
                target_host: "does-not-exist".to_owned(),
            },
            &runner,
        )
        .expect_err("unknown target should fail");

        assert!(error.to_string().contains("unknown target: does-not-exist"));
        assert!(runner.requests.borrow().is_empty());
    }

    #[test]
    fn clap_rejects_missing_target_and_unknown_options() {
        assert!(VmArgs::try_parse_from(["vm"]).is_err());
        assert!(VmArgs::try_parse_from(["vm", "--unknown", "builder1"]).is_err());
    }

    #[test]
    fn macos_selects_its_backend_with_reset_and_graphics() {
        let runner = FakeRunner {
            exit_code: 0,
            requests: RefCell::new(Vec::new()),
        };
        let arguments = VmArgs::try_parse_from(["vm", "--reset", "--gui", "macos"]).unwrap();
        assert_eq!(run(arguments, &runner).unwrap(), 0);
        assert_eq!(
            *runner.requests.borrow(),
            [VmRequest {
                target: VmTarget::Macos,
                gui: true,
                reset: true,
            }]
        );
    }

    #[test]
    fn reset_cannot_discard_a_nixos_disk() {
        let runner = FakeRunner {
            exit_code: 0,
            requests: RefCell::new(Vec::new()),
        };
        let arguments = VmArgs::try_parse_from(["vm", "--reset", "builder1"]).unwrap();
        assert!(run(arguments, &runner)
            .unwrap_err()
            .to_string()
            .contains("only for macOS"));
        assert!(runner.requests.borrow().is_empty());
    }

    #[test]
    fn darwin_configuration_supports_reset_and_graphics() {
        let runner = FakeRunner {
            exit_code: 0,
            requests: RefCell::new(Vec::new()),
        };
        let arguments = VmArgs::try_parse_from(["vm", "--reset", "--gui", "vm-test"]).unwrap();
        assert_eq!(run(arguments, &runner).unwrap(), 0);
        assert_eq!(
            *runner.requests.borrow(),
            [VmRequest {
                target: VmTarget::Darwin("vm-test".to_owned()),
                gui: true,
                reset: true,
            }]
        );
    }
}
