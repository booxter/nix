{
  config,
  hostInventory,
  outputs,
  ...
}:
let
  tuning = config.host.srvarrTuning;
  beastNfsAddress = hostInventory.dhcpReservationsByHostname.beast.ip;
  beastHostConfig = outputs.nixosConfigurations.beast.config;
  beastJellyfinEndpoint = beastHostConfig.host.observability.prometheusEndpoints.jellyfin;
  beastNfsPort = hostInventory.site.ports.nfs;
  beastNfsRateMbit = 1500;
  wgEndpointPort = 1637;
  jellyfinClientName = "jellyfin-upload-policy";
  jellyfinClient = config.host.internalPki.clients.${jellyfinClientName};
in
{
  services.adaptive-upload-policy = {
    enable = true;
    fallbackRateMbit = tuning.wgConservativeUploadRateMbit;
    source.jellyfin = {
      exporterUrl = "https://${beastHostConfig.networking.hostName}:${toString beastJellyfinEndpoint.port}${beastJellyfinEndpoint.path}";
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
    device = "ens18";
    limits = {
      nfs = {
        rateMbit = beastNfsRateMbit;
        match = {
          protocol = "tcp";
          destinationAddress = beastNfsAddress;
          destinationPort = beastNfsPort;
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
    interface = "ens18";
    # nft postrouting overcounts the WireGuard transport on this host, so use
    # the shaped tc class as the authoritative WAN egress counter instead.
    wanTransmitTcClass = config.host.qos.classIds.wan.wireguard-upload;
    wanUdpSubclass = {
      name = "wg";
      port = wgEndpointPort;
    };
  };

}
