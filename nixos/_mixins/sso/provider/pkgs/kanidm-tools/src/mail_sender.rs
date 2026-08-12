use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use anyhow::{ensure, Context, Result};
use async_trait::async_trait;
use clap::Parser;
use kanidm_client::KanidmClient;
use nix::unistd::{chown, Gid, Group, Uid, User};
use zeroize::Zeroizing;

use crate::atomic::write_owned_atomic;
use crate::client::{authenticated_at_address, client_error};
use crate::non_empty;

const ACCOUNT: &str = "mail-sender";
const DISPLAY_NAME: &str = "Kanidm Mail Sender";
const ENTRY_MANAGED_BY: &str = "idm_admins";
const MESSAGE_SENDER_GROUP: &str = "idm_message_senders";
const TOKEN_LABEL: &str = "mail sender token";

#[derive(Debug, Parser)]
#[command(
    version,
    about = "Bootstrap the Kanidm mail sender account and API token"
)]
pub struct MailSenderArgs {
    #[arg(long, value_name = "URL", value_parser = non_empty)]
    pub url: String,

    #[arg(long, value_name = "PATH")]
    pub idm_admin_password_file: PathBuf,

    #[arg(long, value_name = "PATH")]
    pub token_file: PathBuf,

    #[arg(long, value_name = "USER", value_parser = non_empty)]
    pub token_owner: String,

    #[arg(long, value_name = "GROUP", value_parser = non_empty)]
    pub token_group: String,
}

#[async_trait]
pub trait MailSenderDirectory {
    async fn service_account_exists(&self) -> Result<bool>;
    async fn create_service_account(&self) -> Result<()>;
    async fn group_members(&self) -> Result<Vec<String>>;
    async fn add_group_member(&self) -> Result<()>;
    async fn generate_api_token(&self) -> Result<String>;
}

#[async_trait]
impl MailSenderDirectory for KanidmClient {
    async fn service_account_exists(&self) -> Result<bool> {
        self.idm_service_account_get(ACCOUNT)
            .await
            .map(|entry| entry.is_some())
            .map_err(|error| client_error("failed to query mail sender service account", error))
    }

    async fn create_service_account(&self) -> Result<()> {
        self.idm_service_account_create(ACCOUNT, DISPLAY_NAME, ENTRY_MANAGED_BY)
            .await
            .map_err(|error| client_error("failed to create mail sender service account", error))
    }

    async fn group_members(&self) -> Result<Vec<String>> {
        self.idm_group_get_members(MESSAGE_SENDER_GROUP)
            .await
            .map(|members| members.unwrap_or_default())
            .map_err(|error| client_error("failed to query Kanidm message sender group", error))
    }

    async fn add_group_member(&self) -> Result<()> {
        self.idm_group_add_members(MESSAGE_SENDER_GROUP, &[ACCOUNT])
            .await
            .map_err(|error| client_error("failed to add mail sender to Kanidm group", error))
    }

    async fn generate_api_token(&self) -> Result<String> {
        self.idm_service_account_generate_api_token(ACCOUNT, TOKEN_LABEL, None, true, false)
            .await
            .map_err(|error| client_error("failed to generate mail sender API token", error))
    }
}

pub trait MailSenderTokenStore {
    fn path(&self) -> &Path;
    fn prepare(&self) -> Result<()>;
    fn has_token(&self) -> Result<bool>;
    fn store(&self, token: &str) -> Result<()>;
}

pub struct FileTokenStore {
    path: PathBuf,
    uid: Uid,
    gid: Gid,
}

impl FileTokenStore {
    pub fn from_names(path: PathBuf, owner: &str, group: &str) -> Result<Self> {
        let user = User::from_name(owner)
            .with_context(|| format!("failed to resolve token owner {owner}"))?
            .with_context(|| format!("token owner does not exist: {owner}"))?;
        let group = Group::from_name(group)
            .with_context(|| format!("failed to resolve token group {group}"))?
            .with_context(|| format!("token group does not exist: {group}"))?;
        Ok(Self {
            path,
            uid: user.uid,
            gid: group.gid,
        })
    }

    #[cfg(test)]
    fn with_ids(path: PathBuf, uid: Uid, gid: Gid) -> Self {
        Self { path, uid, gid }
    }

    fn directory(&self) -> &Path {
        self.path
            .parent()
            .filter(|path| !path.as_os_str().is_empty())
            .unwrap_or_else(|| Path::new("."))
    }
}

impl MailSenderTokenStore for FileTokenStore {
    fn path(&self) -> &Path {
        &self.path
    }

    fn prepare(&self) -> Result<()> {
        let directory = self.directory();
        fs::create_dir_all(directory)
            .with_context(|| format!("failed to create {}", directory.display()))?;
        fs::set_permissions(directory, fs::Permissions::from_mode(0o700))
            .with_context(|| format!("failed to set permissions on {}", directory.display()))?;
        chown(directory, Some(self.uid), Some(self.gid))
            .with_context(|| format!("failed to set ownership on {}", directory.display()))
    }

    fn has_token(&self) -> Result<bool> {
        match fs::metadata(&self.path) {
            Ok(metadata) => Ok(metadata.is_file() && metadata.len() > 0),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(error) => {
                Err(error).with_context(|| format!("failed to inspect {}", self.path.display()))
            }
        }
    }

    fn store(&self, token: &str) -> Result<()> {
        ensure!(!token.is_empty(), "Kanidm returned an empty API token");
        write_owned_atomic(&self.path, 0o400, self.uid, self.gid, |file| {
            writeln!(file, "{token}").context("failed to write API token")
        })
    }
}

pub async fn bootstrap_mail_sender(
    directory: &dyn MailSenderDirectory,
    token_store: &dyn MailSenderTokenStore,
    output: &mut dyn Write,
) -> Result<()> {
    if directory.service_account_exists().await? {
        writeln!(output, "service account already exists: {ACCOUNT}")?;
    } else {
        directory.create_service_account().await?;
        writeln!(output, "created service account: {ACCOUNT}")?;
    }

    let is_member = directory
        .group_members()
        .await?
        .iter()
        .any(|member| member.split('@').next() == Some(ACCOUNT));
    if is_member {
        writeln!(
            output,
            "service account already in group: {MESSAGE_SENDER_GROUP}"
        )?;
    } else {
        directory.add_group_member().await?;
        writeln!(output, "added {ACCOUNT} to {MESSAGE_SENDER_GROUP}")?;
    }

    token_store.prepare()?;
    if token_store.has_token()? {
        writeln!(
            output,
            "mail sender API token file already exists: {}",
            token_store.path().display()
        )?;
        return Ok(());
    }

    let token = Zeroizing::new(directory.generate_api_token().await?);
    ensure!(!token.is_empty(), "Kanidm returned an empty API token");
    token_store.store(&token)?;
    writeln!(
        output,
        "created mail sender API token file: {}",
        token_store.path().display()
    )?;
    Ok(())
}

pub async fn run(arguments: MailSenderArgs, output: &mut dyn Write) -> Result<()> {
    let token_store = FileTokenStore::from_names(
        arguments.token_file,
        &arguments.token_owner,
        &arguments.token_group,
    )?;
    let client =
        authenticated_at_address(&arguments.url, &arguments.idm_admin_password_file).await?;
    bootstrap_mail_sender(&client, &token_store, output).await
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};
    use std::sync::Mutex;

    use anyhow::Result;
    use async_trait::async_trait;
    use clap::Parser;
    use nix::unistd::{Gid, Uid};

    use super::{
        bootstrap_mail_sender, FileTokenStore, MailSenderArgs, MailSenderDirectory,
        MailSenderTokenStore,
    };

    struct FakeDirectory {
        account_exists: bool,
        members: Vec<String>,
        token: String,
        calls: Mutex<Vec<&'static str>>,
    }

    #[async_trait]
    impl MailSenderDirectory for FakeDirectory {
        async fn service_account_exists(&self) -> Result<bool> {
            self.calls.lock().expect("calls lock").push("get-account");
            Ok(self.account_exists)
        }

        async fn create_service_account(&self) -> Result<()> {
            self.calls
                .lock()
                .expect("calls lock")
                .push("create-account");
            Ok(())
        }

        async fn group_members(&self) -> Result<Vec<String>> {
            self.calls.lock().expect("calls lock").push("get-members");
            Ok(self.members.clone())
        }

        async fn add_group_member(&self) -> Result<()> {
            self.calls.lock().expect("calls lock").push("add-member");
            Ok(())
        }

        async fn generate_api_token(&self) -> Result<String> {
            self.calls
                .lock()
                .expect("calls lock")
                .push("generate-token");
            Ok(self.token.clone())
        }
    }

    struct FakeTokenStore {
        path: PathBuf,
        exists: bool,
        stored: Mutex<Vec<String>>,
        calls: Mutex<Vec<&'static str>>,
    }

    impl MailSenderTokenStore for FakeTokenStore {
        fn path(&self) -> &Path {
            &self.path
        }

        fn prepare(&self) -> Result<()> {
            self.calls.lock().expect("calls lock").push("prepare");
            Ok(())
        }

        fn has_token(&self) -> Result<bool> {
            self.calls.lock().expect("calls lock").push("has-token");
            Ok(self.exists)
        }

        fn store(&self, token: &str) -> Result<()> {
            self.calls.lock().expect("calls lock").push("store");
            self.stored
                .lock()
                .expect("stored lock")
                .push(token.to_owned());
            Ok(())
        }
    }

    fn fake_store(exists: bool) -> FakeTokenStore {
        FakeTokenStore {
            path: PathBuf::from("/token"),
            exists,
            stored: Mutex::new(Vec::new()),
            calls: Mutex::new(Vec::new()),
        }
    }

    #[test]
    fn parses_required_command_line_options() {
        let arguments = MailSenderArgs::try_parse_from([
            "kanidm-mail-sender-bootstrap",
            "--url",
            "https://id.example.test",
            "--idm-admin-password-file",
            "/run/secrets/password",
            "--token-file",
            "/var/lib/mail-sender/token",
            "--token-owner",
            "mailer",
            "--token-group",
            "mailer",
        ])
        .expect("arguments should parse");

        assert_eq!(arguments.url, "https://id.example.test");
        assert_eq!(
            arguments.idm_admin_password_file,
            PathBuf::from("/run/secrets/password")
        );
        assert_eq!(
            arguments.token_file,
            PathBuf::from("/var/lib/mail-sender/token")
        );
        assert_eq!(arguments.token_owner, "mailer");
        assert_eq!(arguments.token_group, "mailer");
    }

    #[tokio::test]
    async fn creates_missing_account_membership_and_token() {
        let directory = FakeDirectory {
            account_exists: false,
            members: Vec::new(),
            token: "secret-token".to_owned(),
            calls: Mutex::new(Vec::new()),
        };
        let store = fake_store(false);
        let mut output = Vec::new();

        bootstrap_mail_sender(&directory, &store, &mut output)
            .await
            .expect("bootstrap should succeed");

        assert_eq!(
            *directory.calls.lock().expect("calls lock"),
            [
                "get-account",
                "create-account",
                "get-members",
                "add-member",
                "generate-token",
            ]
        );
        assert_eq!(
            *store.calls.lock().expect("calls lock"),
            ["prepare", "has-token", "store"]
        );
        assert_eq!(*store.stored.lock().expect("stored lock"), ["secret-token"]);
        assert_eq!(
            String::from_utf8(output).expect("output should be UTF-8"),
            "created service account: mail-sender\n\
             added mail-sender to idm_message_senders\n\
             created mail sender API token file: /token\n"
        );
    }

    #[tokio::test]
    async fn preserves_existing_account_membership_and_token() {
        let directory = FakeDirectory {
            account_exists: true,
            members: vec!["mail-sender@example.test".to_owned()],
            token: "unused".to_owned(),
            calls: Mutex::new(Vec::new()),
        };
        let store = fake_store(true);
        let mut output = Vec::new();

        bootstrap_mail_sender(&directory, &store, &mut output)
            .await
            .expect("bootstrap should succeed");

        assert_eq!(
            *directory.calls.lock().expect("calls lock"),
            ["get-account", "get-members"]
        );
        assert_eq!(
            *store.calls.lock().expect("calls lock"),
            ["prepare", "has-token"]
        );
        assert!(store.stored.lock().expect("stored lock").is_empty());
        assert_eq!(
            String::from_utf8(output).expect("output should be UTF-8"),
            "service account already exists: mail-sender\n\
             service account already in group: idm_message_senders\n\
             mail sender API token file already exists: /token\n"
        );
    }

    #[tokio::test]
    async fn rejects_empty_generated_token() {
        let directory = FakeDirectory {
            account_exists: true,
            members: vec!["mail-sender".to_owned()],
            token: String::new(),
            calls: Mutex::new(Vec::new()),
        };
        let store = fake_store(false);
        let mut output = Vec::new();

        let error = bootstrap_mail_sender(&directory, &store, &mut output)
            .await
            .expect_err("empty token should fail");

        assert!(error.to_string().contains("empty API token"));
        assert_eq!(
            *store.calls.lock().expect("calls lock"),
            ["prepare", "has-token"]
        );
        assert!(store.stored.lock().expect("stored lock").is_empty());
    }

    #[test]
    fn file_store_writes_private_token_atomically() {
        let temporary = tempfile::tempdir().expect("temporary directory should be created");
        let directory = temporary.path().join("state");
        let path = directory.join("token");
        let store = FileTokenStore::with_ids(path.clone(), Uid::current(), Gid::current());

        store.prepare().expect("token directory should be prepared");
        assert!(!store.has_token().expect("token state should be readable"));
        store.store("secret-token").expect("token should be stored");

        assert!(store.has_token().expect("token state should be readable"));
        assert_eq!(
            fs::read_to_string(&path).expect("token should be readable"),
            "secret-token\n"
        );
        assert_eq!(
            fs::metadata(&directory)
                .expect("directory metadata")
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        assert_eq!(
            fs::metadata(&path)
                .expect("token metadata")
                .permissions()
                .mode()
                & 0o777,
            0o400
        );
    }
}
