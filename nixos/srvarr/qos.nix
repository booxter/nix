{
  config,
  hostInventory,
  outputs,
  ...
}:
let
  tuning = config.host.srvarrTuning;
  mediaExport = hostInventory.storage.nfs.exports.media;
  nfsServerConfig = outputs.nixosConfigurations.${mediaExport.server}.config;
  nfsServerAddress = hostInventory.dhcpReservationsByHostname.${mediaExport.server}.ip;
  nfsServerPort = nfsServerConfig.services.nfs.settings.nfsd.port;
  nfsRateMbit = 1500;
  jellyfinService = hostInventory.servicesById.jellyfin;
  egressVpn = hostInventory.egressVpns.airvpn;
  jellyfinHostConfig = outputs.nixosConfigurations.${jellyfinService.owner}.config;
  jellyfinEndpoint = jellyfinHostConfig.host.observability.prometheusEndpoints.jellyfin;
  wgEndpointPort = egressVpn.endpointPort;
  jellyfinClientName = "jellyfin-upload-policy";
  jellyfinClient = config.host.internalPki.clients.${jellyfinClientName};
in
{
  services.adaptive-upload-policy = {
    enable = true;
    fallbackRateMbit = tuning.wgConservativeUploadRateMbit;
    source.jellyfin = {
      exporterUrl = "https://${jellyfinHostConfig.networking.hostName}:${toString jellyfinEndpoint.port}${jellyfinEndpoint.path}";
      mtls = {
        enable = true;
        certificateFile =
          config.sops.secrets.${jellyfinClient.materializations.default.certificateSecretName}.path;
        keyFile = config.sops.secrets.${jellyfinClient.materializations.default.keySecretName}.path;
        dependencyUnits = [ "sops-install-secrets.service" ];
      };
    };
    outputs = {
      transmission.enable = true;
      qos = {
        enable = true;
        profile = "wan";
        limit = "wireguard-upload";
      };
    };
    group = "media";
  };

  host.internalPki.clients.${jellyfinClientName} = {
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
      nfs = {
        rateMbit = nfsRateMbit;
        match = {
          protocol = "tcp";
          destinationAddress = nfsServerAddress;
          destinationPort = nfsServerPort;
        };
      };
      wireguard-download = {
        direction = "ingress";
        rateMbit = 400;
        match = {
          protocol = "udp";
          sourcePort = wgEndpointPort;
        };
      };
      wireguard-upload = {
        rateMbit = tuning.wgConservativeUploadRateMbit;
        queue = "cake";
        match = {
          protocol = "udp";
          destinationPort = wgEndpointPort;
        };
      };
    };
  };

  host.observability.lanWan = {
    # nft postrouting overcounts the WireGuard transport on this host, so use
    # the shaped tc class as the authoritative WAN egress counter instead.
    wanTransmitTcClass = config.host.qos.classIds.wan.wireguard-upload;
    wanUdpSubclass = {
      name = egressVpn.namespace;
      port = wgEndpointPort;
    };
  };

}
