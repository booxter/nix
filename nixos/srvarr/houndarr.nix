{
  config,
  hostInventory,
  lib,
  pkgs,
  srvarrPkgs,
  ...
}:
let
  port = 8877;
  srvarrAddress = hostInventory.toNixosHostIpv4Address "srvarr";
  stateDir = "${config.host.srvarrPaths.stateDir}/houndarr";
  nodeExporterTextfileDir = "/var/lib/prometheus-node-exporter-textfile";
  statusMetricsFile = "${nodeExporterTextfileDir}/houndarr-status.prom";
  statusCollector = pkgs.writeShellApplication {
    name = "houndarr-status-collector";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      jq
    ];
    text = ''
      set -euo pipefail

      metrics_file=${lib.escapeShellArg statusMetricsFile}
      metrics_dir="$(dirname "$metrics_file")"
      response_file="$(mktemp)"
      tmp_file="$(mktemp "$metrics_dir/.houndarr-status.prom.XXXXXX")"
      trap 'rm -f "$response_file" "$tmp_file"' EXIT

      ok=0
      enabled_instances=0
      active_error_instances=0
      if curl \
        --fail-with-body \
        --silent \
        --show-error \
        --connect-timeout 5 \
        --max-time 30 \
        --header 'X-User: houndarr-monitor' \
        --output "$response_file" \
        http://127.0.0.1:${toString port}/api/status \
        && jq --exit-status '.instances | type == "array"' "$response_file" >/dev/null
      then
        ok=1
        enabled_instances="$(
          jq '[.instances[] | select(.enabled == true)] | length' "$response_file"
        )"
        active_error_instances="$(
          jq '[.instances[] | select(.enabled == true and .active_error == true)] | length' \
            "$response_file"
        )"
      fi

      cat > "$tmp_file" <<EOF
      # HELP host_observability_houndarr_status_ok Whether the latest Houndarr operational status collection succeeded.
      # TYPE host_observability_houndarr_status_ok gauge
      host_observability_houndarr_status_ok $ok
      # HELP host_observability_houndarr_enabled_instances Number of enabled Houndarr Arr instances.
      # TYPE host_observability_houndarr_enabled_instances gauge
      host_observability_houndarr_enabled_instances $enabled_instances
      # HELP host_observability_houndarr_active_error_instances Number of enabled Houndarr Arr instances whose newest cycle result is an error.
      # TYPE host_observability_houndarr_active_error_instances gauge
      host_observability_houndarr_active_error_instances $active_error_instances
      # HELP host_observability_houndarr_status_timestamp_seconds Unix timestamp of the latest Houndarr operational status collection.
      # TYPE host_observability_houndarr_status_timestamp_seconds gauge
      host_observability_houndarr_status_timestamp_seconds $(date +%s)
      EOF
      chmod 0644 "$tmp_file"
      mv "$tmp_file" "$metrics_file"

      [ "$ok" = 1 ]
    '';
  };
in
{
  users = {
    groups.houndarr = { };
    users.houndarr = {
      description = "Houndarr service user";
      isSystemUser = true;
      group = "houndarr";
    };
  };

  systemd = {
    services.houndarr = {
      description = "Polite Arr search scheduler";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "lidarr.service"
        "radarr.service"
        "sonarr.service"
      ];
      environment = {
        # Uvicorn otherwise trusts nginx's X-Forwarded-For and rewrites the
        # ASGI peer to the browser address. Houndarr's proxy-auth trust check
        # must instead see the actual loopback peer; it handles forwarded
        # client addresses itself where needed for rate limiting.
        FORWARDED_ALLOW_IPS = "";
        HOUNDARR_AUTH_MODE = "proxy";
        HOUNDARR_AUTH_PROXY_HEADER = "X-User";
        HOUNDARR_COOKIE_SAMESITE = "lax";
        HOUNDARR_DATA_DIR = stateDir;
        HOUNDARR_DEV = "false";
        HOUNDARR_HOST = "127.0.0.1";
        HOUNDARR_LOG_LEVEL = "info";
        HOUNDARR_PORT = toString port;
        HOUNDARR_SECURE_COOKIES = "true";
        HOUNDARR_TRUSTED_PROXIES = "127.0.0.1/32";
        # httpx otherwise uses certifi's public-only CA set and cannot verify
        # the internal HTTPS certificates on the local Arr API lanes.
        SSL_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt";
      };
      serviceConfig = {
        ExecStart = lib.getExe srvarrPkgs.houndarr;
        Restart = "on-failure";
        RestartSec = "5s";
        User = "houndarr";
        Group = "houndarr";
        UMask = "0077";

        CapabilityBoundingSet = "";
        DevicePolicy = "closed";
        IPAddressAllow = [
          "localhost"
          "${srvarrAddress}/32"
        ];
        IPAddressDeny = "any";
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProcSubset = "pid";
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        ReadWritePaths = [ stateDir ];
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
      };
      unitConfig.RequiresMountsFor = stateDir;
    };

    services.houndarr-status-collector = {
      description = "Collect Houndarr scheduler and Arr-instance status";
      wants = [ "houndarr.service" ];
      after = [ "houndarr.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe statusCollector;
        User = "root";
        Group = "root";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ nodeExporterTextfileDir ];
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
        ];
      };
    };

    timers.houndarr-status-collector = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2m";
        OnUnitActiveSec = "2m";
        AccuracySec = "30s";
      };
    };

    tmpfiles.rules = [
      "d ${stateDir} 0700 houndarr houndarr -"
      "d ${nodeExporterTextfileDir} 0755 root root - -"
    ];
  };

  host.internalHttps.services.houndarr = {
    enable = true;
    upstream = "http://127.0.0.1:${toString port}";
  };
}
