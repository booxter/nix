use std::collections::BTreeSet;
use std::env;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Instant;

use anyhow::{bail, Context, Result};
use chrono::{DateTime, Local, Utc};
use clap::Parser;
use serde::{Deserialize, Serialize};

const NAME: &str = "fleet-cache-warmer";
const NIX: &str = env!("FLEET_CACHE_WARMER_NIX");
const ATTIC: &str = env!("FLEET_CACHE_WARMER_ATTIC");
const TARGETS_JSON: &str = env!("FLEET_CACHE_WARMER_TARGETS_JSON");
const MAX_SUBSTITUTION_JOBS: &str = "4";
const HTTP_CONNECTIONS: &str = "8";

#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct RunSummary {
    configured_targets: usize,
    output_paths: usize,
    fallback_failures: usize,
    attic_pushes: usize,
    operational_success: bool,
    partial: bool,
}

impl RunSummary {
    fn status(&self) -> &'static str {
        if !self.operational_success {
            "failed"
        } else if self.partial {
            "partial"
        } else {
            "success"
        }
    }
}

#[derive(Debug, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct PersistedState {
    schema_version: u8,
    last_success_timestamp_seconds: Option<i64>,
}

struct MetricsStore {
    state_path: PathBuf,
    metrics_path: PathBuf,
    state: PersistedState,
}

impl MetricsStore {
    fn from_environment() -> Result<Option<Self>> {
        let state_path = env::var_os("FLEET_CACHE_WARMER_STATE_FILE").map(PathBuf::from);
        let metrics_path = env::var_os("FLEET_CACHE_WARMER_METRICS_FILE").map(PathBuf::from);
        let (state_path, metrics_path) = match (state_path, metrics_path) {
            (Some(state_path), Some(metrics_path)) => (state_path, metrics_path),
            (None, None) => return Ok(None),
            _ => bail!("fleet cache-warmer state and metrics paths must be configured together"),
        };
        let state = match fs::read_to_string(&state_path) {
            Ok(contents) => serde_json::from_str(&contents)
                .with_context(|| format!("failed to parse {}", state_path.display()))?,
            Err(error) if error.kind() == io::ErrorKind::NotFound => PersistedState {
                schema_version: 1,
                ..PersistedState::default()
            },
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("failed to read {}", state_path.display()));
            }
        };
        if state.schema_version != 1 {
            bail!(
                "unsupported fleet cache-warmer state schema {}",
                state.schema_version
            );
        }
        Ok(Some(Self {
            state_path,
            metrics_path,
            state,
        }))
    }

    fn write_running(&self, started_at: DateTime<Utc>, configured_targets: usize) -> Result<()> {
        let summary = RunSummary {
            configured_targets,
            ..RunSummary::default()
        };
        self.write_metrics(started_at, 0.0, true, &summary)
    }

    fn write_completed(
        &mut self,
        started_at: DateTime<Utc>,
        duration_seconds: f64,
        summary: &RunSummary,
    ) -> Result<()> {
        if summary.operational_success {
            self.state.last_success_timestamp_seconds = Some(Utc::now().timestamp());
            let state = serde_json::to_string_pretty(&self.state)? + "\n";
            write_atomic(&self.state_path, &state)?;
        }
        self.write_metrics(started_at, duration_seconds, false, summary)
    }

    fn write_metrics(
        &self,
        started_at: DateTime<Utc>,
        duration_seconds: f64,
        running: bool,
        summary: &RunSummary,
    ) -> Result<()> {
        write_atomic(
            &self.metrics_path,
            &render_metrics(
                started_at,
                duration_seconds,
                running,
                summary,
                self.state.last_success_timestamp_seconds,
            ),
        )
    }
}

fn write_atomic(path: &Path, contents: &str) -> Result<()> {
    let parent = path
        .parent()
        .with_context(|| format!("{} has no parent directory", path.display()))?;
    fs::create_dir_all(parent).with_context(|| format!("failed to create {}", parent.display()))?;
    let file_name = path
        .file_name()
        .with_context(|| format!("{} has no file name", path.display()))?;
    let temporary = parent.join(format!(".{}.tmp", file_name.to_string_lossy()));
    let mut file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o644)
        .open(&temporary)
        .with_context(|| format!("failed to open {}", temporary.display()))?;
    file.write_all(contents.as_bytes())
        .with_context(|| format!("failed to write {}", temporary.display()))?;
    file.sync_all()
        .with_context(|| format!("failed to sync {}", temporary.display()))?;
    fs::rename(&temporary, path)
        .with_context(|| format!("failed to replace {}", path.display()))?;
    Ok(())
}

fn render_metrics(
    started_at: DateTime<Utc>,
    duration_seconds: f64,
    running: bool,
    summary: &RunSummary,
    last_success_timestamp_seconds: Option<i64>,
) -> String {
    let mut lines = vec![
        "# HELP host_observability_fleet_cache_warmer_running Whether a fleet warming run is in progress.",
        "# TYPE host_observability_fleet_cache_warmer_running gauge",
        "# HELP host_observability_fleet_cache_warmer_last_attempt_success Whether the last completed fleet warming run succeeded operationally.",
        "# TYPE host_observability_fleet_cache_warmer_last_attempt_success gauge",
        "# HELP host_observability_fleet_cache_warmer_last_attempt_status_info Exact outcome of the current or last fleet warming run.",
        "# TYPE host_observability_fleet_cache_warmer_last_attempt_status_info gauge",
        "# HELP host_observability_fleet_cache_warmer_last_attempt_timestamp_seconds Unix timestamp when the current or last fleet warming run started.",
        "# TYPE host_observability_fleet_cache_warmer_last_attempt_timestamp_seconds gauge",
        "# HELP host_observability_fleet_cache_warmer_last_attempt_duration_seconds Duration of the last completed fleet warming run.",
        "# TYPE host_observability_fleet_cache_warmer_last_attempt_duration_seconds gauge",
        "# HELP host_observability_fleet_cache_warmer_last_success_timestamp_seconds Unix timestamp of the last operationally successful fleet warming run.",
        "# TYPE host_observability_fleet_cache_warmer_last_success_timestamp_seconds gauge",
        "# HELP host_observability_fleet_cache_warmer_configured_targets Fleet outputs configured for warming.",
        "# TYPE host_observability_fleet_cache_warmer_configured_targets gauge",
        "# HELP host_observability_fleet_cache_warmer_output_paths Unique output paths produced by the last run.",
        "# TYPE host_observability_fleet_cache_warmer_output_paths gauge",
        "# HELP host_observability_fleet_cache_warmer_fallback_failures Targets that failed during per-target fallback builds.",
        "# TYPE host_observability_fleet_cache_warmer_fallback_failures gauge",
        "# HELP host_observability_fleet_cache_warmer_attic_pushes Successful cache pushes performed by the last run.",
        "# TYPE host_observability_fleet_cache_warmer_attic_pushes gauge",
    ]
    .into_iter()
    .map(str::to_owned)
    .collect::<Vec<_>>();
    let status = if running { "running" } else { summary.status() };
    lines.extend([
        format!(
            "host_observability_fleet_cache_warmer_running {}",
            usize::from(running)
        ),
        format!(
            "host_observability_fleet_cache_warmer_last_attempt_success {}",
            usize::from(!running && summary.operational_success)
        ),
        format!(
            "host_observability_fleet_cache_warmer_last_attempt_status_info{{status=\"{status}\"}} 1"
        ),
        format!(
            "host_observability_fleet_cache_warmer_last_attempt_timestamp_seconds {}",
            started_at.timestamp()
        ),
        format!(
            "host_observability_fleet_cache_warmer_last_attempt_duration_seconds {duration_seconds:.3}"
        ),
        format!(
            "host_observability_fleet_cache_warmer_configured_targets {}",
            summary.configured_targets
        ),
        format!(
            "host_observability_fleet_cache_warmer_output_paths {}",
            summary.output_paths
        ),
        format!(
            "host_observability_fleet_cache_warmer_fallback_failures {}",
            summary.fallback_failures
        ),
        format!(
            "host_observability_fleet_cache_warmer_attic_pushes {}",
            summary.attic_pushes
        ),
    ]);
    if let Some(timestamp) = last_success_timestamp_seconds {
        lines.push(format!(
            "host_observability_fleet_cache_warmer_last_success_timestamp_seconds {timestamp}"
        ));
    }
    lines.join("\n") + "\n"
}

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
    attic_caches: Vec<String>,
    backend: B,
}

impl<B: Backend> Warmer<B> {
    fn run(&mut self, log: &mut dyn Write) -> Result<RunSummary> {
        let mut summary = RunSummary {
            configured_targets: self.targets.len(),
            ..RunSummary::default()
        };
        log_line(
            log,
            format!("Building {} warm target(s)", self.targets.len()),
        )?;
        let batch = self.backend.build(&self.targets, true)?;
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

        let batch_successful = batch.successful;
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
            for target in &self.targets {
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
        summary.output_paths = outputs.len();
        summary.fallback_failures = fallback_failures;
        if outputs.is_empty() {
            log_line(log, format!("{}: no targets built successfully", self.name))?;
            return Ok(summary);
        }

        for cache in &self.attic_caches {
            log_line(
                log,
                format!(
                    "Pushing {} warmed output path(s) to Attic cache {cache}",
                    outputs.len()
                ),
            )?;
            self.backend.push(cache, &outputs)?;
            summary.attic_pushes += 1;
            log_line(
                log,
                format!(
                    "Pushed {} warmed output path(s) to Attic cache {cache}",
                    outputs.len()
                ),
            )?;
        }
        if self.attic_caches.is_empty() {
            log_line(
                log,
                format!(
                    "Built {} warmed output path(s); Attic push disabled",
                    outputs.len()
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
        summary.operational_success = true;
        summary.partial = !batch_successful || fallback_failures > 0;
        Ok(summary)
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
    let attic_caches = if push_to_attic() {
        serde_json::from_str(
            &env::var("FLEET_CACHE_WARMER_ATTIC_CACHES")
                .unwrap_or_else(|_| "[\"default\"]".to_owned()),
        )
        .context("invalid FLEET_CACHE_WARMER_ATTIC_CACHES JSON")?
    } else {
        Vec::new()
    };
    let started_at = Utc::now();
    let timer = Instant::now();
    let configured_targets = targets.len();
    let mut metrics = MetricsStore::from_environment()?;
    if let Some(store) = &metrics {
        store.write_running(started_at, configured_targets)?;
    }
    let result = Warmer {
        name: NAME.to_owned(),
        targets,
        attic_caches,
        backend: CommandBackend,
    }
    .run(&mut io::stderr());
    let duration_seconds = timer.elapsed().as_secs_f64();
    match result {
        Ok(summary) => {
            if let Some(store) = &mut metrics {
                store.write_completed(started_at, duration_seconds, &summary)?;
            }
            Ok(())
        }
        Err(error) => {
            if let Some(store) = &mut metrics {
                let summary = RunSummary {
                    configured_targets,
                    ..RunSummary::default()
                };
                store.write_completed(started_at, duration_seconds, &summary)?;
            }
            Err(error)
        }
    }
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;

    use super::*;

    #[derive(Default)]
    struct FakeBackend {
        builds: VecDeque<BuildResult>,
        build_calls: Vec<(Vec<String>, bool)>,
        pushes: Vec<(String, Vec<PathBuf>)>,
    }

    impl Backend for FakeBackend {
        fn build(&mut self, targets: &[String], keep_going: bool) -> Result<BuildResult> {
            self.build_calls.push((targets.to_vec(), keep_going));
            self.builds.pop_front().context("missing fake build result")
        }

        fn push(&mut self, cache: &str, outputs: &[PathBuf]) -> Result<()> {
            self.pushes.push((cache.to_owned(), outputs.to_vec()));
            Ok(())
        }
    }

    fn warmer(backend: FakeBackend, caches: &[&str]) -> Warmer<FakeBackend> {
        Warmer {
            name: "fleet-cache-warmer".to_owned(),
            targets: vec!["flake#one".to_owned(), "flake#two".to_owned()],
            attic_caches: caches.iter().map(|cache| (*cache).to_owned()).collect(),
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
    fn builds_targets_and_pushes_unique_outputs() {
        let backend = FakeBackend {
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
        let mut warmer = warmer(backend, &["cache-a:default", "cache-b:default"]);
        let mut log = Vec::new();
        let summary = warmer.run(&mut log).unwrap();
        assert_eq!(
            warmer.backend.build_calls,
            vec![(vec!["flake#one".to_owned(), "flake#two".to_owned()], true)]
        );
        assert_eq!(
            warmer.backend.pushes,
            vec![
                (
                    "cache-a:default".to_owned(),
                    vec!["/nix/store/a".into(), "/nix/store/b".into()]
                ),
                (
                    "cache-b:default".to_owned(),
                    vec!["/nix/store/a".into(), "/nix/store/b".into()]
                )
            ]
        );
        let log = String::from_utf8(log).unwrap();
        assert!(log.contains("batched build reported failures"));
        assert!(log.contains("Pushed 2 warmed output path(s)"));
        assert_eq!(
            summary,
            RunSummary {
                configured_targets: 2,
                output_paths: 2,
                attic_pushes: 2,
                operational_success: true,
                partial: true,
                ..RunSummary::default()
            }
        );
    }

    #[test]
    fn retries_empty_batch_individually_and_reports_failures() {
        let backend = FakeBackend {
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
        let mut warmer = warmer(backend, &[]);
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
            builds: VecDeque::from([
                BuildResult {
                    successful: false,
                    outputs: vec![],
                },
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
        let mut warmer = warmer(backend, &["default"]);
        let mut log = Vec::new();
        warmer.run(&mut log).unwrap();
        assert!(warmer.backend.pushes.is_empty());
        assert!(String::from_utf8(log)
            .unwrap()
            .contains("no targets built successfully"));
    }

    #[test]
    fn renders_persistent_fleet_metrics() {
        let started_at = DateTime::from_timestamp(1_700_000_000, 0).unwrap();
        let summary = RunSummary {
            configured_targets: 4,
            output_paths: 2,
            fallback_failures: 1,
            attic_pushes: 2,
            operational_success: true,
            partial: true,
        };

        let metrics = render_metrics(started_at, 12.5, false, &summary, Some(1_699_999_999));

        assert!(metrics.contains("last_attempt_status_info{status=\"partial\"} 1"));
        assert!(metrics.contains("last_attempt_duration_seconds 12.500"));
        assert!(metrics.contains("configured_targets 4"));
        assert!(metrics.contains("output_paths 2"));
        assert!(metrics.contains("last_success_timestamp_seconds 1699999999"));
    }
}
