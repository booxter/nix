{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.observability.backupMetrics;
  textfileDir = "/var/lib/prometheus-node-exporter-textfile";
  stateDir = "/var/lib/host-observability-backup-metrics";
  sanitizeName =
    name:
    lib.replaceStrings
      [
        "/"
        "."
        " "
      ]
      [
        "-"
        "-"
        "-"
      ]
      name;
  # Prometheus text-format label values must escape backslashes, line feeds,
  # and double quotes. This applies to every label value, including free-form
  # backup titles, rather than only to unusual job names.
  escapeLabel =
    value:
    lib.replaceStrings
      [
        "\\"
        "\n"
        "\""
      ]
      [
        "\\\\"
        "\\n"
        "\\\""
      ]
      value;
  configuredMetrics = pkgs.writeText "configured-backup-jobs.prom" (
    ''
      # HELP host_observability_backup_job_configured Whether a backup job is configured on this host.
      # TYPE host_observability_backup_job_configured gauge
    ''
    + lib.concatMapStringsSep "\n" (
      backupJob:
      let
        job = cfg.jobs.${backupJob};
        labels = {
          backup_job = backupJob;
          backup_title = job.title;
          phase = job.phase;
          unit = "${job.service}.service";
        };
        labelText = lib.concatStringsSep "," (
          lib.mapAttrsToList (name: value: ''${name}="${escapeLabel value}"'') labels
        );
      in
      "host_observability_backup_job_configured{${labelText}} 1"
    ) (builtins.attrNames cfg.jobs)
    + "\n"
  );
  recorder = pkgs.writeTextFile {
    name = "record-backup-metrics";
    executable = true;
    text = ''
      #!${pkgs.python3}/bin/python3
      import argparse
      import json
      import os
      import subprocess
      import tempfile
      import time
      from pathlib import Path


      def parse_args():
          parser = argparse.ArgumentParser(
              description="Persist backup service outcome metrics for node_exporter textfile collection."
          )
          parser.add_argument("--backup-job", required=True)
          parser.add_argument("--backup-title", required=True)
          parser.add_argument("--phase", required=True)
          parser.add_argument("--unit", required=True)
          parser.add_argument("--state-file", required=True)
          parser.add_argument("--metrics-file", required=True)
          return parser.parse_args()


      def escape_label(value: str) -> str:
          return value.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


      def write_atomic(path: Path, content: str) -> None:
          path.parent.mkdir(parents=True, exist_ok=True)
          with tempfile.NamedTemporaryFile(
              "w",
              encoding="utf-8",
              dir=path.parent,
              prefix=f".{path.name}.",
              delete=False,
          ) as handle:
              handle.write(content)
              tmp_name = handle.name
          os.chmod(tmp_name, 0o644)
          os.replace(tmp_name, path)


      def read_state(path: Path) -> dict:
          if not path.exists():
              return {}
          try:
              return json.loads(path.read_text(encoding="utf-8"))
          except (json.JSONDecodeError, OSError):
              return {}


      def read_systemd_props(unit: str) -> dict[str, str]:
          proc = subprocess.run(
              [
                  "${pkgs.systemd}/bin/systemctl",
                  "show",
                  unit,
                  "--property",
                  "ExecMainStartTimestampMonotonic",
                  "--property",
                  "ExecMainExitTimestampMonotonic",
              ],
              check=False,
              capture_output=True,
              text=True,
          )
          props: dict[str, str] = {}
          if proc.returncode != 0:
              return props
          for line in proc.stdout.splitlines():
              if "=" not in line:
                  continue
              key, value = line.split("=", 1)
              props[key] = value
          return props


      def parse_duration_seconds(unit: str) -> float:
          props = read_systemd_props(unit)
          start = int(props.get("ExecMainStartTimestampMonotonic") or "0")
          end = int(props.get("ExecMainExitTimestampMonotonic") or "0")
          if start <= 0 or end <= 0 or end < start:
              return 0.0
          return (end - start) / 1_000_000


      def metric_lines(labels: dict[str, str], state: dict[str, object]) -> str:
          label_text = ",".join(
              f'{name}="{escape_label(str(labels[name]))}"' for name in sorted(labels)
          )
          result_labels = labels | {
              "service_result": str(state["service_result"]),
              "exit_code": str(state["exit_code"]),
              "exit_status": str(state["exit_status"]),
          }
          result_label_text = ",".join(
              f'{name}="{escape_label(str(result_labels[name]))}"'
              for name in sorted(result_labels)
          )
          lines = [
              "# HELP host_observability_backup_last_run_timestamp_seconds Unix timestamp of the most recent backup job run.",
              "# TYPE host_observability_backup_last_run_timestamp_seconds gauge",
              f'host_observability_backup_last_run_timestamp_seconds{{{label_text}}} {state["last_run_timestamp_seconds"]}',
              "# HELP host_observability_backup_last_success_timestamp_seconds Unix timestamp of the most recent successful backup job run.",
              "# TYPE host_observability_backup_last_success_timestamp_seconds gauge",
              f'host_observability_backup_last_success_timestamp_seconds{{{label_text}}} {state["last_success_timestamp_seconds"]}',
              "# HELP host_observability_backup_last_duration_seconds Duration of the most recent backup job run in seconds.",
              "# TYPE host_observability_backup_last_duration_seconds gauge",
              f'host_observability_backup_last_duration_seconds{{{label_text}}} {state["last_duration_seconds"]}',
              "# HELP host_observability_backup_last_success Whether the most recent backup job run succeeded.",
              "# TYPE host_observability_backup_last_success gauge",
              f'host_observability_backup_last_success{{{label_text}}} {state["last_success"]}',
              "# HELP host_observability_backup_last_result_info Metadata about the most recent backup job result.",
              "# TYPE host_observability_backup_last_result_info gauge",
              f"host_observability_backup_last_result_info{{{result_label_text}}} 1",
          ]
          return "\n".join(lines) + "\n"


      def main() -> int:
          args = parse_args()
          state_path = Path(args.state_file)
          metrics_path = Path(args.metrics_file)
          previous = read_state(state_path)

          service_result = os.environ.get("SERVICE_RESULT", "unknown")
          exit_code = os.environ.get("EXIT_CODE", "unknown")
          exit_status = os.environ.get("EXIT_STATUS", "unknown")
          now = time.time()
          success = 1 if service_result == "success" else 0

          state = {
              "last_run_timestamp_seconds": now,
              "last_success_timestamp_seconds": (
                  now if success else float(previous.get("last_success_timestamp_seconds", 0))
              ),
              "last_duration_seconds": parse_duration_seconds(args.unit),
              "last_success": success,
              "service_result": service_result,
              "exit_code": exit_code,
              "exit_status": exit_status,
          }

          write_atomic(state_path, json.dumps(state, indent=2, sort_keys=True) + "\n")
          labels = {
              "backup_job": args.backup_job,
              "backup_title": args.backup_title,
              "phase": args.phase,
              "unit": args.unit,
          }
          write_atomic(metrics_path, metric_lines(labels, state))
          return 0


      if __name__ == "__main__":
          raise SystemExit(main())
    '';
  };
in
{
  options.host.observability.backupMetrics.jobs = lib.mkOption {
    type =
      with lib.types;
      attrsOf (submodule {
        options = {
          service = lib.mkOption {
            type = str;
            description = "Systemd service name, without the .service suffix.";
          };

          title = lib.mkOption {
            type = str;
            description = "Human-oriented backup job title.";
          };

          phase = lib.mkOption {
            type = str;
            description = "Backup phase label such as prep, local, or cloud.";
          };
        };
      });
    default = { };
    description = "Backup-related systemd services whose last-run outcome should be exported through node_exporter textfiles.";
  };

  config = lib.mkIf (cfg.jobs != { }) {
    systemd.tmpfiles.rules = [
      "d ${stateDir} 0755 root root - -"
      "C+ ${textfileDir}/backup-jobs-configured.prom 0644 root root - ${configuredMetrics}"
    ];

    systemd.services = lib.mapAttrs' (
      backupJob: job:
      let
        metricsBase = sanitizeName backupJob;
        unitName = "${job.service}.service";
        wrapper = pkgs.writeShellScript "record-${metricsBase}-backup-metrics" ''
          exec ${recorder} \
            --backup-job ${lib.escapeShellArg backupJob} \
            --backup-title ${lib.escapeShellArg job.title} \
            --phase ${lib.escapeShellArg job.phase} \
            --unit ${lib.escapeShellArg unitName} \
            --state-file ${lib.escapeShellArg "${stateDir}/${metricsBase}.json"} \
            --metrics-file ${lib.escapeShellArg "${textfileDir}/${metricsBase}.prom"}
        '';
      in
      lib.nameValuePair job.service {
        serviceConfig.ExecStopPost = lib.mkAfter [ "+${wrapper}" ];
      }
    ) cfg.jobs;
  };
}
