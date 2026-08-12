{
  config,
  lib,
  outputs,
  ...
}:
let
  username = config.host.username;
  clientName = "sketchybar-jellyfin";
  client = config.host.internalPki.clients.${clientName};
  beastConfig = outputs.nixosConfigurations.beast.config;
  endpoint = beastConfig.host.observability.prometheusEndpoints.jellyfin;
  enable = config.host.userEnvironment.features.gui.enable && config.host.observability.enable;
in
{
  host.internalPki.clients.${clientName} = {
    inherit enable;
    category = "observability";
    materializations.default = {
      owner = username;
      group = "staff";
    };
  };

  home-manager.users.${username}.programs.sketchybarJellyfin = lib.mkIf enable {
    enable = true;
    metricsUrl = "https://${beastConfig.networking.hostName}:${toString endpoint.port}${endpoint.path}";
    dashboardUrl = "https://grafana.${config.host.network.lanDomain}/d/fana-media-pipe";
    clientCertificate =
      config.sops.secrets.${client.materializations.default.certificateSecretName}.path;
    clientKey = config.sops.secrets.${client.materializations.default.keySecretName}.path;
  };
}
