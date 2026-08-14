{
  config,
  lib,
  outputs,
  ...
}:
let
  username = config.host.username;
  clientName = "sketchybar-jellyfin";
  client = config.host.pki.clients.${clientName};
  beastConfig = outputs.nixosConfigurations.beast.config;
  endpoint = beastConfig.host.observability.prometheusEndpoints.jellyfin;
  enable = config.host.userEnvironment.roles.workstation.enable && config.host.observability.enable;
in
{
  host.pki.clients.${clientName} = {
    inherit enable;
    category = "observability";
    materializations.default = {
      owner = username;
      group = "staff";
    };
  };

  home-manager.users.${username}.host.hm.sketchybar.jellyfin = lib.mkIf enable {
    enable = true;
    metricsUrl = "https://${beastConfig.networking.hostName}:${toString endpoint.port}${endpoint.path}";
    dashboardUrl = "https://grafana.${config.host.network.lanDomain}/d/fana-media-pipe";
    clientCertificate = client.materializations.default.certificatePath;
    clientKey = client.materializations.default.keyPath;
  };
}
