use std::io;
use std::process::ExitCode;

use clap::Parser;
use fleet_tools::{compiled_inventory, select_hosts};

#[derive(Debug, Parser)]
#[command(
    version,
    about = "Print classified NixOS and Darwin fleet hosts as JSON"
)]
struct Arguments {
    /// Return only these host names. Unknown names are ignored.
    #[arg(value_name = "HOST")]
    hosts: Vec<String>,
}

fn main() -> ExitCode {
    match execute() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("get-hosts: {error}");
            ExitCode::FAILURE
        }
    }
}

fn execute() -> Result<(), Box<dyn std::error::Error>> {
    let arguments = Arguments::parse();
    let selected = select_hosts(&compiled_inventory()?, &arguments.hosts);
    serde_json::to_writer(io::stdout().lock(), &selected)?;
    println!();
    Ok(())
}
