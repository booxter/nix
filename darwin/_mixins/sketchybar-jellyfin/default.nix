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
  enable = config.host.observability.enable;
in
lib.mkIf enable {
  host.pki.clients.${clientName} = {
    category = "observability";
    materializations.default = {
      owner = username;
      group = "staff";
    };
  };

  home-manager.users.${username}.host.hm.sketchybar.jellyfin = {
    enable = true;
    metricsUrl = "https://${beastConfig.networking.hostName}:${toString endpoint.port}${endpoint.path}";
    dashboardUrl = "https://grafana.${config.host.network.lanDomain}/d/fana-media-pipe";
    clientCertificate = client.materializations.default.certificatePath;
    clientKey = client.materializations.default.keyPath;
  };
}
