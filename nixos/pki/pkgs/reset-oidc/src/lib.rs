use std::fs;
use std::future::Future;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use anyhow::{anyhow, bail, ensure, Context, Result};
use clap::Parser;
use kanidm_client::KanidmClientBuilder;
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

const PROTOCOL_VERSION: u8 = 1;
const TTL_SECONDS: u64 = 86_400;
const ADMIN_ID: &str = "idm_admin";
const REMOTE_PROGRAM: &str = "/run/current-system/sw/bin/reset-oidc-server";
const SSH_PROGRAM: &str = match option_env!("RESET_OIDC_SSH") {
    Some(path) => path,
    None => "ssh",
};

#[derive(Debug, Parser)]
#[command(
    version,
    about = "Send a Kanidm OIDC credential reset email through pki",
    after_help = "Examples:\n  reset-oidc ihar\n  reset-oidc kasia"
)]
pub struct ClientArgs {
    /// Kanidm person account ID.
    #[arg(value_name = "USER_ID", value_parser = non_empty)]
    pub user_id: String,

    /// Send the reset to this registered alternate email address.
    #[arg(value_name = "EMAIL")]
    pub email: Option<String>,

    /// OpenSSH destination of the Kanidm host.
    #[arg(
        long,
        env = "RESET_OIDC_SSH_TARGET",
        default_value = "pki",
        hide_env_values = true,
        value_parser = ssh_target
    )]
    pub target: String,
}

fn non_empty(value: &str) -> Result<String, String> {
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
    transport: &impl ResetTransport,
    output: &mut impl Write,
) -> Result<()> {
    let request = ResetRequest::new(arguments.user_id, arguments.email);
    transport.send(&arguments.target, &request)?;

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

    let mut password = Zeroizing::new(
        fs::read_to_string(password_path)
            .with_context(|| format!("failed to read {}", password_path.display()))?,
    );
    while matches!(password.as_bytes().last(), Some(b'\n' | b'\r')) {
        password.pop();
    }
    ensure!(!password.is_empty(), "Kanidm admin password is empty");

    let client = KanidmClientBuilder::new()
        .read_options_from_optional_config(config_path)
        .map_err(|error| anyhow!("failed to read Kanidm client configuration: {error:?}"))?
        .build()
        .map_err(|error| anyhow!("failed to build Kanidm client: {error:?}"))?;
    client
        .auth_simple_password(ADMIN_ID, &password)
        .await
        .map_err(|error| anyhow!("Kanidm authentication failed: {error:?}"))?;
    client
        .idm_person_account_credential_update_send_intent(
            &request.user_id,
            Some(TTL_SECONDS),
            request.email,
        )
        .await
        .map_err(|error| anyhow!("Kanidm rejected the credential reset request: {error:?}"))
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::io::Cursor;

    use anyhow::{bail, Result};
    use clap::{error::ErrorKind, Parser};

    use super::{run_client, run_server, ClientArgs, ResetRequest, ResetTransport};

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
        let arguments = ClientArgs::try_parse_from(["reset-oidc", "ihar", "i@example.com"])
            .expect("arguments should parse");

        assert_eq!(arguments.user_id, "ihar");
        assert_eq!(arguments.email.as_deref(), Some("i@example.com"));
        assert_eq!(arguments.target, "pki");
    }

    #[test]
    fn rejects_empty_user_and_option_shaped_target() {
        let empty =
            ClientArgs::try_parse_from(["reset-oidc", ""]).expect_err("empty user should fail");
        assert_eq!(empty.kind(), ErrorKind::ValueValidation);

        let target = ClientArgs::try_parse_from(["reset-oidc", "--target=-V", "ihar"])
            .expect_err("option-shaped target should fail");
        assert_eq!(target.kind(), ErrorKind::ValueValidation);
    }

    #[test]
    fn client_sends_request_and_reports_selected_email() {
        let transport = FakeTransport::default();
        let arguments = ClientArgs {
            user_id: "ihar".to_owned(),
            email: Some("i@example.com".to_owned()),
            target: "pki.example".to_owned(),
        };
        let mut output = Vec::new();

        run_client(arguments, &transport, &mut output).expect("client should succeed");

        let sent = transport.sent.borrow();
        assert_eq!(sent.len(), 1);
        assert_eq!(sent[0].0, "pki.example");
        assert_eq!(sent[0].1.user_id, "ihar");
        assert_eq!(sent[0].1.email.as_deref(), Some("i@example.com"));
        assert_eq!(
            String::from_utf8(output).expect("output should be UTF-8"),
            "Requested OIDC credential reset email for ihar at i@example.com.\n"
        );
    }

    #[test]
    fn client_does_not_report_success_after_transport_failure() {
        let transport = FakeTransport {
            fail: true,
            ..FakeTransport::default()
        };
        let arguments = ClientArgs {
            user_id: "ihar".to_owned(),
            email: None,
            target: "pki".to_owned(),
        };
        let mut output = Vec::new();

        let error = run_client(arguments, &transport, &mut output)
            .expect_err("transport failure should propagate");

        assert!(error.to_string().contains("transport failed"));
        assert!(output.is_empty());
    }

    #[tokio::test]
    async fn server_decodes_and_dispatches_request() {
        let input =
            Cursor::new(br#"{"protocol_version":1,"user_id":"kasia","email":null}"#.to_vec());

        run_server(input, |request| async move {
            assert_eq!(request.user_id, "kasia");
            assert_eq!(request.email, None);
            Ok(())
        })
        .await
        .expect("server should dispatch request");
    }

    #[tokio::test]
    async fn server_rejects_wrong_protocol_before_dispatch() {
        let input =
            Cursor::new(br#"{"protocol_version":2,"user_id":"ihar","email":null}"#.to_vec());
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
            br#"{"protocol_version":1,"user_id":"ihar","email":null,"ttl":1}"#.to_vec(),
        );

        let error = run_server(input, |_| async { Ok(()) })
            .await
            .expect_err("unknown fields should fail");

        assert!(error.to_string().contains("failed to read reset request"));
    }
}
