use std::io;
use std::process::ExitCode;

use anyhow::Result;
use clap::Parser;
use kanidm_tools::mail_sender::{run, MailSenderArgs};

#[tokio::main]
async fn main() -> ExitCode {
    match execute().await {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("kanidm-mail-sender-bootstrap: {error:#}");
            ExitCode::FAILURE
        }
    }
}

async fn execute() -> Result<()> {
    run(MailSenderArgs::parse(), &mut io::stdout().lock()).await
}
