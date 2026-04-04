{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.observability.thermal;
  textfileDir = "/var/lib/prometheus-node-exporter-textfile";
  stateDir = "/var/lib/observability-thermal";
  ismcBin = lib.getExe cfg.package;
  exportMetrics = pkgs.writeShellApplication {
    name = "observability-thermal-export";
    runtimeInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.gnused
      pkgs.gawk
      pkgs.jq
      cfg.package
    ];
    text = ''
      set -euo pipefail

      mkdir -p "${textfileDir}" "${stateDir}"

      tmp_metrics="$(mktemp ${textfileDir}/thermal.prom.XXXXXX)"
      tmp_pmset="$(mktemp ${stateDir}/pmset.txt.XXXXXX)"
      tmp_powermetrics="$(mktemp ${stateDir}/powermetrics.txt.XXXXXX)"
      tmp_ismc="$(mktemp ${stateDir}/ismc-temp.json.XXXXXX)"
      trap 'rm -f "$tmp_metrics" "$tmp_pmset" "$tmp_powermetrics" "$tmp_ismc"' EXIT

      thermal_warning_level=0
      performance_warning_level=0
      cpu_power_status=0
      powermetrics_collect_success=0
      ismc_collect_success=0
      sample_timestamp="$(date +%s)"

      parse_pmset_level() {
        local key="$1"
        local fallback="$2"
        local level

        level="$(awk -v key="$key" '
          BEGIN { IGNORECASE = 1 }
          index($0, key) {
            if (match($0, /[0-9]+/)) {
              print substr($0, RSTART, RLENGTH)
              exit
            }
          }
        ' "$tmp_pmset")"

        if [[ -n "$level" ]]; then
          printf '%s\n' "$level"
        else
          printf '%s\n' "$fallback"
        fi
      }

      /usr/bin/pmset -g therm >"$tmp_pmset" 2>/dev/null || true
      thermal_warning_level="$(parse_pmset_level 'thermal warning level' 0)"
      performance_warning_level="$(parse_pmset_level 'performance warning level' 0)"
      cpu_power_status="$(parse_pmset_level 'cpu power status' 0)"

      if "${ismcBin}" temp -o json >"$tmp_ismc" 2>&1; then
        ismc_collect_success=1
      fi

      if /usr/bin/powermetrics -n 1 -i 500 --samplers cpu_power,thermal >"$tmp_powermetrics" 2>&1; then
        powermetrics_collect_success=1
      fi

      cp "$tmp_pmset" "${stateDir}/latest-pmset-therm.txt"
      cp "$tmp_powermetrics" "${stateDir}/latest-powermetrics.txt"
      cp "$tmp_ismc" "${stateDir}/latest-ismc-temp.json"

      {
        printf '%s\n' '# HELP host_observability_darwin_thermal_warning_level Darwin thermal warning level from pmset -g therm.'
        printf '%s\n' '# TYPE host_observability_darwin_thermal_warning_level gauge'
        printf 'host_observability_darwin_thermal_warning_level %s\n' "$thermal_warning_level"

        printf '%s\n' '# HELP host_observability_darwin_performance_warning_level Darwin performance warning level from pmset -g therm.'
        printf '%s\n' '# TYPE host_observability_darwin_performance_warning_level gauge'
        printf 'host_observability_darwin_performance_warning_level %s\n' "$performance_warning_level"

        printf '%s\n' '# HELP host_observability_darwin_cpu_power_status Darwin CPU power status from pmset -g therm.'
        printf '%s\n' '# TYPE host_observability_darwin_cpu_power_status gauge'
        printf 'host_observability_darwin_cpu_power_status %s\n' "$cpu_power_status"

        printf '%s\n' '# HELP host_observability_darwin_powermetrics_collect_success Whether the last root powermetrics collection succeeded.'
        printf '%s\n' '# TYPE host_observability_darwin_powermetrics_collect_success gauge'
        printf 'host_observability_darwin_powermetrics_collect_success %s\n' "$powermetrics_collect_success"

        printf '%s\n' '# HELP host_observability_darwin_ismc_collect_success Whether the last iSMC temperature collection succeeded.'
        printf '%s\n' '# TYPE host_observability_darwin_ismc_collect_success gauge'
        printf 'host_observability_darwin_ismc_collect_success %s\n' "$ismc_collect_success"

        printf '%s\n' '# HELP host_observability_darwin_powermetrics_sample_timestamp_seconds Unix timestamp of the latest Darwin thermal sample.'
        printf '%s\n' '# TYPE host_observability_darwin_powermetrics_sample_timestamp_seconds gauge'
        printf 'host_observability_darwin_powermetrics_sample_timestamp_seconds %s\n' "$sample_timestamp"

        printf '%s\n' '# HELP host_observability_darwin_temperature_celsius Darwin temperature sensor reading collected via iSMC.'
        printf '%s\n' '# TYPE host_observability_darwin_temperature_celsius gauge'
        printf '%s\n' '# HELP host_observability_darwin_temperature_group_max_celsius Maximum Darwin temperature by derived sensor group.'
        printf '%s\n' '# TYPE host_observability_darwin_temperature_group_max_celsius gauge'
        printf '%s\n' '# HELP host_observability_darwin_temperature_max_celsius Maximum Darwin temperature across all iSMC sensors.'
        printf '%s\n' '# TYPE host_observability_darwin_temperature_max_celsius gauge'

        awk '
          function watts_from(value, unit) {
            if (unit == "mW") {
              return value / 1000
            }
            return value
          }
          match($0, /^(CPU|GPU|ANE) Power: ([0-9.]+) (mW|W)$/, m) {
            domain = tolower(m[1])
            printf "host_observability_darwin_power_watts{domain=\"%s\"} %.6f\n", domain, watts_from(m[2] + 0, m[3])
          }
        ' "$tmp_powermetrics"

        if [[ "$ismc_collect_success" == "1" ]]; then
          jq -r '
            to_entries[]
            | select(.value.quantity != null)
            | select((.value.quantity | type) == "number")
            | select((.value.unit // "") | contains("°C"))
            | [.key, (.value.key // ""), (.value.type // ""), (.value.quantity | tostring)]
            | @tsv
          ' "$tmp_ismc" \
            | awk -F "\t" '
                function esc(value) {
                  gsub(/\\/, "\\\\", value)
                  gsub(/"/, "\\\"", value)
                  gsub(/\n/, "\\n", value)
                  return value
                }
                function update_group(group, temp) {
                  if (!(group in group_max) || temp > group_max[group]) {
                    group_max[group] = temp
                  }
                }
                function classify_and_update(name, temp, lower) {
                  lower = tolower(name)

                  if (lower ~ /^cpu performance core/) {
                    update_group("cpu", temp)
                    update_group("cpu_perf", temp)
                    return "cpu_perf"
                  }
                  if (lower ~ /^cpu efficiency core/) {
                    update_group("cpu", temp)
                    update_group("cpu_eff", temp)
                    return "cpu_eff"
                  }
                  if (lower ~ /^gpu / || lower ~ /^gpu[[:space:]]*[0-9]/ || lower ~ /^gpu heatsink/) {
                    update_group("gpu", temp)
                    return "gpu"
                  }
                  if (lower ~ /^nand/ || lower ~ /^nvme/) {
                    update_group("storage", temp)
                    return "storage"
                  }
                  if (lower ~ /^memory /) {
                    update_group("memory", temp)
                    return "memory"
                  }
                  if (lower ~ /^power supply/) {
                    update_group("power_supply", temp)
                    return "power_supply"
                  }
                  if (lower ~ /^pmu2? /) {
                    update_group("pmu", temp)
                    return "pmu"
                  }
                  if (lower ~ /^battery / || lower ~ /^gas gauge battery/) {
                    update_group("battery", temp)
                    return "battery"
                  }
                  if (lower ~ /^airport /) {
                    update_group("wireless", temp)
                    return "wireless"
                  }
                  if (lower ~ /^pcie /) {
                    update_group("pcie", temp)
                    return "pcie"
                  }

                  update_group("other", temp)
                  return "other"
                }
                {
                  sensor_name = $1
                  sensor_key = $2
                  sensor_type = $3
                  temp = $4 + 0
                  sensor_group = classify_and_update(sensor_name, temp)

                  if (!seen_any || temp > max_temp) {
                    max_temp = temp
                    seen_any = 1
                  }

                  printf "host_observability_darwin_temperature_celsius{sensor_name=\"%s\",sensor_key=\"%s\",sensor_type=\"%s\",sensor_group=\"%s\"} %.6f\n",
                    esc(sensor_name), esc(sensor_key), esc(sensor_type), esc(sensor_group), temp
                }
                END {
                  if (seen_any) {
                    printf "host_observability_darwin_temperature_max_celsius %.6f\n", max_temp
                  }
                  for (group in group_max) {
                    printf "host_observability_darwin_temperature_group_max_celsius{group=\"%s\"} %.6f\n", esc(group), group_max[group]
                  }
                }
              '
        fi
      } >"$tmp_metrics"

      chmod 0644 "$tmp_metrics"
      mv "$tmp_metrics" ${textfileDir}/thermal.prom
    '';
  };
in
{
  options.host.observability.thermal = {
    enable = lib.mkEnableOption "Darwin thermal and power metrics export";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.ismc;
      description = "iSMC package used to collect Darwin temperature sensors.";
    };

    intervalSeconds = lib.mkOption {
      type = lib.types.int;
      default = 30;
      description = "How often to sample Darwin thermal state and power metrics.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    assertions = [
      {
        assertion = config.host.observability.lanWan.enable;
        message = "Darwin thermal export currently requires host.observability.lanWan.enable so node exporter textfile support is configured.";
      }
    ];

    system.activationScripts.postActivation.text = lib.mkAfter ''
      mkdir -p ${stateDir}
      chmod 0755 ${stateDir}
    '';

    launchd.daemons.observability-thermal-export = {
      serviceConfig = {
        ProgramArguments = [ (lib.getExe exportMetrics) ];
        RunAtLoad = true;
        StartInterval = cfg.intervalSeconds;
        StandardOutPath = "/var/log/observability-thermal-export.log";
        StandardErrorPath = "/var/log/observability-thermal-export.log";
      };
    };
  };
}
