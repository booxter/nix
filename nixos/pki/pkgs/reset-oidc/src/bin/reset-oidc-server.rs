use std::io;
use std::path::Path;
use std::process::ExitCode;

use anyhow::Result;
use reset_oidc::{run_server, send_with_kanidm};

const CONFIG_PATH: &str = "/etc/kanidm/config";
const PASSWORD_PATH: &str = "/run/secrets/kanidmIdmAdminPassword";

#[tokio::main]
async fn main() -> ExitCode {
    match run().await {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("reset-oidc-server: {error:#}");
            ExitCode::FAILURE
        }
    }
}

async fn run() -> Result<()> {
    run_server(io::stdin().lock(), |request| {
        send_with_kanidm(request, Path::new(CONFIG_PATH), Path::new(PASSWORD_PATH))
    })
    .await
}
