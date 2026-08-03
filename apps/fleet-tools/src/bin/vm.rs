use std::process::ExitCode;

use anyhow::Result;
use clap::Parser;
use fleet_tools::vm::{run, NativeVmRunner, VmArgs};

fn main() -> ExitCode {
    match execute() {
        Ok(code) => u8::try_from(code)
            .map(ExitCode::from)
            .unwrap_or(ExitCode::FAILURE),
        Err(error) => {
            eprintln!("vm: {error:#}");
            ExitCode::FAILURE
        }
    }
}

fn execute() -> Result<i32> {
    run(VmArgs::parse(), &NativeVmRunner::default())
}
