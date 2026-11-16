{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.mediaRepair;
  serviceUser = "media-repair-worker";
  storageIdentities = import ../storage/identities.nix;
  webService = config.host.web.services.repairr;
  internalWeb = webService.internal;
  localAliases = internalWeb.localAliases ++ map (alias: "${alias}.local") internalWeb.localAliases;
  publicAliases =
    internalWeb.publicAliases
    ++ lib.optional (
      webService.public != null && webService.public.serveOnOwner
    ) webService.public.hostName;
  origins = map (host: "https://${host}") (
    lib.unique ([ internalWeb.serverName ] ++ internalWeb.aliases ++ localAliases ++ publicAliases)
  );
  clients = config.host.downloads.clients;
  rootPaths = builtins.attrValues cfg.roots;
  mediaHelper = import ./helper.nix {
    inherit lib pkgs;
    inherit (cfg) roots;
  };
  credentials = "/run/credentials/repairr.service";
  configuration = pkgs.formats.json { };
  configFile = configuration.generate "repairr.json" {
    Database = "/var/lib/repairr/jobs.db";
    MetricsFile = "/var/lib/prometheus-node-exporter-textfile/repairr/repairr.prom";
    Listen = "127.0.0.1:${toString cfg.port}";
    Origins = origins;
    Roots = cfg.roots;
    Helper = mediaHelper;
    PlannerSocket = cfg.planner.socketPath;
    TraceEndpoint = (import ../observability/tempo/paths.nix).endpoint;
    Timeouts = {
      RequestSeconds = 30;
      ProbeSeconds = 30;
      MediaSeconds = 60 * 60;
      PlanningSeconds = cfg.planner.planningTimeoutSeconds;
      ResponseGraceSeconds = 60;
    };
    TransmissionURL = clients.transmission.endpoint;
    SABnzbdURL = clients.sabnzbd.endpoint;
    SABnzbdKeyFile = "${credentials}/sabnzbd-api-key";
    Radarr = {
      URL = "http://127.0.0.1:${toString config.services.radarr.settings.server.port}";
      APIKeyFile = "${credentials}/radarr-api-key";
      QueueURL = "https://radarr.${config.host.network.lanDomain}/activity/queue";
      DisableFile = "/run/radarr-repair-disable-apply";
    };
    Lidarr = {
      URL = "http://127.0.0.1:${toString config.services.lidarr.settings.server.port}";
      APIKeyFile = "${credentials}/lidarr-api-key";
      QueueURL = "https://lidarr.${config.host.network.lanDomain}/activity/queue";
      DisableFile = "/run/lidarr-repair-disable-apply";
    };
  };
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = rootPaths != [ ] && !(builtins.elem "/" rootPaths);
        message = "Repairr requires media roots and cannot expose the filesystem root.";
      }
    ];
    host.mediaRepair.planner.enable = true;
    users.groups.repairr = { };
    users.users.${serviceUser} = {
      isSystemUser = true;
      group = "repairr";
      home = "/var/empty";
      uid = storageIdentities.users.${serviceUser}.uid;
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/repairr 0700 ${serviceUser} repairr - -"
      "d /var/lib/prometheus-node-exporter-textfile/repairr 0755 ${serviceUser} repairr - -"
    ];
    users.groups.telemetry = { };
    systemd.services.repairr = {
      description = "Media repair controller and operator inbox";
      wantedBy = [ "multi-user.target" ];
      wants = lib.optional config.services.alloy.enable "alloy.service";
      requires = [ "media-repair-planner.socket" ];
      after = [
        "media-repair-planner.socket"
        "sops-install-secrets.service"
        "radarr.service"
        "lidarr.service"
        "transmission.service"
        "sabnzbd.service"
      ]
      ++ lib.optional config.services.alloy.enable "alloy.service";
      unitConfig.RequiresMountsFor = rootPaths;
      serviceConfig = {
        ExecStart = "${lib.getExe pkgs.repairr} --config ${configFile}";
        User = serviceUser;
        Group = "media";
        SupplementaryGroups = [
          "repairr"
          "telemetry"
          cfg.planner.clientGroup
        ];
        StateDirectory = "repairr";
        StateDirectoryMode = "0700";
        LoadCredential = [
          "radarr-api-key:${config.sops.secrets."radarr/apiKey".path}"
          "lidarr-api-key:${config.sops.secrets."lidarr/apiKey".path}"
          "sabnzbd-api-key:${config.sops.secrets.${clients.sabnzbd.authentication.secret}.path}"
        ];
        Restart = "on-failure";
        RestartSec = "5s";
        TimeoutStopSec = "45s";
        UMask = "0077";
        AmbientCapabilities = "";
        CapabilityBoundingSet = "";
        IPAddressAllow = [ "localhost" ];
        IPAddressDeny = "any";
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectKernelModules = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        ReadWritePaths = rootPaths ++ [ "/var/lib/prometheus-node-exporter-textfile/repairr" ];
        RemoveIPC = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK" # Bubblewrap initializes loopback in its network namespace.
        ];
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
        # The helper creates its own namespaces and cannot see credentials or
        # the jobs database. RestrictNamespaces would prevent that isolation.
      };
    };

    host.web.services.repairr = {
      upstream = "http://127.0.0.1:${toString cfg.port}";
      auth.policy = "media-admin";
    };
  };
}
