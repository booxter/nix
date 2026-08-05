use std::process::ExitCode;

use anyhow::Result;
use clap::Parser;
use kanidm_tools::mail_sender_config::{run, ConfigWriterArgs};

fn main() -> ExitCode {
    match execute() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("kanidm-mail-sender-write-config: {error:#}");
            ExitCode::FAILURE
        }
    }
}

fn execute() -> Result<()> {
    run(ConfigWriterArgs::parse())
}
