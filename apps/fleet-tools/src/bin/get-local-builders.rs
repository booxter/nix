use std::env;
use std::path::PathBuf;
use std::process::ExitCode;

use clap::Parser;
use fleet_tools::local_builders::{
    local_builders, read_builders, DEFAULT_NIX_CONF, DEFAULT_NIX_MACHINES,
};

#[derive(Debug, Parser)]
#[command(version, about = "Read local Nix builders from configuration files")]
struct Arguments {
    /// Print only exact localhost entries.
    #[arg(long)]
    local: bool,
}

fn main() -> ExitCode {
    let arguments = Arguments::parse();
    let nix_conf = env::var_os("NIX_CONF")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(DEFAULT_NIX_CONF));
    let nix_machines = env::var_os("NIX_MACHINES")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(DEFAULT_NIX_MACHINES));

    if let Some(builders) = read_builders(&nix_conf, &nix_machines) {
        let output = if arguments.local {
            local_builders(&builders)
        } else {
            builders
        };
        if !output.is_empty() {
            println!("{output}");
        }
    }

    ExitCode::SUCCESS
}
