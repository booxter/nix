use std::io;
use std::process::ExitCode;

use anyhow::Result;
use clap::Parser;
use kanidm_tools::{run_client, ClientArgs, SshTransport};

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("reset-oidc: {error:#}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<()> {
    let arguments = ClientArgs::parse();
    run_client(
        arguments,
        &SshTransport::default(),
        &mut io::stdout().lock(),
    )
}
