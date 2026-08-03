use std::io;
use std::process::ExitCode;

use anyhow::Result;
use clap::Parser;
use fleet_tools::wireguard::{run, SshPublicKeyFetcher, WireguardArgs};

fn main() -> ExitCode {
    match execute() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("wg-home-client-config: {error:#}");
            ExitCode::FAILURE
        }
    }
}

fn execute() -> Result<()> {
    run(
        WireguardArgs::parse(),
        &SshPublicKeyFetcher::default(),
        &mut io::stdout().lock(),
    )
}
