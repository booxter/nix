{
  config,
  lib,
  outputs,
  pkgs,
  ...
}:
let
  unifiPkgs = import ./pkgs pkgs;
  serviceAccount = "unifi-sync";
  controller = config.host.site.lan.ipController;
  pkiRootCaPath = config.host.pki.authority.rootCaCertificate;
  lanDomain = config.host.network.lanDomain;
  wgHome = config.host.wireguard.networks.home or null;
  wgHomeServerConfig = outputs.nixosConfigurations.${wgHome.server.host}.config;
  wgHomeEndpoint = wgHomeServerConfig.host.observability.prometheusEndpoints."wg-home";
  wgHomeDnsSyncClientSecretPrefix = "prometheus/clients/wg-home-dns-sync";
  wgHomeDnsSyncClient = config.host.pki.clients."wg-home-dns-sync";
  wgHomeDnsPeers = lib.mapAttrsToList (name: peer: {
    inherit name;
    inherit (peer) address;
    domain = "${peer.host}.${lanDomain}";
    inherit (peer) publicKey;
  }) (lib.filterAttrs (_name: peer: peer.host != null) wgHome.peers);
  wgHomeDnsPeersFile = pkgs.writeText "wg-home-dns-peers.json" (builtins.toJSON wgHomeDnsPeers);
in
lib.mkIf (config.host.network.ipController.enable && wgHome != null) {
  sops.secrets.unifiApiKey.restartUnits = [ "wg-home-dns-sync.service" ];
  sops.templates."unifi-sync.env".restartUnits = [ "wg-home-dns-sync.service" ];

  host.pki.clients."wg-home-dns-sync" = {
    enable = true;
    category = "observability";
    secretPrefix = wgHomeDnsSyncClientSecretPrefix;
    materializations.default = {
      owner = serviceAccount;
      group = serviceAccount;
      restartUnits = [ "wg-home-dns-sync.service" ];
    };
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
      UNIFI_BASE_URL = controller.endpoint;
      UNIFI_SITE = controller.site;
    };
    serviceConfig = {
      Type = "oneshot";
      User = serviceAccount;
      Group = serviceAccount;
      EnvironmentFile = config.sops.templates."unifi-sync.env".path;
      ExecStart = "${lib.getExe unifiPkgs.wg-home-dns-sync} --status-url https://${wgHomeEndpoint.serverName}:${toString wgHomeEndpoint.port}${wgHomeEndpoint.path} --ca-file ${pkiRootCaPath} --client-cert-file ${wgHomeDnsSyncClient.materializations.default.certificatePath} --client-key-file ${wgHomeDnsSyncClient.materializations.default.keyPath} --handshake-max-age-seconds 180 --peers-json-file ${wgHomeDnsPeersFile}";
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
