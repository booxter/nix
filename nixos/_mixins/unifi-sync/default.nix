{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.unifi-sync;
  realmUnifi = hostInventory.realms.${config.host.realm}.services.unifi or null;
  isSyncHost = realmUnifi != null && realmUnifi.syncHost == config.networking.hostName;
  package = pkgs.callPackage ./package { };
  renderedEnvironment = import ./environment.nix {
    baseUrl = if realmUnifi == null then "" else realmUnifi.baseUrl;
    inherit hostInventory;
    site = if realmUnifi == null then "" else realmUnifi.site;
  };
  payloadHash = builtins.hashString "sha256" (builtins.toJSON cfg.environment);
in
{
  options.services.unifi-sync = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = isSyncHost;
      readOnly = true;
      internal = true;
      description = "Whether this host owns UniFi synchronization for its realm.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "unifi-sync";
      description = "User account under which unifi-sync runs.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "unifi-sync";
      description = "Group under which unifi-sync runs.";
    };

    environment = lib.mkOption {
      type = with lib.types; attrsOf str;
      default = renderedEnvironment.environment;
      readOnly = true;
      internal = true;
      description = "Inventory rendered for unifi-sync.";
    };

    runOnConfigurationChange = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run unifi-sync during activation when its environment changes.";
    };

    timer = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run unifi-sync periodically.";
      };

      onBootSec = lib.mkOption {
        type = lib.types.str;
        default = "10m";
        description = "Delay after boot before the first synchronization.";
      };

      onUnitActiveSec = lib.mkOption {
        type = lib.types.str;
        default = "1h";
        description = "Interval between synchronizations.";
      };

      randomizedDelaySec = lib.mkOption {
        type = lib.types.str;
        default = "10m";
        description = "Maximum random delay added to timer runs.";
      };

      persistent = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run a missed synchronization after the host resumes or boots.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = realmUnifi != null && realmUnifi.syncHost == config.networking.hostName;
        message = "UniFi synchronization must run on the sync host assigned by the realm";
      }
    ];

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
    };

    users.groups.${cfg.group} = { };

    sops.secrets.unifiApiKey = {
      key = "unifi/api_key";
      owner = cfg.user;
      group = cfg.group;
      mode = "0400";
      restartUnits = [ "unifi-sync.service" ];
    };

    sops.templates."unifi-sync.env" = {
      owner = cfg.user;
      group = cfg.group;
      mode = "0400";
      content = ''
        UNIFI_API_KEY=${config.sops.placeholder.unifiApiKey}
      '';
      restartUnits = [ "unifi-sync.service" ];
    };

    system.activationScripts.unifiSyncApply = lib.mkIf cfg.runOnConfigurationChange {
      deps = [ "etc" ];
      text = ''
        if [ "''${NIXOS_ACTION:-}" = "dry-activate" ]; then
          exit 0
        fi

        stamp_dir=/var/lib/unifi-sync
        stamp_file="$stamp_dir/last-applied-payload"
        next=${lib.escapeShellArg payloadHash}
        previous=

        if [ -r "$stamp_file" ]; then
          previous="$(${pkgs.coreutils}/bin/cat "$stamp_file")"
        fi

        if [ "$previous" != "$next" ]; then
          ${pkgs.coreutils}/bin/install -d -m 0755 "$stamp_dir"
          if [ -d /run/systemd/system ]; then
            ${config.systemd.package}/bin/systemctl daemon-reload
            ${config.systemd.package}/bin/systemctl start unifi-sync.service
          fi
          ${pkgs.coreutils}/bin/printf '%s\n' "$next" > "$stamp_file"
        fi
      '';
    };

    systemd.services.unifi-sync = {
      description = "Sync UniFi reservations, DHCP, DNS, and routes";
      wants = [
        "network-online.target"
        "sops-install-secrets.service"
      ];
      after = [
        "network-online.target"
        "sops-install-secrets.service"
      ];
      environment = cfg.environment;
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = cfg.group;
        EnvironmentFile = config.sops.templates."unifi-sync.env".path;
        ExecStart = lib.getExe package;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ProtectControlGroups = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
      };
    };

    systemd.timers.unifi-sync = lib.mkIf cfg.timer.enable {
      description = "Periodically sync UniFi reservations, DHCP, DNS, and routes";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = cfg.timer.onBootSec;
        OnUnitActiveSec = cfg.timer.onUnitActiveSec;
        RandomizedDelaySec = cfg.timer.randomizedDelaySec;
        Persistent = cfg.timer.persistent;
        Unit = "unifi-sync.service";
      };
    };
  };
}
