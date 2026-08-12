use std::io;
use std::path::Path;
use std::process::ExitCode;

use anyhow::{Context, Result};
use clap::Parser;
use kanidm_tools::{
    discover_repo_root, load_provider_inventory, query_provider_inventory, run_client, ClientArgs,
    SshTransport,
};

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
    let inventory_path = std::env::var("RESET_OIDC_PROVIDERS_FILE")
        .context("RESET_OIDC_PROVIDERS_FILE is not configured")?;
    let mut providers = load_provider_inventory(Path::new(&inventory_path))?;
    if providers.is_empty() {
        let query_path = std::env::var("RESET_OIDC_PROVIDERS_QUERY_FILE")
            .context("RESET_OIDC_PROVIDERS_QUERY_FILE is not configured")?;
        let current_dir = std::env::current_dir().context("failed to read current directory")?;
        providers =
            query_provider_inventory(Path::new(&query_path), &discover_repo_root(&current_dir)?)?;
    }
    run_client(
        arguments,
        &providers,
        &SshTransport::default(),
        &mut io::stdout().lock(),
    )
}
