use std::io;
use std::process::ExitCode;

use clap::Parser;
use fleet_tools::compiled_inventory;
use fleet_tools::deploy::{run, DeployArgs, SystemBackend};

fn main() -> ExitCode {
    let inventory = match compiled_inventory() {
        Ok(inventory) => inventory,
        Err(error) => {
            eprintln!("deploy: compiled fleet inventory is invalid: {error}");
            return ExitCode::FAILURE;
        }
    };
    let mut backend = match SystemBackend::from_environment(&inventory) {
        Ok(backend) => backend,
        Err(error) => {
            eprintln!("deploy: {error:#}");
            return ExitCode::FAILURE;
        }
    };
    match run(
        DeployArgs::parse(),
        &inventory,
        &mut backend,
        &mut io::stdout().lock(),
    ) {
        Ok(true) => ExitCode::SUCCESS,
        Ok(false) => ExitCode::FAILURE,
        Err(error) => {
            eprintln!("deploy: {error:#}");
            ExitCode::FAILURE
        }
    }
}
