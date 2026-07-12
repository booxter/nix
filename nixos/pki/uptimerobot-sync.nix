{
  config,
  hostInventory,
  lib,
  pkiPkgs,
  pkgs,
  ...
}:
let
  servicesFile = pkgs.writeText "uptimerobot-services.json" (
    builtins.toJSON (
      map (service: {
        inherit (service) id title;
        url = service.probeUrl;
      }) hostInventory.publicServices
    )
  );
in
{
  users.users.uptimerobot-sync = {
    isSystemUser = true;
    group = "uptimerobot-sync";
  };

  users.groups.uptimerobot-sync = { };

  sops.secrets.uptimeRobotApiKey = {
    key = "uptimerobot/api_key";
  };

  systemd.services.uptimerobot-sync = {
    description = "Sync UptimeRobot monitors from service inventory";
    wants = [
      "network-online.target"
      "sops-install-secrets.service"
    ];
    after = [
      "network-online.target"
      "sops-install-secrets.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      User = "uptimerobot-sync";
      Group = "uptimerobot-sync";
      LoadCredential = "uptimerobot-api-key:${config.sops.secrets.uptimeRobotApiKey.path}";
      ExecStart = "${lib.getExe pkiPkgs.uptimerobot-sync} ${
        lib.escapeShellArgs [
          "--api-key-file"
          "%d/uptimerobot-api-key"
          "--inventory-json-file"
          servicesFile
        ]
      }";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ProtectControlGroups = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
      ];
      RestrictSUIDSGID = true;
      SystemCallArchitectures = "native";
    };
  };

  systemd.timers.uptimerobot-sync = {
    description = "Periodically sync UptimeRobot monitors from service inventory";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5m";
      OnUnitActiveSec = "1h";
      RandomizedDelaySec = "10m";
      Persistent = true;
      Unit = "uptimerobot-sync.service";
    };
  };
}
