use std::env;
use std::ffi::OsStr;
use std::path::PathBuf;
use std::process::ExitCode;

use anyhow::Result;
use clap::{Parser, Subcommand};
use fleet_tools::deploy_remote::{
    activate_darwin, askpass, deploy, DeployAction, DeployRequest, SystemBackend,
};

#[derive(Debug, Parser)]
#[command(version, about = "Activate a fleet configuration on its target host")]
struct Arguments {
    #[command(subcommand)]
    command: FleetCommand,
}

#[derive(Debug, Subcommand)]
enum FleetCommand {
    Deploy {
        #[arg(long, value_enum)]
        action: DeployAction,
        #[arg(long)]
        config_name: String,
        #[arg(long)]
        expected_runtime_host: String,
        #[arg(long, default_value_t = 5)]
        gc_headroom_gib: u64,
        #[arg(long, default_value_t = 30)]
        min_free_gib: u64,
        #[arg(long)]
        no_inhibit: bool,
        #[arg(long)]
        source: PathBuf,
    },
    #[command(hide = true)]
    ActivateDarwin {
        #[arg(long)]
        system_config: PathBuf,
    },
}

fn main() -> ExitCode {
    if env::var_os("FLEET_DEPLOY_ASKPASS").is_some() {
        return report(askpass(
            env::args_os()
                .nth(1)
                .as_deref()
                .unwrap_or_else(|| OsStr::new("Password:")),
        ));
    }
    report(execute(Arguments::parse()))
}

fn execute(arguments: Arguments) -> Result<()> {
    let mut backend = SystemBackend;
    match arguments.command {
        FleetCommand::Deploy {
            action,
            config_name,
            expected_runtime_host,
            gc_headroom_gib,
            min_free_gib,
            no_inhibit,
            source,
        } => deploy(
            &mut backend,
            &DeployRequest {
                action,
                config_name,
                expected_runtime_host,
                gc_headroom_gib,
                min_free_gib,
                no_inhibit,
                source,
            },
        ),
        FleetCommand::ActivateDarwin { system_config } => {
            activate_darwin(&mut backend, &system_config)
        }
    }
}

fn report(result: Result<()>) -> ExitCode {
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("fleet-deploy-remote: {error:#}");
            ExitCode::FAILURE
        }
    }
}
