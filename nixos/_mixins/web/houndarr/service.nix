{
  config,
  hostInventory,
  lib,
  utils,
  ...
}:
let
  cfg = config.services.houndarr;
  hostCfg = config.host.houndarr;
  hostname = config.networking.hostName;
  service = hostInventory.servicesById.houndarr;
  instance = service.instances.${hostname} or { };
  requiredServices = instance.requiresLocalServices or [ ];
  requiredServiceUnits = map (name: "${name}.service") requiredServices;
  runtimeUnits = [ "nginx.service" ] ++ requiredServiceUnits;
  unknownRequiredServices = builtins.filter (
    name: !builtins.hasAttr name hostInventory.servicesById
  ) requiredServices;
  nonLocalRequiredServices = builtins.filter (
    name:
    builtins.hasAttr name hostInventory.servicesById
    && !builtins.hasAttr hostname hostInventory.servicesById.${name}.instances
  ) requiredServices;
  disabledInternalServices = builtins.filter (
    name: !(config.host.internalService.services.${name}.enable or false)
  ) requiredServices;
  hostAddress = hostInventory.toNixosHostIpv4Address hostname;
  apiVhosts = builtins.listToAttrs (
    map (name: {
      name = "internal-https-${name}-probe";
      value.locations."/api/" = {
        proxyPass = config.host.internalService.services.${name}.upstream;
        recommendedProxySettings = true;
        extraConfig = ''
          auth_request off;
          allow ${hostAddress};
          deny all;
        '';
      };
    }) requiredServices
  );
  probeUrls = map (
    name:
    let
      requiredService = hostInventory.servicesById.${name};
    in
    "https://${name}.${hostInventory.site.lan.domain}:9443${requiredService.backendProbe.path}"
  ) requiredServices;
  waitForBackendsCommand = utils.escapeSystemdExecArgs (
    [
      (lib.getExe' cfg.tools.package "wait-for-houndarr-arr-backends")
      "--timeout-seconds"
      "120"
    ]
    ++ lib.concatMap (url: [
      "--url"
      url
    ]) probeUrls
  );
in
{
  options = {
    host.houndarr.enable = lib.mkOption {
      type = lib.types.bool;
      default = hostInventory.serviceRunsOn hostname service;
      readOnly = true;
      internal = true;
      description = "Whether inventory assigns Houndarr to this host.";
    };

    services.houndarr = {
      enable = lib.mkEnableOption "Houndarr";

      dataDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/houndarr";
        description = "Directory containing Houndarr state.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 8877;
        description = "Loopback port on which Houndarr listens.";
      };

      localUrl = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        internal = true;
        description = "Loopback URL for Houndarr.";
      };
    };
  };

  config = lib.mkMerge [
    {
      services.houndarr.localUrl = "http://127.0.0.1:${toString cfg.port}";
    }

    (lib.mkIf hostCfg.enable {
      assertions = [
        {
          assertion = instance ? dataDir && requiredServices != [ ];
          message = "The Houndarr inventory instance must define dataDir and requiresLocalServices.";
        }
        {
          assertion = unknownRequiredServices == [ ];
          message = "Houndarr requires unknown services: ${lib.concatStringsSep ", " unknownRequiredServices}";
        }
        {
          assertion = nonLocalRequiredServices == [ ];
          message = "Houndarr must be colocated with: ${lib.concatStringsSep ", " nonLocalRequiredServices}";
        }
        {
          assertion = disabledInternalServices == [ ];
          message = "Houndarr requires enabled internal HTTPS endpoints for: ${lib.concatStringsSep ", " disabledInternalServices}";
        }
        {
          assertion = config.host.backups.client.enable;
          message = "The Houndarr host must be a declared backup client.";
        }
      ];

      services.houndarr = {
        enable = true;
        dataDir = instance.dataDir;
      };

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
          requires = runtimeUnits;
          after = [ "network-online.target" ] ++ runtimeUnits;
          partOf = runtimeUnits;
          environment = {
            FORWARDED_ALLOW_IPS = "";
            HOUNDARR_AUTH_MODE = "proxy";
            HOUNDARR_AUTH_PROXY_HEADER = "X-User";
            HOUNDARR_COOKIE_SAMESITE = "lax";
            HOUNDARR_DATA_DIR = cfg.dataDir;
            HOUNDARR_DEV = "false";
            HOUNDARR_HOST = "127.0.0.1";
            HOUNDARR_LOG_LEVEL = "info";
            HOUNDARR_PORT = toString cfg.port;
            HOUNDARR_SECURE_COOKIES = "true";
            HOUNDARR_TRUSTED_PROXIES = "127.0.0.1/32";
            SSL_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt";
          };
          serviceConfig = {
            ExecStartPre = waitForBackendsCommand;
            ExecStart = lib.getExe cfg.package;
            Restart = "on-failure";
            RestartSec = "5s";
            User = "houndarr";
            Group = "houndarr";
            UMask = "0077";
            CapabilityBoundingSet = "";
            DevicePolicy = "closed";
            IPAddressAllow = [
              "localhost"
              "${hostInventory.toNixosHostIpv4Address hostname}/32"
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
            ReadWritePaths = [ cfg.dataDir ];
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
          unitConfig.RequiresMountsFor = cfg.dataDir;
        };

        tmpfiles.rules = [
          "d ${cfg.dataDir} 0700 houndarr houndarr -"
        ];
      };

      host.internalService.services.houndarr = {
        enable = true;
        upstream = cfg.localUrl;
      };

      # Houndarr rejects loopback instance URLs as an SSRF defense. Reuse the
      # required Arr services' probe listeners for a host-only API lane.
      services.nginx.virtualHosts = apiVhosts;
    })
  ];
}
