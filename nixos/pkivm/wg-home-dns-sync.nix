{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  unifiSyncEnv = import ../../lib/unifi-sync-env.nix { inherit hostInventory; };
  lan = hostInventory.site.lan;
  wgHome = hostInventory.site.wireguard.home;
  wgHomeExporterPort = 9586;
  wgHomeExporterAddress = hostInventory.toNixosHostIpv4Address wgHome.gateway.host;
  wgHomeDnsPeers = lib.mapAttrsToList (name: peer: {
    inherit name;
    address = builtins.head (lib.splitString "/" peer.address);
    domain = "${peer.host}.${lan.domain}";
  }) (lib.filterAttrs (_name: peer: peer ? host) wgHome.peers);
  wgHomeDnsPeersFile = pkgs.writeText "wg-home-dns-peers.json" (builtins.toJSON wgHomeDnsPeers);
in
{
  sops.secrets.unifiApiKey.restartUnits = [ "wg-home-dns-sync.service" ];
  sops.templates."unifi-sync.env".restartUnits = [ "wg-home-dns-sync.service" ];

  systemd.services.wg-home-dns-sync = {
    description = "Sync home WireGuard peer DNS overrides to UniFi";
    wants = [
      "network-online.target"
      "sops-install-secrets.service"
    ];
    after = [
      "network-online.target"
      "sops-install-secrets.service"
    ];
    environment = {
      UNIFI_BASE_URL = unifiSyncEnv.baseUrl;
      UNIFI_SITE = unifiSyncEnv.site;
    };
    serviceConfig = {
      Type = "oneshot";
      User = "unifi-sync";
      Group = "unifi-sync";
      EnvironmentFile = config.sops.templates."unifi-sync.env".path;
      ExecStart = "${lib.getExe pkgs.wg-home-dns-sync} --status-url http://${wgHomeExporterAddress}:${toString wgHomeExporterPort}/peers.json --peers-json-file ${wgHomeDnsPeersFile} --unifi-sync-command ${lib.getExe pkgs.unifi-sync}";
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

  systemd.timers.wg-home-dns-sync = {
    description = "Periodically sync home WireGuard peer DNS overrides";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2m";
      OnUnitActiveSec = "1m";
      RandomizedDelaySec = "10s";
      Persistent = true;
      Unit = "wg-home-dns-sync.service";
    };
  };
}
