{
  config,
  hostInventory,
  lib,
  srvarrPkgs,
  utils,
  ...
}:
let
  port = 8877;
  arrServiceNames = [
    "lidarr"
    "radarr"
    "sonarr"
  ];
  arrServiceUnits = map (name: "${name}.service") arrServiceNames;
  runtimeUnits = [ "nginx.service" ] ++ arrServiceUnits;
  arrProbeUrls = map (
    name: "https://${name}.${hostInventory.site.lan.domain}:9443/ping"
  ) arrServiceNames;
  srvarrAddress = hostInventory.toNixosHostIpv4Address "srvarr";
  stateDir = "${config.host.srvarrPaths.stateDir}/houndarr";
  nodeExporterTextfileDir = "/var/lib/prometheus-node-exporter-textfile";
  statusMetricsFile = "${nodeExporterTextfileDir}/houndarr-status.prom";
  waitForArrBackendsCommand = utils.escapeSystemdExecArgs (
    [
      (lib.getExe' srvarrPkgs.houndarr-tools "wait-for-houndarr-arr-backends")
      "--timeout-seconds"
      "120"
    ]
    ++ lib.concatMap (url: [
      "--url"
      url
    ]) arrProbeUrls
  );
  statusCollectorCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' srvarrPkgs.houndarr-tools "houndarr-status-collector")
    "--url"
    "http://127.0.0.1:${toString port}/api/status"
    "--metrics-file"
    statusMetricsFile
  ];
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
      # Houndarr persists the newest cycle error. Keep it stopped throughout
      # proxy or Arr restarts so deployment downtime does not become a stale
      # degraded state, then start it only after the dependency transaction.
      requires = runtimeUnits;
      after = [ "network-online.target" ] ++ runtimeUnits;
      partOf = runtimeUnits;
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
        # Servarr units can be active before their HTTP APIs accept requests.
        ExecStartPre = waitForArrBackendsCommand;
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
        ExecStart = statusCollectorCommand;
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
