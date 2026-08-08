{
  config,
  hostInventory,
  lib,
  outputs,
  pkgs,
  ...
}:
let
  cfg = config.services.unifi-sync;
  internalPkiRootCaPath = config.host.internalPki.rootCaCertificate;
  unifiSyncPackage = pkgs.callPackage ./package { };
  package = pkgs.callPackage ./wireguard-dns/package { unifiSync = unifiSyncPackage; };
  lan = hostInventory.site.lan;
  realmEndpoints = lib.filterAttrs (
    _: endpoint: hostInventory.nixosHosts.${endpoint.gateway.host}.realm == config.host.realm
  ) hostInventory.site.wireguard;
  endpointData = lib.mapAttrs (
    name: endpoint:
    let
      serviceName = "wg-${name}-dns-sync";
      gatewayConfig = outputs.nixosConfigurations.${endpoint.gateway.host}.config;
    in
    {
      inherit name endpoint serviceName;
      metrics = gatewayConfig.host.observability.metricsEndpoints."wg-${name}";
      client = config.host.internalPki.clients.${serviceName};
      peersFile = pkgs.writeText "${serviceName}-peers.json" (
        builtins.toJSON (
          lib.mapAttrsToList (peerName: peer: {
            name = peerName;
            address = builtins.head (lib.splitString "/" peer.address);
            domain = "${peer.host}.${lan.domain}";
            inherit (peer) publicKey;
          }) (lib.filterAttrs (_: peer: peer ? host) endpoint.peers)
        )
      );
    }
  ) realmEndpoints;
  serviceNames = map (data: data.serviceName) (builtins.attrValues endpointData);
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = endpointData != { };
        message = "UniFi synchronization requires a WireGuard endpoint in realm ${config.host.realm}";
      }
    ];

    sops.secrets.unifiApiKey.restartUnits = map (name: "${name}.service") serviceNames;
    sops.templates."unifi-sync.env".restartUnits = map (name: "${name}.service") serviceNames;

    host.internalPki.clients = lib.mapAttrs' (
      _: data:
      lib.nameValuePair data.serviceName {
        enable = true;
        category = "observability";
        secretPrefix = "prometheus/clients/${data.serviceName}";
        materializations.default = {
          owner = cfg.user;
          group = cfg.group;
          restartUnits = [ "${data.serviceName}.service" ];
        };
      }
    ) endpointData;

    systemd.services = lib.mapAttrs' (
      _: data:
      lib.nameValuePair data.serviceName {
        description = "Sync ${data.name} WireGuard peer DNS overrides to UniFi";
        wants = [
          "network-online.target"
          "sops-install-secrets.service"
        ];
        after = [
          "network-online.target"
          "sops-install-secrets.service"
        ];
        environment = {
          inherit (cfg.environment) UNIFI_BASE_URL UNIFI_SITE;
        };
        serviceConfig = {
          Type = "oneshot";
          User = cfg.user;
          Group = cfg.group;
          EnvironmentFile = config.sops.templates."unifi-sync.env".path;
          ExecStart = "${lib.getExe package} --status-url https://${data.metrics.serverName}:${toString data.metrics.port}${data.metrics.path} --ca-file ${internalPkiRootCaPath} --client-cert-file ${
            config.sops.secrets.${data.client.materializations.default.certificateSecretName}.path
          } --client-key-file ${
            config.sops.secrets.${data.client.materializations.default.keySecretName}.path
          } --handshake-max-age-seconds 180 --peers-json-file ${data.peersFile}";
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
      }
    ) endpointData;

    systemd.timers = lib.mapAttrs' (
      _: data:
      lib.nameValuePair data.serviceName {
        description = "Periodically sync ${data.name} WireGuard peer DNS overrides";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "2m";
          OnUnitActiveSec = "1m";
          RandomizedDelaySec = "10s";
          Persistent = true;
          Unit = "${data.serviceName}.service";
        };
      }
    ) endpointData;
  };
}
