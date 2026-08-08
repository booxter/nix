{
  config,
  hostInventory,
  lib,
  outputs,
  ...
}:
let
  cfg = config.services.transmission;
  hostname = config.networking.hostName;
  instance = hostInventory.servicesById.transmission.instances.${hostname} or { };
  policy = instance.adaptiveUpload or { };
  targetNames = instance.bandwidthTargets or { };
  target = name: config.host.network.bandwidthTargets.${targetNames.${name}};
  conservativeUpload = target "conservativeUpload";
  bulkDownload = target "bulkDownload";
  idleUpload = target "idleUpload";
  vpnProfile = hostInventory.egressVpns.${instance.vpnConfinement.profile};
  sourceService = hostInventory.servicesById.${policy.sourceService};
  sourceHostConfig = outputs.nixosConfigurations.${hostInventory.serviceHost sourceService}.config;
  sourceEndpoint = sourceHostConfig.host.observability.metricsEndpoints.jellyfin;
  clientName = "jellyfin-upload-policy";
  client = config.host.internalPki.clients.${clientName};
in
{
  config = lib.mkIf (config.host.transmission.enable && cfg.adaptiveUpload.enable) {
    assertions = [
      {
        assertion = policy.sourceService == "jellyfin";
        message = "Transmission adaptive upload currently requires Jellyfin as its playback source.";
      }
      {
        assertion =
          conservativeUpload.link == "internet"
          && conservativeUpload.direction == "egress"
          && idleUpload.link == "internet"
          && idleUpload.direction == "egress"
          && bulkDownload.link == "internet"
          && bulkDownload.direction == "ingress";
        message = "Transmission adaptive upload requires egress upload and ingress download internet targets.";
      }
    ];

    services.adaptive-upload-policy = {
      enable = true;
      fallbackRateMbit = conservativeUpload.rateMbit;
      policy.idleRateMbit = idleUpload.rateMbit;
      source.jellyfin = {
        exporterUrl = "https://${sourceHostConfig.networking.hostName}:${toString sourceEndpoint.port}${sourceEndpoint.path}";
        mtls = {
          enable = true;
          certificateFile = config.sops.secrets.${client.materializations.default.certificateSecretName}.path;
          keyFile = config.sops.secrets.${client.materializations.default.keySecretName}.path;
          dependencyUnits = [ "sops-install-secrets.service" ];
        };
      };
      outputs.qos = {
        enable = true;
        profile = "wan";
        limit = "wireguard-upload";
      };
      group = "media";
    };

    host.internalPki.clients.${clientName} = {
      enable = true;
      category = "internal";
      secretPrefix = "prometheus/clients/jellyfin-upload-policy";
      materializations.default = {
        owner = config.services.adaptive-upload-policy.user;
        group = config.services.adaptive-upload-policy.group;
        restartUnits = [ "adaptive-upload-policy.service" ];
      };
    };

    host.qos.interfaces.wan = {
      device = config.host.network.primaryInterface;
      limits = {
        wireguard-download = {
          direction = "ingress";
          rateMbit = bulkDownload.rateMbit;
          match = {
            protocol = "udp";
            sourcePort = vpnProfile.endpointPort;
          };
        };
        wireguard-upload = {
          rateMbit = conservativeUpload.rateMbit;
          queue = "cake";
          match = {
            protocol = "udp";
            destinationPort = vpnProfile.endpointPort;
          };
        };
      };
    };

    host.observability.lanWan = {
      # nft postrouting overcounts the WireGuard transport on this host, so use
      # the shaped tc class as the authoritative WAN egress counter instead.
      wanTransmitTcClass = config.host.qos.classIds.wan.wireguard-upload;
      wanUdpSubclass = {
        name = vpnProfile.namespace;
        port = vpnProfile.endpointPort;
      };
    };
  };
}
