use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::{bail, ensure, Context, Result};
use clap::Parser;
use nix::unistd::{Gid, Uid};
use serde::Serialize;

use crate::atomic::write_owned_atomic;

#[derive(Debug, Parser)]
#[command(version, about = "Render Kanidm person mail provisioning data")]
pub struct PersonMailArgs {
    #[arg(value_name = "OUTPUT")]
    pub output: PathBuf,

    #[arg(value_name = "PERSON_OR_MAIL_FILE", required = true)]
    pub person_mail: Vec<String>,
}

#[derive(Debug)]
struct MailSource {
    person: String,
    path: PathBuf,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PersonProvision {
    mail_addresses: Vec<String>,
}

#[derive(Serialize)]
struct ProvisionDocument {
    persons: BTreeMap<String, PersonProvision>,
}

fn sources_from(arguments: &PersonMailArgs) -> Result<Vec<MailSource>> {
    if !arguments.person_mail.len().is_multiple_of(2) {
        bail!("expected PERSON MAIL_FILE pairs");
    }
    Ok(arguments
        .person_mail
        .chunks_exact(2)
        .map(|pair| MailSource {
            person: pair[0].clone(),
            path: PathBuf::from(&pair[1]),
        })
        .collect())
}

fn read_mail_address(source: &MailSource) -> Result<String> {
    let metadata = source.path.metadata().with_context(|| {
        format!(
            "mail address file is empty or missing for {}: {}",
            source.person,
            source.path.display()
        )
    })?;
    ensure!(
        metadata.is_file() && metadata.len() != 0,
        "mail address file is empty or missing for {}: {}",
        source.person,
        source.path.display()
    );
    let contents = fs::read_to_string(&source.path).with_context(|| {
        format!(
            "failed to read mail address for {}: {}",
            source.person,
            source.path.display()
        )
    })?;
    let address = contents.trim_end_matches(['\r', '\n']);
    ensure!(
        !address.is_empty(),
        "empty mail address for {}: {}",
        source.person,
        source.path.display()
    );
    Ok(address.to_owned())
}

fn render(sources: &[MailSource]) -> Result<Vec<u8>> {
    let persons = sources
        .iter()
        .map(|source| {
            Ok((
                source.person.clone(),
                PersonProvision {
                    mail_addresses: vec![read_mail_address(source)?],
                },
            ))
        })
        .collect::<Result<BTreeMap<_, _>>>()?;
    let mut rendered = serde_json::to_vec(&ProvisionDocument { persons })?;
    rendered.push(b'\n');
    Ok(rendered)
}

fn write_document(output: &Path, rendered: &[u8]) -> Result<()> {
    let parent = output
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    ensure!(
        parent.is_dir(),
        "output directory does not exist: {}",
        parent.display()
    );
    write_owned_atomic(output, 0o600, Uid::current(), Gid::current(), |file| {
        file.write_all(rendered)
            .context("failed to write person mail provisioning data")
    })
}

pub fn run(arguments: PersonMailArgs) -> Result<()> {
    let sources = sources_from(&arguments)?;
    let rendered = render(&sources)?;
    write_document(&arguments.output, &rendered)
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::os::unix::fs::PermissionsExt;

    use tempfile::tempdir;

    use super::{run, PersonMailArgs};

    #[test]
    fn renders_addresses_atomically_with_private_permissions() {
        let directory = tempdir().unwrap();
        let first = directory.path().join("first-mail");
        let second = directory.path().join("second-mail");
        let output = directory.path().join("persons.json");
        fs::write(&first, "first@example.invalid\n").unwrap();
        fs::write(&second, "second+tag@example.invalid\r\n").unwrap();

        run(PersonMailArgs {
            output: output.clone(),
            person_mail: vec![
                "alpha".to_owned(),
                first.display().to_string(),
                "beta-user".to_owned(),
                second.display().to_string(),
            ],
        })
        .unwrap();

        let value: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(&output).unwrap()).unwrap();
        assert_eq!(
            value["persons"]["alpha"]["mailAddresses"][0],
            "first@example.invalid"
        );
        assert_eq!(
            value["persons"]["beta-user"]["mailAddresses"][0],
            "second+tag@example.invalid"
        );
        assert_eq!(
            fs::metadata(output).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }

    #[test]
    fn invalid_input_does_not_replace_existing_output() {
        let directory = tempdir().unwrap();
        let mail = directory.path().join("empty-mail");
        let output = directory.path().join("persons.json");
        fs::write(&mail, "").unwrap();
        fs::write(&output, "existing\n").unwrap();

        let error = run(PersonMailArgs {
            output: output.clone(),
            person_mail: vec!["alpha".to_owned(), mail.display().to_string()],
        })
        .unwrap_err();

        assert!(error.to_string().contains("empty or missing for alpha"));
        assert_eq!(fs::read_to_string(output).unwrap(), "existing\n");
    }

    #[test]
    fn rejects_incomplete_pairs() {
        let error = run(PersonMailArgs {
            output: PathBuf::from("persons.json"),
            person_mail: vec!["alpha".to_owned()],
        })
        .unwrap_err();
        assert!(error
            .to_string()
            .contains("expected PERSON MAIL_FILE pairs"));
    }

    use std::path::PathBuf;
}
