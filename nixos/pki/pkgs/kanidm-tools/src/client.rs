use std::fs;
use std::path::Path;

use anyhow::{anyhow, ensure, Context, Result};
use kanidm_client::{ClientError, KanidmClient, KanidmClientBuilder};
use zeroize::Zeroizing;

const ADMIN_ID: &str = "idm_admin";

pub(crate) fn client_error(context: &str, error: ClientError) -> anyhow::Error {
    anyhow!("{context}: {error:?}")
}

fn read_password(path: &Path) -> Result<Zeroizing<String>> {
    let mut password = Zeroizing::new(
        fs::read_to_string(path).with_context(|| format!("failed to read {}", path.display()))?,
    );
    while matches!(password.as_bytes().last(), Some(b'\n' | b'\r')) {
        password.pop();
    }
    ensure!(!password.is_empty(), "Kanidm admin password is empty");
    Ok(password)
}

async fn authenticate(client: KanidmClient, password_path: &Path) -> Result<KanidmClient> {
    let password = read_password(password_path)?;
    client
        .auth_simple_password(ADMIN_ID, &password)
        .await
        .map_err(|error| client_error("Kanidm authentication failed", error))?;
    Ok(client)
}

pub(crate) async fn authenticated_from_config(
    config_path: &Path,
    password_path: &Path,
) -> Result<KanidmClient> {
    let client = KanidmClientBuilder::new()
        .read_options_from_optional_config(config_path)
        .map_err(|error| client_error("failed to read Kanidm client configuration", error))?
        .build()
        .map_err(|error| client_error("failed to build Kanidm client", error))?;
    authenticate(client, password_path).await
}

pub(crate) async fn authenticated_at_address(
    address: &str,
    password_path: &Path,
) -> Result<KanidmClient> {
    let client = KanidmClientBuilder::new()
        .address(address.trim_end_matches('/').to_owned())
        .build()
        .map_err(|error| client_error("failed to build Kanidm client", error))?;
    authenticate(client, password_path).await
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::read_password;

    #[test]
    fn password_reader_removes_line_endings() {
        let directory = tempfile::tempdir().expect("temporary directory should be created");
        let path = directory.path().join("password");
        fs::write(&path, "secret\r\n\n").expect("password should be written");

        let password = read_password(&path).expect("password should be read");

        assert_eq!(password.as_str(), "secret");
    }

    #[test]
    fn password_reader_rejects_empty_secret() {
        let directory = tempfile::tempdir().expect("temporary directory should be created");
        let path = directory.path().join("password");
        fs::write(&path, "\n").expect("password should be written");

        let error = read_password(&path).expect_err("empty password should fail");

        assert!(error.to_string().contains("password is empty"));
    }
}
