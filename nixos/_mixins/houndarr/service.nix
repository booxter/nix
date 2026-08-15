{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model) cfg;
  instances = builtins.filter (instance: instance.apiRegistration != null) (
    builtins.attrValues model.instances
  );
  apiUnits = lib.unique (
    builtins.filter (unit: unit != null) (map (instance: instance.apiRegistration.localUnit) instances)
  );
  runtimeUnits = [
    "nginx.service"
  ]
  ++ map (unit: "${lib.removeSuffix ".service" unit}.service") apiUnits;
  allowedCidrs = lib.unique (
    builtins.concatMap (instance: instance.apiRegistration.allowedCidrs) instances
  );
in
{
  config = lib.mkIf cfg.enable {
    users.groups.${cfg.group} = { };
    users.users.${cfg.user} = {
      description = "Houndarr service user";
      isSystemUser = true;
      group = cfg.group;
      home = "/var/empty";
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0700 ${cfg.user} ${cfg.group} - -"
    ];

    systemd.services.houndarr = {
      description = "Polite application search scheduler";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      requires = [ "houndarr-reconcile.service" ] ++ runtimeUnits;
      after = [
        "network-online.target"
        "houndarr-reconcile.service"
      ]
      ++ runtimeUnits;
      partOf = runtimeUnits;
      environment = {
        FORWARDED_ALLOW_IPS = "";
        HOUNDARR_AUTH_MODE = "proxy";
        HOUNDARR_AUTH_PROXY_HEADER = cfg.authProxy.userHeader;
        HOUNDARR_COOKIE_SAMESITE = "lax";
        HOUNDARR_DATA_DIR = cfg.stateDir;
        HOUNDARR_DEV = "false";
        HOUNDARR_HOST = "127.0.0.1";
        HOUNDARR_LOG_LEVEL = "info";
        HOUNDARR_PORT = toString cfg.port;
        HOUNDARR_SECURE_COOKIES = "true";
        HOUNDARR_TRUSTED_PROXIES = "127.0.0.1/32";
        SSL_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt";
      };
      serviceConfig = {
        ExecStart = lib.getExe cfg.package;
        Restart = "on-failure";
        RestartSec = "5s";
        User = cfg.user;
        Group = cfg.group;
        UMask = "0077";
        CapabilityBoundingSet = "";
        DevicePolicy = "closed";
        IPAddressAllow = [ "localhost" ] ++ allowedCidrs;
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
        ReadWritePaths = [ cfg.stateDir ];
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
      unitConfig.RequiresMountsFor = cfg.stateDir;
    };
  };
}
