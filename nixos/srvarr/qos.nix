{
  config,
  outputs,
  ...
}:
let
  beastHostConfig = outputs.nixosConfigurations.beast.config;
  beastJellyfinEndpoint = beastHostConfig.host.observability.prometheusEndpoints.jellyfin;
  wgEndpointPort = 1637;
  jellyfinClientName = "jellyfin-upload-policy";
  jellyfinClient = config.host.pki.clients.${jellyfinClientName};
in
{
  services.adaptive-upload-policy = {
    enable = true;
    fallbackRateMbit = 8;
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

  host.pki.clients.${jellyfinClientName} = {
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
        rateMbit = 400;
        match = {
          protocol = "udp";
          sourcePort = wgEndpointPort;
        };
      };
      wireguard-upload = {
        queue = "cake";
        match = {
          protocol = "udp";
          destinationPort = wgEndpointPort;
        };
      };
    };
  };

  host.observability.lanWan = {
    wanEgressOverride = {
      name = "wg";
      udpDestinationPort = wgEndpointPort;
      tcClass = config.host.qos.classIds.wan.wireguard-upload;
    };
  };

}
