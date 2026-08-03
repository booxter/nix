use std::env;
use std::io;
use std::process::ExitCode;

use clap::Parser;
use fleet_tools::check_target::{run, CheckTargetOptions, SystemBackend};

const CURRENT_SYSTEM: &str = env!("CHECK_SYSTEM");

#[derive(Debug, Parser)]
#[command(
    version,
    about = "Build repository checks by name or as a complete set"
)]
struct Arguments {
    /// Top-level flake attribute containing system-keyed checks.
    flake_attribute: String,

    /// Plural label used in user-facing messages.
    label_plural: String,

    /// Singular label used in user-facing messages.
    label_singular: String,
}

fn main() -> ExitCode {
    let arguments = Arguments::parse();
    let options = CheckTargetOptions {
        flake_attribute: arguments.flake_attribute,
        label_plural: arguments.label_plural,
        label_singular: arguments.label_singular,
        remote: env::var("REMOTE").map_or(true, |value| value != "false"),
        what: env::var("WHAT").ok(),
    };
    let mut backend = SystemBackend::from_environment();
    match run(
        &options,
        CURRENT_SYSTEM,
        &mut backend,
        &mut io::stdout().lock(),
    ) {
        Ok(status) => u8::try_from(status)
            .map(ExitCode::from)
            .unwrap_or(ExitCode::FAILURE),
        Err(error) => {
            eprintln!("run-check-target: {error:#}");
            ExitCode::FAILURE
        }
    }
}
