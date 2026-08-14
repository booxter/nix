{
  config,
  fleetWebServices,
  lib,
  pkgs,
  ...
}:
let
  unifiPkgs = import ./pkgs pkgs;
  serviceAccount = "unifi-sync";
  controller = config.host.site.lan.ipController;
  siteNetwork = import ../../../../common/_lib/site-network.nix { inherit config; };
  webDnsRecords = import ../../../_lib/fleet-web-dns-records.nix {
    fleetServices = fleetWebServices;
    addressFor = siteNetwork.addressFor;
  };
  wireguardStaticRoutes = lib.mapAttrsToList (name: network: {
    destination = network.cidr;
    nextHopHost = network.server.host;
    distance = 1;
    name = "wg-${name}";
  }) config.host.wireguard.networks;
  unifiSyncEnv = import ./environment.nix {
    inherit webDnsRecords;
    addressFor = siteNetwork.addressFor;
    baseUrl = controller.endpoint;
    lan = config.host.site.lan;
    lanDomain = config.host.network.lanDomain;
    reservations = config.host.site.lan.reservations;
    site = controller.site;
    staticRoutes = wireguardStaticRoutes;
  };
  environment = unifiSyncEnv.environment;
  payloadHash = builtins.hashString "sha256" (builtins.toJSON environment);
in
{
  imports = [ ./wireguard-dns-sync.nix ];

  config = lib.mkIf config.host.network.ipController.enable {
    users.users.${serviceAccount} = {
      isSystemUser = true;
      group = serviceAccount;
    };
    users.groups.${serviceAccount} = { };

    sops.secrets.unifiApiKey = {
      key = "unifi/api_key";
      owner = serviceAccount;
      group = serviceAccount;
      mode = "0400";
      restartUnits = [ "unifi-sync.service" ];
    };

    sops.templates."unifi-sync.env" = {
      owner = serviceAccount;
      group = serviceAccount;
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
      environment = environment;
      serviceConfig = {
        Type = "oneshot";
        User = serviceAccount;
        Group = serviceAccount;
        EnvironmentFile = config.sops.templates."unifi-sync.env".path;
        ExecStart = lib.getExe unifiPkgs.unifi-sync;
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
      description = "Periodically sync UniFi reservations, DHCP, DNS, and routes";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10m";
        OnUnitActiveSec = "1h";
        RandomizedDelaySec = "10m";
        Persistent = true;
        Unit = "unifi-sync.service";
      };
    };
  };
}
