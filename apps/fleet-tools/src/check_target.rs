use std::env;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

use anyhow::{bail, Context, Result};

use crate::local_builders::{
    local_builders, read_builders, DEFAULT_NIX_CONF, DEFAULT_NIX_MACHINES,
};

const CHECK_NIX: &str = env!("CHECK_NIX");
const CHECK_NOM: &str = env!("CHECK_NOM");

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CheckTargetOptions {
    pub flake_attribute: String,
    pub label_plural: String,
    pub label_singular: String,
    pub remote: bool,
    pub what: Option<String>,
}

pub trait Backend {
    fn evaluate_names(&mut self, flake_attribute: &str, system: &str) -> Result<Vec<String>>;
    fn local_builders(&self) -> String;
    fn build(&mut self, attribute: &str, builders: Option<&str>) -> Result<i32>;
}

#[derive(Debug)]
pub struct SystemBackend {
    nix_conf: PathBuf,
    nix_machines: PathBuf,
}

impl SystemBackend {
    pub fn from_environment() -> Self {
        Self {
            nix_conf: env::var_os("NIX_CONF")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from(DEFAULT_NIX_CONF)),
            nix_machines: env::var_os("NIX_MACHINES")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from(DEFAULT_NIX_MACHINES)),
        }
    }
}

impl Backend for SystemBackend {
    fn evaluate_names(&mut self, flake_attribute: &str, system: &str) -> Result<Vec<String>> {
        let attribute = format!(".#{flake_attribute}.{system}");
        let output = Command::new(CHECK_NIX)
            .args([
                "eval",
                "--json",
                &attribute,
                "--apply",
                "builtins.attrNames",
            ])
            .stderr(Stdio::inherit())
            .output()
            .with_context(|| format!("failed to run nix eval for {attribute}"))?;
        if !output.status.success() {
            bail!("nix eval failed for {attribute}");
        }
        serde_json::from_slice(&output.stdout)
            .with_context(|| format!("nix eval returned invalid JSON for {attribute}"))
    }

    fn local_builders(&self) -> String {
        read_builders(&self.nix_conf, &self.nix_machines)
            .map(|builders| local_builders(&builders))
            .unwrap_or_default()
    }

    fn build(&mut self, attribute: &str, builders: Option<&str>) -> Result<i32> {
        let mut command = Command::new(CHECK_NOM);
        command.arg("build");
        if let Some(builders) = builders {
            command.args(["--option", "builders", builders]);
        }
        let status = command
            .args([attribute, "-L", "--show-trace"])
            .status()
            .with_context(|| format!("failed to run nom build for {attribute}"))?;
        Ok(status.code().unwrap_or(1))
    }
}

pub fn run(
    options: &CheckTargetOptions,
    current_system: &str,
    backend: &mut impl Backend,
    output: &mut impl Write,
) -> Result<i32> {
    let linux_system = current_system
        .strip_suffix("-darwin")
        .map(|architecture| format!("{architecture}-linux"))
        .unwrap_or_else(|| current_system.to_owned());
    let check_system = if options.flake_attribute == "nixosTests" {
        &linux_system
    } else {
        current_system
    };
    let checks = backend.evaluate_names(&options.flake_attribute, check_system)?;
    let local_builders = (!options.remote).then(|| backend.local_builders());

    let Some(what) = options.what.as_deref().filter(|value| !value.is_empty()) else {
        if checks.is_empty() {
            writeln!(output, "No {} for {check_system}.", options.label_plural)?;
            return Ok(0);
        }
        for check in checks {
            writeln!(output, "Running {check} on {check_system}...")?;
            let status = backend.build(
                &check_attribute(&options.flake_attribute, check_system, &check),
                local_builders.as_deref(),
            )?;
            if status != 0 {
                return Ok(status);
            }
        }
        return Ok(0);
    };

    if checks.iter().any(|check| check == what) {
        return backend.build(
            &check_attribute(&options.flake_attribute, check_system, what),
            local_builders.as_deref(),
        );
    }

    writeln!(output, "Unknown {}: {what}", options.label_singular)?;
    writeln!(output)?;
    writeln!(
        output,
        "Available {} for {check_system}:",
        options.label_plural
    )?;
    for check in &checks {
        writeln!(output, "{check}")?;
    }

    if options.flake_attribute == "checks" {
        let nixos_checks = backend.evaluate_names("nixosTests", &linux_system)?;
        if nixos_checks.iter().any(|check| check == what) {
            writeln!(output)?;
            writeln!(output, "Hint: use make check-nixos WHAT={what}")?;
        }
    }
    Ok(1)
}

fn check_attribute(flake_attribute: &str, system: &str, check: &str) -> String {
    format!(".#{flake_attribute}.{system}.{check}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    #[derive(Default)]
    struct RecordingBackend {
        names: BTreeMap<(String, String), Vec<String>>,
        builders: String,
        builds: Vec<(String, Option<String>)>,
        build_statuses: Vec<i32>,
        evaluations: Vec<(String, String)>,
    }

    impl Backend for RecordingBackend {
        fn evaluate_names(&mut self, flake_attribute: &str, system: &str) -> Result<Vec<String>> {
            self.evaluations
                .push((flake_attribute.to_owned(), system.to_owned()));
            Ok(self
                .names
                .get(&(flake_attribute.to_owned(), system.to_owned()))
                .cloned()
                .unwrap_or_default())
        }

        fn local_builders(&self) -> String {
            self.builders.clone()
        }

        fn build(&mut self, attribute: &str, builders: Option<&str>) -> Result<i32> {
            self.builds
                .push((attribute.to_owned(), builders.map(ToOwned::to_owned)));
            Ok(if self.build_statuses.is_empty() {
                0
            } else {
                self.build_statuses.remove(0)
            })
        }
    }

    fn options(flake_attribute: &str, what: Option<&str>) -> CheckTargetOptions {
        CheckTargetOptions {
            flake_attribute: flake_attribute.to_owned(),
            label_plural: "checks".to_owned(),
            label_singular: "check".to_owned(),
            remote: true,
            what: what.map(ToOwned::to_owned),
        }
    }

    fn add_names(backend: &mut RecordingBackend, attribute: &str, system: &str, names: &[&str]) {
        backend.names.insert(
            (attribute.to_owned(), system.to_owned()),
            names.iter().map(|name| (*name).to_owned()).collect(),
        );
    }

    #[test]
    fn runs_every_check_in_order_and_stops_on_failure() {
        let mut backend = RecordingBackend {
            builders: "localhost".to_owned(),
            build_statuses: vec![0, 7],
            ..RecordingBackend::default()
        };
        add_names(
            &mut backend,
            "checks",
            "aarch64-darwin",
            &["alpha", "beta", "gamma"],
        );
        let mut request = options("checks", None);
        request.remote = false;
        let mut output = Vec::new();

        assert_eq!(
            run(&request, "aarch64-darwin", &mut backend, &mut output).unwrap(),
            7
        );
        assert_eq!(
            backend.builds,
            [
                (
                    ".#checks.aarch64-darwin.alpha".to_owned(),
                    Some("localhost".to_owned())
                ),
                (
                    ".#checks.aarch64-darwin.beta".to_owned(),
                    Some("localhost".to_owned())
                ),
            ]
        );
        assert_eq!(
            String::from_utf8(output).unwrap(),
            "Running alpha on aarch64-darwin...\nRunning beta on aarch64-darwin...\n"
        );
    }

    #[test]
    fn runs_one_named_check_without_local_builder_override() {
        let mut backend = RecordingBackend::default();
        add_names(&mut backend, "checks", "x86_64-linux", &["alpha", "beta"]);
        let mut output = Vec::new();

        assert_eq!(
            run(
                &options("checks", Some("beta")),
                "x86_64-linux",
                &mut backend,
                &mut output,
            )
            .unwrap(),
            0
        );
        assert_eq!(
            backend.builds,
            [(".#checks.x86_64-linux.beta".to_owned(), None)]
        );
        assert!(output.is_empty());
    }

    #[test]
    fn runs_nixos_tests_for_matching_linux_architecture() {
        let mut backend = RecordingBackend::default();
        add_names(&mut backend, "nixosTests", "aarch64-linux", &["boot"]);

        assert_eq!(
            run(
                &options("nixosTests", Some("boot")),
                "aarch64-darwin",
                &mut backend,
                &mut Vec::new(),
            )
            .unwrap(),
            0
        );
        assert_eq!(
            backend.builds,
            [(".#nixosTests.aarch64-linux.boot".to_owned(), None)]
        );
    }

    #[test]
    fn reports_empty_sets_and_unknown_checks_with_nixos_hint() {
        let mut empty = RecordingBackend::default();
        let mut empty_output = Vec::new();
        assert_eq!(
            run(
                &options("checks", None),
                "x86_64-linux",
                &mut empty,
                &mut empty_output,
            )
            .unwrap(),
            0
        );
        assert_eq!(
            String::from_utf8(empty_output).unwrap(),
            "No checks for x86_64-linux.\n"
        );

        let mut unknown = RecordingBackend::default();
        add_names(&mut unknown, "checks", "aarch64-darwin", &["darwin-check"]);
        add_names(&mut unknown, "nixosTests", "aarch64-linux", &["boot"]);
        let mut output = Vec::new();
        assert_eq!(
            run(
                &options("checks", Some("boot")),
                "aarch64-darwin",
                &mut unknown,
                &mut output,
            )
            .unwrap(),
            1
        );
        assert_eq!(
            String::from_utf8(output).unwrap(),
            "Unknown check: boot\n\nAvailable checks for aarch64-darwin:\n\
             darwin-check\n\nHint: use make check-nixos WHAT=boot\n"
        );
    }
}
