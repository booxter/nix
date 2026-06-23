{
  config,
  hostInventory,
  lib,
  pkiPkgs,
  pkgs,
  ...
}:
let
  unifiSyncEnv = import ../../lib/unifi-sync-env.nix { inherit hostInventory; };
  unifiSyncPayloadHash = builtins.hashString "sha256" (builtins.toJSON unifiSyncEnv.environment);
in
{
  users.users.unifi-sync = {
    isSystemUser = true;
    group = "unifi-sync";
  };

  users.groups.unifi-sync = { };

  sops.secrets.unifiApiKey = {
    key = "unifi/api_key";
    owner = "unifi-sync";
    group = "unifi-sync";
    mode = "0400";
    restartUnits = [ "unifi-sync.service" ];
  };

  sops.templates."unifi-sync.env" = {
    owner = "unifi-sync";
    group = "unifi-sync";
    mode = "0400";
    content = ''
      UNIFI_API_KEY=${config.sops.placeholder.unifiApiKey}
    '';
    restartUnits = [ "unifi-sync.service" ];
  };

  system.activationScripts.unifiSyncApply = {
    deps = [ "etc" ];
    text = ''
      if [ "''${NIXOS_ACTION:-}" = "dry-activate" ]; then
        exit 0
      fi

      stamp_dir=/var/lib/unifi-sync
      stamp_file="$stamp_dir/last-applied-payload"
      next=${lib.escapeShellArg unifiSyncPayloadHash}
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
    description = "Sync UniFi reservations, DHCP, and DNS from inventory";
    wants = [
      "network-online.target"
      "sops-install-secrets.service"
    ];
    after = [
      "network-online.target"
      "sops-install-secrets.service"
    ];
    environment = unifiSyncEnv.environment;
    serviceConfig = {
      Type = "oneshot";
      User = "unifi-sync";
      Group = "unifi-sync";
      EnvironmentFile = config.sops.templates."unifi-sync.env".path;
      ExecStart = lib.getExe pkiPkgs.unifi-sync;
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

  systemd.timers.unifi-sync = {
    description = "Periodically sync UniFi reservations, DHCP, and DNS";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10m";
      OnUnitActiveSec = "1h";
      RandomizedDelaySec = "10m";
      Persistent = true;
      Unit = "unifi-sync.service";
    };
  };
}
