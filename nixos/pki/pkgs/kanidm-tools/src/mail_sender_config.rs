use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::{ensure, Context, Result};
use clap::Parser;
use nix::unistd::{Gid, Group, Uid};
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

use crate::atomic::write_owned_atomic;
use crate::non_empty;

#[derive(Debug, Parser)]
#[command(version, about = "Render the Kanidm mail sender configuration")]
pub struct ConfigWriterArgs {
    #[arg(long, value_name = "PATH")]
    pub template: PathBuf,

    #[arg(long, value_name = "PATH")]
    pub token_file: PathBuf,

    #[arg(long, value_name = "PATH")]
    pub password_file: PathBuf,

    #[arg(long, value_name = "PATH")]
    pub output: PathBuf,

    #[arg(long, value_name = "GROUP", value_parser = non_empty)]
    pub output_group: String,
}

#[derive(Debug, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct MailSenderTemplate {
    schedule: String,
    instance_display_name: String,
    instance_url: String,
    mail_from_address: String,
    mail_reply_to_address: String,
    mail_relay: String,
    mail_username: String,
    mail_connect_timeout_seconds: u64,
}

#[derive(Serialize)]
struct MailSenderConfig<'a> {
    token: &'a str,
    schedule: &'a str,
    instance_display_name: &'a str,
    instance_url: &'a str,
    mail_from_address: &'a str,
    mail_reply_to_address: &'a str,
    mail_relay: &'a str,
    mail_username: &'a str,
    mail_password: &'a str,
    mail_connect_timeout_seconds: u64,
}

fn read_secret(path: &Path) -> Result<Zeroizing<String>> {
    let contents = fs::read_to_string(path)
        .with_context(|| format!("failed to read secret {}", path.display()))?;
    let contents = contents.strip_suffix('\n').unwrap_or(&contents).to_owned();
    ensure!(!contents.is_empty(), "secret is empty: {}", path.display());
    Ok(Zeroizing::new(contents))
}

fn load_template(path: &Path) -> Result<MailSenderTemplate> {
    let contents = fs::read_to_string(path)
        .with_context(|| format!("failed to read template {}", path.display()))?;
    serde_json::from_str(&contents)
        .with_context(|| format!("failed to parse template {}", path.display()))
}

fn render(template: &MailSenderTemplate, token: &str, password: &str) -> Result<Zeroizing<String>> {
    let config = MailSenderConfig {
        token,
        schedule: &template.schedule,
        instance_display_name: &template.instance_display_name,
        instance_url: &template.instance_url,
        mail_from_address: &template.mail_from_address,
        mail_reply_to_address: &template.mail_reply_to_address,
        mail_relay: &template.mail_relay,
        mail_username: &template.mail_username,
        mail_password: password,
        mail_connect_timeout_seconds: template.mail_connect_timeout_seconds,
    };
    toml::to_string(&config)
        .map(Zeroizing::new)
        .context("failed to serialize mail sender configuration")
}

fn write_config(
    template: &MailSenderTemplate,
    token: &str,
    password: &str,
    output: &Path,
    uid: Uid,
    gid: Gid,
) -> Result<()> {
    let rendered = render(template, token, password)?;
    write_owned_atomic(output, 0o440, uid, gid, |file| {
        file.write_all(rendered.as_bytes())
            .context("failed to write mail sender configuration")
    })
}

pub fn run(arguments: ConfigWriterArgs) -> Result<()> {
    let group = Group::from_name(&arguments.output_group)
        .with_context(|| format!("failed to resolve output group {}", arguments.output_group))?
        .with_context(|| format!("output group does not exist: {}", arguments.output_group))?;
    let template = load_template(&arguments.template)?;
    let token = read_secret(&arguments.token_file)?;
    let password = read_secret(&arguments.password_file)?;
    write_config(
        &template,
        &token,
        &password,
        &arguments.output,
        Uid::from_raw(0),
        group.gid,
    )
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::os::unix::fs::{MetadataExt, PermissionsExt};

    use nix::unistd::{Gid, Uid};
    use tempfile::tempdir;

    use super::{read_secret, render, write_config, MailSenderTemplate};

    fn template() -> MailSenderTemplate {
        MailSenderTemplate {
            schedule: "*/30 * * * * * *".to_owned(),
            instance_display_name: "SSO".to_owned(),
            instance_url: "https://id.example.test".to_owned(),
            mail_from_address: "sender@example.test".to_owned(),
            mail_reply_to_address: "reply@example.test".to_owned(),
            mail_relay: "smtp.example.test".to_owned(),
            mail_username: "sender@example.test".to_owned(),
            mail_connect_timeout_seconds: 15,
        }
    }

    #[test]
    fn toml_serializer_escapes_secret_values() {
        let rendered = render(&template(), "token\"value", "line1\nline2").unwrap();
        let parsed: toml::Value = toml::from_str(&rendered).unwrap();

        assert_eq!(parsed["token"].as_str(), Some("token\"value"));
        assert_eq!(parsed["mail_password"].as_str(), Some("line1\nline2"));
        assert_eq!(
            parsed["instance_url"].as_str(),
            Some("https://id.example.test")
        );
        assert_eq!(
            parsed["mail_connect_timeout_seconds"].as_integer(),
            Some(15)
        );
    }

    #[test]
    fn writes_owned_config_atomically_with_expected_mode() {
        let directory = tempdir().unwrap();
        let output = directory.path().join("mail-sender.toml");
        let gid = Gid::current();

        write_config(
            &template(),
            "token",
            "password",
            &output,
            Uid::current(),
            gid,
        )
        .unwrap();

        let metadata = fs::metadata(&output).unwrap();
        assert_eq!(metadata.permissions().mode() & 0o777, 0o440);
        assert_eq!(metadata.gid(), gid.as_raw());
        let parsed: toml::Value = toml::from_str(&fs::read_to_string(output).unwrap()).unwrap();
        assert_eq!(parsed["token"].as_str(), Some("token"));
        assert_eq!(parsed["mail_password"].as_str(), Some("password"));
    }

    #[test]
    fn secret_reader_removes_one_terminal_newline_and_rejects_empty_input() {
        let directory = tempdir().unwrap();
        let secret = directory.path().join("secret");
        fs::write(&secret, "value\n\n").unwrap();
        assert_eq!(&*read_secret(&secret).unwrap(), "value\n");

        fs::write(&secret, "").unwrap();
        assert!(read_secret(&secret).is_err());
    }
}
