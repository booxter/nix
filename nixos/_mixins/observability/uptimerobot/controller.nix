{
  config,
  lib,
  outputs,
  pkgs,
  ...
}:
let
  cfg = config.host.observability.uptimeRobot.controller;
  model = import ./model.nix {
    inherit
      config
      lib
      outputs
      ;
  };
  describe = contribution: {
    inherit (contribution) id owner;
    inherit (contribution.value.observability) importance;
    requirement = contribution.value.observability.externalProbe.requirement;
    title = contribution.value.displayName;
    url = "${contribution.value.public.url}${contribution.value.health.frontend.path}";
  };
  inventoryFile = (pkgs.formats.json { }).generate "uptimerobot-services.json" (
    map (contribution: {
      inherit (contribution) id;
      title = contribution.value.displayName;
      url = "${contribution.value.public.url}${contribution.value.health.frontend.path}";
    }) model.plan.selected
  );
  planFile = (pkgs.formats.json { }).generate "uptimerobot-plan.json" {
    capacity = cfg.capacity;
    selected = map describe model.plan.selected;
    omitted = map describe model.plan.omitted;
  };
in
{
  config = lib.mkIf cfg.enable {
    users.users.uptimerobot-sync = {
      isSystemUser = true;
      group = "uptimerobot-sync";
    };
    users.groups.uptimerobot-sync = { };

    sops.secrets.${cfg.apiKeySecret} = { };

    system.build.uptimeRobotPlan = planFile;

    systemd.services.uptimerobot-sync = {
      description = "Reconcile capacity-planned UptimeRobot monitors";
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
        LoadCredential = "uptimerobot-api-key:${config.sops.secrets.${cfg.apiKeySecret}.path}";
        ExecStart = "${lib.getExe cfg.package} ${
          lib.escapeShellArgs [
            "--api-url"
            cfg.apiUrl
            "--api-key-file"
            "%d/uptimerobot-api-key"
            "--inventory-json-file"
            inventoryFile
            "--interval"
            (toString cfg.monitorInterval)
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
      description = "Periodically reconcile capacity-planned UptimeRobot monitors";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = cfg.schedule.onBootSec;
        OnUnitActiveSec = cfg.schedule.onUnitActiveSec;
        RandomizedDelaySec = cfg.schedule.randomizedDelaySec;
        Persistent = true;
        Unit = "uptimerobot-sync.service";
      };
    };
  };
}
