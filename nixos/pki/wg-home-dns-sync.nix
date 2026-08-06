{
  config,
  hostInventory,
  lib,
  pkiPkgs,
  pkgs,
  ...
}:
let
  internalPkiRootCaPath = config.host.internalPki.rootCaCertificate;
  unifiSyncCfg = config.services.unifi-sync;
  unifiSyncEnv = import ./unifi-sync-env.nix { inherit hostInventory; };
  lan = hostInventory.site.lan;
  wgHome = hostInventory.site.wireguard.home;
  wgHomeExporterPort = 9586;
  wgHomeExporterHost = "gw.${lan.domain}";
  wgHomeDnsSyncClientSecretPrefix = "prometheus/clients/wg-home-dns-sync";
  wgHomeDnsPeers = lib.mapAttrsToList (name: peer: {
    inherit name;
    address = builtins.head (lib.splitString "/" peer.address);
    domain = "${peer.host}.${lan.domain}";
    inherit (peer) publicKey;
  }) (lib.filterAttrs (_name: peer: peer ? host) wgHome.peers);
  wgHomeDnsPeersFile = pkgs.writeText "wg-home-dns-peers.json" (builtins.toJSON wgHomeDnsPeers);
in
{
  sops.secrets.unifiApiKey.restartUnits = [ "wg-home-dns-sync.service" ];
  sops.templates."unifi-sync.env".restartUnits = [ "wg-home-dns-sync.service" ];

  host.observability.client.mtlsClients."wg-home-dns-sync" = {
    enable = true;
    secretPrefix = wgHomeDnsSyncClientSecretPrefix;
  };

  sops.secrets.wgHomeDnsSyncClientCrt = {
    key = "${wgHomeDnsSyncClientSecretPrefix}/client_crt_unencrypted";
    owner = unifiSyncCfg.user;
    group = unifiSyncCfg.group;
    mode = "0400";
    restartUnits = [ "wg-home-dns-sync.service" ];
  };

  sops.secrets.wgHomeDnsSyncClientKey = {
    key = "${wgHomeDnsSyncClientSecretPrefix}/client_key";
    owner = unifiSyncCfg.user;
    group = unifiSyncCfg.group;
    mode = "0400";
    restartUnits = [ "wg-home-dns-sync.service" ];
  };

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
      User = unifiSyncCfg.user;
      Group = unifiSyncCfg.group;
      EnvironmentFile = config.sops.templates."unifi-sync.env".path;
      ExecStart = "${lib.getExe pkiPkgs.wg-home-dns-sync} --status-url https://${wgHomeExporterHost}:${toString wgHomeExporterPort}/metrics --ca-file ${internalPkiRootCaPath} --client-cert-file ${config.sops.secrets.wgHomeDnsSyncClientCrt.path} --client-key-file ${config.sops.secrets.wgHomeDnsSyncClientKey.path} --handshake-max-age-seconds 180 --peers-json-file ${wgHomeDnsPeersFile}";
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
