use std::io;
use std::process::ExitCode;

use clap::Parser;
use join_media_parts::{run, Args, FfmpegBackend};

fn main() -> ExitCode {
    let mut backend = FfmpegBackend;
    match run(
        Args::parse(),
        &mut backend,
        &mut io::stdout().lock(),
        &mut io::stderr().lock(),
    ) {
        Ok(_) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("join-media-parts: {error:#}");
            ExitCode::FAILURE
        }
    }
}
