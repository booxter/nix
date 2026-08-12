use std::collections::BTreeMap;
use std::future::Future;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use anyhow::{bail, ensure, Context, Result};
use clap::Parser;
use serde::{Deserialize, Serialize};

mod atomic;
mod client;
pub mod mail_sender;
pub mod mail_sender_config;

const PROTOCOL_VERSION: u8 = 1;
const TTL_SECONDS: u64 = 86_400;
const REMOTE_PROGRAM: &str = "/run/current-system/sw/bin/reset-oidc-server";
const SSH_PROGRAM: &str = match option_env!("RESET_OIDC_SSH") {
    Some(path) => path,
    None => "ssh",
};

#[derive(Debug, Parser)]
#[command(
    version,
    about = "Send a Kanidm OIDC credential reset email through the realm provider",
    after_help = "Example:\n  reset-oidc account-name"
)]
pub struct ClientArgs {
    /// Kanidm person account ID.
    #[arg(value_name = "USER_ID", value_parser = non_empty)]
    pub user_id: String,

    /// Send the reset to this registered alternate email address.
    #[arg(value_name = "EMAIL")]
    pub email: Option<String>,

    /// Realm whose SSO provider should handle the reset.
    #[arg(long, value_parser = non_empty)]
    pub realm: Option<String>,

    /// Explicit OpenSSH destination overriding provider discovery.
    #[arg(long, env = "RESET_OIDC_SSH_TARGET", hide_env_values = true, value_parser = ssh_target)]
    pub target: Option<String>,
}

pub type ProviderInventory = BTreeMap<String, String>;

pub fn load_provider_inventory(path: &Path) -> Result<ProviderInventory> {
    let file = std::fs::File::open(path)
        .with_context(|| format!("failed to open SSO provider inventory {}", path.display()))?;
    serde_json::from_reader(file)
        .with_context(|| format!("failed to read SSO provider inventory {}", path.display()))
}

pub fn discover_repo_root(cwd: &Path) -> Result<PathBuf> {
    cwd.ancestors()
        .find(|candidate| candidate.join("flake.nix").is_file())
        .map(Path::to_path_buf)
        .context("could not find the repository root from the current directory")
}

pub fn query_provider_inventory(query: &Path, repo_root: &Path) -> Result<ProviderInventory> {
    let output = Command::new("nix-instantiate")
        .args(["--eval", "--strict", "--json"])
        .arg(query)
        .args(["--argstr", "repo"])
        .arg(repo_root)
        .output()
        .context("failed to evaluate the SSO provider inventory")?;
    ensure!(
        output.status.success(),
        "failed to evaluate the SSO provider inventory: {}",
        String::from_utf8_lossy(&output.stderr).trim()
    );
    serde_json::from_slice(&output.stdout).context("invalid evaluated SSO provider inventory")
}

fn provider_target(arguments: &ClientArgs, providers: &ProviderInventory) -> Result<String> {
    if let Some(target) = &arguments.target {
        return Ok(target.clone());
    }
    if let Some(realm) = &arguments.realm {
        return providers
            .get(realm)
            .cloned()
            .with_context(|| format!("realm '{realm}' has no SSO provider"));
    }
    if providers.len() == 1 {
        return Ok(providers
            .first_key_value()
            .expect("one provider was present")
            .1
            .clone());
    }
    bail!("--realm is required when multiple SSO providers are configured")
}

pub(crate) fn non_empty(value: &str) -> Result<String, String> {
    if value.trim().is_empty() {
        Err("value must be non-empty".to_owned())
    } else {
        Ok(value.to_owned())
    }
}

fn ssh_target(value: &str) -> Result<String, String> {
    let value = non_empty(value)?;
    if value.starts_with('-') {
        Err("SSH target must not start with '-'".to_owned())
    } else {
        Ok(value)
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ResetRequest {
    protocol_version: u8,
    user_id: String,
    email: Option<String>,
}

impl ResetRequest {
    fn new(user_id: String, email: Option<String>) -> Self {
        Self {
            protocol_version: PROTOCOL_VERSION,
            user_id,
            email: email.filter(|value| !value.is_empty()),
        }
    }

    fn validate(&self) -> Result<()> {
        ensure!(
            self.protocol_version == PROTOCOL_VERSION,
            "unsupported reset-oidc protocol version {}",
            self.protocol_version
        );
        ensure!(!self.user_id.trim().is_empty(), "user ID must be non-empty");
        Ok(())
    }
}

pub trait ResetTransport {
    fn send(&self, target: &str, request: &ResetRequest) -> Result<()>;
}

pub struct SshTransport {
    executable: PathBuf,
}

impl Default for SshTransport {
    fn default() -> Self {
        Self {
            executable: PathBuf::from(SSH_PROGRAM),
        }
    }
}

impl ResetTransport for SshTransport {
    fn send(&self, target: &str, request: &ResetRequest) -> Result<()> {
        let encoded = serde_json::to_vec(request).context("failed to serialize reset request")?;
        let mut child = Command::new(&self.executable)
            .arg(target)
            .args(["sudo", "-n", REMOTE_PROGRAM])
            .stdin(Stdio::piped())
            .spawn()
            .with_context(|| format!("failed to start {}", self.executable.display()))?;

        let write_result = child
            .stdin
            .take()
            .context("SSH stdin was not available")?
            .write_all(&encoded);
        let status = child.wait().context("failed to wait for SSH")?;

        if !status.success() {
            bail!("SSH reset request failed with {status}");
        }
        write_result.context("failed to send reset request over SSH")
    }
}

pub fn run_client(
    arguments: ClientArgs,
    providers: &ProviderInventory,
    transport: &impl ResetTransport,
    output: &mut impl Write,
) -> Result<()> {
    let target = provider_target(&arguments, providers)?;
    let request = ResetRequest::new(arguments.user_id, arguments.email);
    transport.send(&target, &request)?;

    match &request.email {
        Some(email) => writeln!(
            output,
            "Requested OIDC credential reset email for {} at {email}.",
            request.user_id
        ),
        None => writeln!(
            output,
            "Requested OIDC credential reset email for {}.",
            request.user_id
        ),
    }
    .context("failed to write success message")
}

pub async fn run_server<R, F, Fut>(input: R, send: F) -> Result<()>
where
    R: Read,
    F: FnOnce(ResetRequest) -> Fut,
    Fut: Future<Output = Result<()>>,
{
    let request: ResetRequest =
        serde_json::from_reader(input).context("failed to read reset request")?;
    request.validate()?;
    send(request).await
}

pub async fn send_with_kanidm(
    request: ResetRequest,
    config_path: &Path,
    password_path: &Path,
) -> Result<()> {
    ensure!(
        config_path.is_file(),
        "{} is not a file",
        config_path.display()
    );

    let client = client::authenticated_from_config(config_path, password_path).await?;
    client
        .idm_person_account_credential_update_send_intent(
            &request.user_id,
            Some(TTL_SECONDS),
            request.email,
        )
        .await
        .map_err(|error| {
            client::client_error("Kanidm rejected the credential reset request", error)
        })
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::io::Cursor;

    use anyhow::{bail, Result};
    use clap::{error::ErrorKind, Parser};

    use super::{
        run_client, run_server, ClientArgs, ProviderInventory, ResetRequest, ResetTransport,
    };

    fn providers() -> ProviderInventory {
        ProviderInventory::from([("test-realm".to_owned(), "provider-node".to_owned())])
    }

    #[derive(Default)]
    struct FakeTransport {
        sent: RefCell<Vec<(String, ResetRequest)>>,
        fail: bool,
    }

    impl ResetTransport for FakeTransport {
        fn send(&self, target: &str, request: &ResetRequest) -> Result<()> {
            if self.fail {
                bail!("transport failed");
            }
            self.sent
                .borrow_mut()
                .push((target.to_owned(), request.clone()));
            Ok(())
        }
    }

    #[test]
    fn parses_existing_positional_interface() {
        let arguments =
            ClientArgs::try_parse_from(["reset-oidc", "test-user", "user@example.invalid"])
                .expect("arguments should parse");

        assert_eq!(arguments.user_id, "test-user");
        assert_eq!(arguments.email.as_deref(), Some("user@example.invalid"));
        assert_eq!(arguments.target, None);
        assert_eq!(arguments.realm, None);
    }

    #[test]
    fn rejects_empty_user_and_option_shaped_target() {
        let empty =
            ClientArgs::try_parse_from(["reset-oidc", ""]).expect_err("empty user should fail");
        assert_eq!(empty.kind(), ErrorKind::ValueValidation);

        let target = ClientArgs::try_parse_from(["reset-oidc", "--target=-V", "test-user"])
            .expect_err("option-shaped target should fail");
        assert_eq!(target.kind(), ErrorKind::ValueValidation);
    }

    #[test]
    fn client_sends_request_and_reports_selected_email() {
        let transport = FakeTransport::default();
        let arguments = ClientArgs {
            user_id: "test-user".to_owned(),
            email: Some("user@example.invalid".to_owned()),
            realm: None,
            target: None,
        };
        let mut output = Vec::new();

        run_client(arguments, &providers(), &transport, &mut output)
            .expect("client should succeed");

        let sent = transport.sent.borrow();
        assert_eq!(sent.len(), 1);
        assert_eq!(sent[0].0, "provider-node");
        assert_eq!(sent[0].1.user_id, "test-user");
        assert_eq!(sent[0].1.email.as_deref(), Some("user@example.invalid"));
        assert_eq!(
            String::from_utf8(output).expect("output should be UTF-8"),
            "Requested OIDC credential reset email for test-user at user@example.invalid.\n"
        );
    }

    #[test]
    fn client_does_not_report_success_after_transport_failure() {
        let transport = FakeTransport {
            fail: true,
            ..FakeTransport::default()
        };
        let arguments = ClientArgs {
            user_id: "test-user".to_owned(),
            email: None,
            realm: Some("test-realm".to_owned()),
            target: None,
        };
        let mut output = Vec::new();

        let error = run_client(arguments, &providers(), &transport, &mut output)
            .expect_err("transport failure should propagate");

        assert!(error.to_string().contains("transport failed"));
        assert!(output.is_empty());
    }

    #[tokio::test]
    async fn server_decodes_and_dispatches_request() {
        let input =
            Cursor::new(br#"{"protocol_version":1,"user_id":"second-user","email":null}"#.to_vec());

        run_server(input, |request| async move {
            assert_eq!(request.user_id, "second-user");
            assert_eq!(request.email, None);
            Ok(())
        })
        .await
        .expect("server should dispatch request");
    }

    #[tokio::test]
    async fn server_rejects_wrong_protocol_before_dispatch() {
        let input =
            Cursor::new(br#"{"protocol_version":2,"user_id":"test-user","email":null}"#.to_vec());
        let dispatched = RefCell::new(false);

        let error = run_server(input, |_| async {
            *dispatched.borrow_mut() = true;
            Ok(())
        })
        .await
        .expect_err("wrong protocol should fail");

        assert!(error
            .to_string()
            .contains("unsupported reset-oidc protocol version 2"));
        assert!(!*dispatched.borrow());
    }

    #[tokio::test]
    async fn server_rejects_unknown_fields() {
        let input = Cursor::new(
            br#"{"protocol_version":1,"user_id":"test-user","email":null,"ttl":1}"#.to_vec(),
        );

        let error = run_server(input, |_| async { Ok(()) })
            .await
            .expect_err("unknown fields should fail");

        assert!(error.to_string().contains("failed to read reset request"));
    }
}
