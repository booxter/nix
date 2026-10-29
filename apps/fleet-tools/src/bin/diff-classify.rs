use std::fs;
use std::path::PathBuf;
use std::process::ExitCode;

use clap::Parser;
use fleet_tools::diff::classify;

#[derive(Debug, Parser)]
#[command(about = "Classify a configuration diff for CI reporting.")]
struct Arguments {
    /// Exit code returned by the configuration diff command.
    #[arg(long)]
    exit_code: i32,

    /// File containing the configuration diff command's stdout.
    output: PathBuf,
}

fn main() -> ExitCode {
    let arguments = Arguments::parse();
    match fs::read_to_string(&arguments.output) {
        Ok(output) => {
            println!("{}", classify(&output, arguments.exit_code));
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("Unable to read {}: {error}", arguments.output.display());
            ExitCode::FAILURE
        }
    }
}
