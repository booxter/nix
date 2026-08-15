use std::process::ExitCode;

use anyhow::Result;
use clap::Parser;
use kanidm_tools::person_mail::{run, PersonMailArgs};

fn main() -> ExitCode {
    match execute() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("kanidm-person-mail-provision: {error:#}");
            ExitCode::FAILURE
        }
    }
}

fn execute() -> Result<()> {
    run(PersonMailArgs::parse())
}
