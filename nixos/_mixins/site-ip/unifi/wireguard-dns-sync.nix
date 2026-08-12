{
  config,
  facts,
  lib,
  outputs,
  pkgs,
  ...
}:
let
  unifiPkgs = import ./pkgs pkgs;
  controller = config.host.network.ipController;
  fleetWireguardEnabled = config.host.wireguard.networks != { };
  internalPkiRootCaPath = config.host.internalPki.rootCaCertificate;
  unifiSyncCfg = config.services.unifi-sync;
  lanDomain = config.host.network.lanDomain;
  fleetServices = import ../../../_lib/fleet-web-services.nix {
    inherit config lib outputs;
  };
  fleetNetwork = import ../../../_lib/fleet-host-network.nix { inherit config outputs; };
  webDnsRecords = import ../../../_lib/fleet-web-dns-records.nix {
    inherit fleetServices;
    addressFor = fleetNetwork.addressFor;
  };
  unifiSyncEnv = import ./environment.nix {
    inherit facts lanDomain webDnsRecords;
    addressFor = fleetNetwork.addressFor;
    baseUrl = controller.target.endpoint;
    reservations = config.host.network.ipController.reservations;
    site = controller.target.site;
  };
  wgHome = config.host.wireguard.networks.home;
  wgHomeServerConfig = outputs.nixosConfigurations.${wgHome.server.host}.config;
  wgHomeEndpoint = wgHomeServerConfig.host.observability.prometheusEndpoints."wg-home";
  wgHomeDnsSyncClientSecretPrefix = "prometheus/clients/wg-home-dns-sync";
  wgHomeDnsSyncClient = config.host.internalPki.clients."wg-home-dns-sync";
  wgHomeDnsPeers = lib.mapAttrsToList (name: peer: {
    inherit name;
    inherit (peer) address;
    domain = "${peer.host}.${lanDomain}";
    inherit (peer) publicKey;
  }) (lib.filterAttrs (_name: peer: peer.host != null) wgHome.peers);
  wgHomeDnsPeersFile = pkgs.writeText "wg-home-dns-peers.json" (builtins.toJSON wgHomeDnsPeers);
in
lib.mkIf (controller.enable && controller.flavor == "unifi" && fleetWireguardEnabled) {
  sops.secrets.unifiApiKey.restartUnits = [ "wg-home-dns-sync.service" ];
  sops.templates."unifi-sync.env".restartUnits = [ "wg-home-dns-sync.service" ];

  host.internalPki.clients."wg-home-dns-sync" = {
    enable = true;
    category = "observability";
    secretPrefix = wgHomeDnsSyncClientSecretPrefix;
    materializations.default = {
      owner = unifiSyncCfg.user;
      group = unifiSyncCfg.group;
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
      UNIFI_BASE_URL = unifiSyncEnv.baseUrl;
      UNIFI_SITE = unifiSyncEnv.site;
    };
    serviceConfig = {
      Type = "oneshot";
      User = unifiSyncCfg.user;
      Group = unifiSyncCfg.group;
      EnvironmentFile = config.sops.templates."unifi-sync.env".path;
      ExecStart = "${lib.getExe unifiPkgs.wg-home-dns-sync} --status-url https://${wgHomeEndpoint.serverName}:${toString wgHomeEndpoint.port}${wgHomeEndpoint.path} --ca-file ${internalPkiRootCaPath} --client-cert-file ${
        config.sops.secrets.${wgHomeDnsSyncClient.materializations.default.certificateSecretName}.path
      } --client-key-file ${
        config.sops.secrets.${wgHomeDnsSyncClient.materializations.default.keySecretName}.path
      } --handshake-max-age-seconds 180 --peers-json-file ${wgHomeDnsPeersFile}";
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
