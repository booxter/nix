use std::collections::BTreeSet;
use std::env;
use std::io::{self, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};

use anyhow::{bail, Context, Result};
use chrono::Local;
use clap::Parser;

const NAME: &str = "fleet-cache-warmer";
const NIX: &str = env!("FLEET_CACHE_WARMER_NIX");
const ATTIC: &str = env!("FLEET_CACHE_WARMER_ATTIC");
const TARGETS_JSON: &str = env!("FLEET_CACHE_WARMER_TARGETS_JSON");
const MAX_SUBSTITUTION_JOBS: &str = "4";
const HTTP_CONNECTIONS: &str = "8";

fn push_to_attic() -> bool {
    env!("FLEET_CACHE_WARMER_PUSH_TO_ATTIC") == "true"
}

#[derive(Debug, Parser)]
#[command(name = NAME, about = "Build selected CI-validated fleet outputs")]
struct Arguments {
    #[arg(long, help = "Print the selected targets without building them")]
    print_targets: bool,

    #[arg(default_value = "run", value_parser = ["run"], hide = true)]
    command: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct BuildResult {
    successful: bool,
    outputs: Vec<PathBuf>,
}

trait Backend {
    fn resolves(&mut self, target: &str) -> Result<bool>;
    fn build(&mut self, targets: &[String], keep_going: bool) -> Result<BuildResult>;
    fn push(&mut self, cache: &str, outputs: &[PathBuf]) -> Result<()>;
}

struct CommandBackend;

fn nix_build_command(
    targets: &[String],
    keep_going: bool,
    limit_substitution_concurrency: bool,
) -> Command {
    let mut command = Command::new(NIX);
    command.args(["build", "-L"]);
    if keep_going {
        command.arg("--keep-going");
    }
    if limit_substitution_concurrency {
        command.args([
            "--option",
            "max-substitution-jobs",
            MAX_SUBSTITUTION_JOBS,
            "--option",
            "http-connections",
            HTTP_CONNECTIONS,
        ]);
    }
    command
        .args(["--no-link", "--print-out-paths"])
        .args(targets);
    command
}

impl Backend for CommandBackend {
    fn resolves(&mut self, target: &str) -> Result<bool> {
        let status = Command::new(NIX)
            .args(["eval", "--raw", &format!("{target}.outPath")])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .with_context(|| format!("failed to execute {NIX}"))?;
        Ok(status.success())
    }

    fn build(&mut self, targets: &[String], keep_going: bool) -> Result<BuildResult> {
        let output = nix_build_command(targets, keep_going, push_to_attic())
            .stderr(Stdio::inherit())
            .output()
            .with_context(|| format!("failed to execute {NIX}"))?;
        let stdout = String::from_utf8(output.stdout).context("nix emitted non-UTF-8 output")?;
        Ok(BuildResult {
            successful: output.status.success(),
            outputs: stdout
                .lines()
                .filter(|line| !line.trim().is_empty())
                .map(PathBuf::from)
                .collect(),
        })
    }

    fn push(&mut self, cache: &str, outputs: &[PathBuf]) -> Result<()> {
        if ATTIC.is_empty() {
            bail!("Attic push is enabled but no Attic executable was packaged");
        }
        let mut child = Command::new(ATTIC)
            .args(["push", "--ignore-upstream-cache-filter", "--stdin", cache])
            .stdin(Stdio::piped())
            .spawn()
            .with_context(|| format!("failed to execute {ATTIC}"))?;
        let mut stdin = child.stdin.take().context("failed to open Attic stdin")?;
        for output in outputs {
            writeln!(stdin, "{}", output.display())?;
        }
        drop(stdin);
        let status = child.wait().context("failed to wait for Attic")?;
        if !status.success() {
            bail!("Attic push failed with {status}");
        }
        Ok(())
    }
}

struct Warmer<B> {
    name: String,
    targets: Vec<String>,
    attic_cache: Option<String>,
    backend: B,
}

impl<B: Backend> Warmer<B> {
    fn run(&mut self, log: &mut dyn Write) -> Result<()> {
        log_line(
            log,
            format!("Resolving {} warm target(s)", self.targets.len()),
        )?;
        let mut buildable = Vec::new();
        let mut skipped_inventory = 0;
        for (index, target) in self.targets.iter().enumerate() {
            log_line(
                log,
                format!(
                    "Resolving target {}/{}: {target}",
                    index + 1,
                    self.targets.len()
                ),
            )?;
            if self.backend.resolves(target)? {
                buildable.push(target.clone());
                log_line(
                    log,
                    format!(
                        "Resolved target {}/{}: {target}",
                        index + 1,
                        self.targets.len()
                    ),
                )?;
            } else {
                skipped_inventory += 1;
                log_line(
                    log,
                    format!(
                        "{}: target is missing or does not evaluate, skipping: {target}",
                        self.name
                    ),
                )?;
            }
        }

        if buildable.is_empty() {
            log_line(
                log,
                format!("{}: no warm targets resolved successfully", self.name),
            )?;
            return Ok(());
        }

        log_line(
            log,
            format!("Building {} resolved warm target(s)", buildable.len()),
        )?;
        let batch = self.backend.build(&buildable, true)?;
        if batch.successful {
            log_line(log, "Batched build completed")?;
        } else {
            log_line(
                log,
                format!(
                    "{}: batched build reported failures; continuing with any successful outputs",
                    self.name
                ),
            )?;
        }

        let mut outputs = batch.outputs;
        let mut fallback_failures = 0;
        if outputs.is_empty() {
            log_line(
                log,
                format!(
                    "{}: batched build produced no successful outputs; retrying target-by-target",
                    self.name
                ),
            )?;
            for target in &buildable {
                log_line(log, format!("Warming {target}"))?;
                let result = self.backend.build(std::slice::from_ref(target), false)?;
                outputs.extend(result.outputs);
                if result.successful {
                    log_line(log, format!("Warmed {target}"))?;
                } else {
                    fallback_failures += 1;
                    log_line(
                        log,
                        format!("{}: target failed, skipping: {target}", self.name),
                    )?;
                }
            }
        }

        let outputs: Vec<PathBuf> = outputs
            .into_iter()
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect();
        if outputs.is_empty() {
            log_line(log, format!("{}: no targets built successfully", self.name))?;
            return Ok(());
        }

        if let Some(cache) = &self.attic_cache {
            log_line(
                log,
                format!(
                    "Pushing {} warmed output path(s) to Attic cache {cache}",
                    outputs.len()
                ),
            )?;
            self.backend.push(cache, &outputs)?;
            log_line(
                log,
                format!(
                    "Pushed {} warmed output path(s) to Attic cache {cache}",
                    outputs.len()
                ),
            )?;
        } else {
            log_line(
                log,
                format!(
                    "Built {} warmed output path(s); Attic push disabled",
                    outputs.len()
                ),
            )?;
        }

        if skipped_inventory > 0 {
            log_line(
                log,
                format!(
                    "{}: skipped {skipped_inventory} missing or unevaluable inventory target(s)",
                    self.name
                ),
            )?;
        }
        if fallback_failures > 0 {
            log_line(
                log,
                format!(
                    "{}: completed with {fallback_failures} skipped target failure(s) after batch fallback",
                    self.name
                ),
            )?;
        }
        Ok(())
    }
}

fn log_line(log: &mut dyn Write, message: impl AsRef<str>) -> Result<()> {
    writeln!(
        log,
        "[{}] {}",
        Local::now().format("%Y-%m-%dT%H:%M:%S%z"),
        message.as_ref()
    )?;
    Ok(())
}

fn targets(flake_ref: &str) -> Result<Vec<String>> {
    let suffixes: Vec<String> =
        serde_json::from_str(TARGETS_JSON).context("invalid embedded warm target JSON")?;
    Ok(suffixes
        .into_iter()
        .map(|suffix| format!("{flake_ref}#{suffix}"))
        .collect())
}

fn main() -> Result<()> {
    let arguments = Arguments::parse();
    let flake_ref =
        env::var("FLEET_CACHE_WARMER_FLAKE").unwrap_or_else(|_| "github:booxter/nix".to_owned());
    let targets = targets(&flake_ref)?;
    if arguments.print_targets {
        for target in targets {
            println!("{target}");
        }
        return Ok(());
    }
    let attic_cache = push_to_attic().then(|| {
        env::var("FLEET_CACHE_WARMER_ATTIC_CACHE").unwrap_or_else(|_| "default".to_owned())
    });
    Warmer {
        name: NAME.to_owned(),
        targets,
        attic_cache,
        backend: CommandBackend,
    }
    .run(&mut io::stderr())
}

#[cfg(test)]
mod tests {
    use std::collections::{HashMap, VecDeque};

    use super::*;

    #[derive(Default)]
    struct FakeBackend {
        resolutions: HashMap<String, bool>,
        builds: VecDeque<BuildResult>,
        build_calls: Vec<(Vec<String>, bool)>,
        pushes: Vec<(String, Vec<PathBuf>)>,
    }

    impl Backend for FakeBackend {
        fn resolves(&mut self, target: &str) -> Result<bool> {
            Ok(self.resolutions.get(target).copied().unwrap_or(false))
        }

        fn build(&mut self, targets: &[String], keep_going: bool) -> Result<BuildResult> {
            self.build_calls.push((targets.to_vec(), keep_going));
            self.builds.pop_front().context("missing fake build result")
        }

        fn push(&mut self, cache: &str, outputs: &[PathBuf]) -> Result<()> {
            self.pushes.push((cache.to_owned(), outputs.to_vec()));
            Ok(())
        }
    }

    fn warmer(backend: FakeBackend, cache: Option<&str>) -> Warmer<FakeBackend> {
        Warmer {
            name: "fleet-cache-warmer".to_owned(),
            targets: vec!["flake#one".to_owned(), "flake#two".to_owned()],
            attic_cache: cache.map(str::to_owned),
            backend,
        }
    }

    #[test]
    fn prints_embedded_targets_for_selected_flake() {
        let actual = targets("path:/repo").unwrap();
        let expected_suffixes: Vec<String> = serde_json::from_str(TARGETS_JSON).unwrap();
        assert_eq!(actual.len(), expected_suffixes.len());
        assert!(actual
            .iter()
            .zip(expected_suffixes)
            .all(|(target, suffix)| target == &format!("path:/repo#{suffix}")));
    }

    #[test]
    fn caps_substitution_concurrency_when_pushing_to_attic() {
        let command = nix_build_command(&["flake#one".to_owned()], true, true);
        let arguments: Vec<_> = command
            .get_args()
            .map(|argument| argument.to_string_lossy())
            .collect();
        assert_eq!(
            arguments,
            [
                "build",
                "-L",
                "--keep-going",
                "--option",
                "max-substitution-jobs",
                "4",
                "--option",
                "http-connections",
                "8",
                "--no-link",
                "--print-out-paths",
                "flake#one",
            ]
        );
    }

    #[test]
    fn leaves_substitution_concurrency_uncapped_without_attic() {
        let command = nix_build_command(&["flake#one".to_owned()], false, false);
        let arguments: Vec<_> = command
            .get_args()
            .map(|argument| argument.to_string_lossy())
            .collect();
        assert_eq!(
            arguments,
            ["build", "-L", "--no-link", "--print-out-paths", "flake#one",]
        );
    }

    #[test]
    fn builds_resolved_targets_and_pushes_unique_outputs() {
        let backend = FakeBackend {
            resolutions: HashMap::from([
                ("flake#one".to_owned(), true),
                ("flake#two".to_owned(), true),
            ]),
            builds: VecDeque::from([BuildResult {
                successful: false,
                outputs: vec![
                    "/nix/store/b".into(),
                    "/nix/store/a".into(),
                    "/nix/store/a".into(),
                ],
            }]),
            ..Default::default()
        };
        let mut warmer = warmer(backend, Some("default"));
        let mut log = Vec::new();
        warmer.run(&mut log).unwrap();
        assert_eq!(
            warmer.backend.build_calls,
            vec![(vec!["flake#one".to_owned(), "flake#two".to_owned()], true)]
        );
        assert_eq!(
            warmer.backend.pushes,
            vec![(
                "default".to_owned(),
                vec!["/nix/store/a".into(), "/nix/store/b".into()]
            )]
        );
        let log = String::from_utf8(log).unwrap();
        assert!(log.contains("batched build reported failures"));
        assert!(log.contains("Pushed 2 warmed output path(s)"));
    }

    #[test]
    fn skips_missing_targets_and_does_not_build_when_none_resolve() {
        let mut warmer = warmer(FakeBackend::default(), None);
        let mut log = Vec::new();
        warmer.run(&mut log).unwrap();
        assert!(warmer.backend.build_calls.is_empty());
        assert!(warmer.backend.pushes.is_empty());
        assert!(String::from_utf8(log)
            .unwrap()
            .contains("no warm targets resolved successfully"));
    }

    #[test]
    fn retries_empty_batch_individually_and_reports_failures() {
        let backend = FakeBackend {
            resolutions: HashMap::from([
                ("flake#one".to_owned(), true),
                ("flake#two".to_owned(), true),
            ]),
            builds: VecDeque::from([
                BuildResult {
                    successful: false,
                    outputs: vec![],
                },
                BuildResult {
                    successful: true,
                    outputs: vec!["/nix/store/one".into()],
                },
                BuildResult {
                    successful: false,
                    outputs: vec![],
                },
            ]),
            ..Default::default()
        };
        let mut warmer = warmer(backend, None);
        let mut log = Vec::new();
        warmer.run(&mut log).unwrap();
        assert_eq!(warmer.backend.build_calls.len(), 3);
        assert!(warmer.backend.build_calls[0].1);
        assert!(!warmer.backend.build_calls[1].1);
        assert!(warmer.backend.pushes.is_empty());
        let log = String::from_utf8(log).unwrap();
        assert!(log.contains("Attic push disabled"));
        assert!(log.contains("completed with 1 skipped target failure(s)"));
    }

    #[test]
    fn successful_empty_fallback_is_reported_without_push() {
        let backend = FakeBackend {
            resolutions: HashMap::from([
                ("flake#one".to_owned(), true),
                ("flake#two".to_owned(), false),
            ]),
            builds: VecDeque::from([
                BuildResult {
                    successful: false,
                    outputs: vec![],
                },
                BuildResult {
                    successful: false,
                    outputs: vec![],
                },
            ]),
            ..Default::default()
        };
        let mut warmer = warmer(backend, Some("default"));
        let mut log = Vec::new();
        warmer.run(&mut log).unwrap();
        assert!(warmer.backend.pushes.is_empty());
        assert!(String::from_utf8(log)
            .unwrap()
            .contains("no targets built successfully"));
    }
}
