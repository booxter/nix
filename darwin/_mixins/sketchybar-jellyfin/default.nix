{
  config,
  hostInventory,
  lib,
  outputs,
  username,
  ...
}:
let
  clientName = "sketchybar-jellyfin";
  client = config.host.observability.client.mtlsClients.${clientName};
  clientCertificateSecret = "sketchybar-jellyfin-client-crt";
  clientKeySecret = "sketchybar-jellyfin-client-key";
  beastConfig = outputs.nixosConfigurations.beast.config;
  endpoint = beastConfig.host.observability.client.prometheusMtlsEndpoints.jellyfin;
  enable = config.host.isDesktop && !config.host.isWork;
in
{
  host.observability.client.mtlsClients.${clientName}.enable = enable;

  sops.secrets = lib.mkIf enable {
    ${clientCertificateSecret} = {
      key = "${client.secretPrefix}/client_crt_unencrypted";
      owner = username;
      group = "staff";
      mode = "0400";
    };
    ${clientKeySecret} = {
      key = "${client.secretPrefix}/client_key";
      owner = username;
      group = "staff";
      mode = "0400";
    };
  };

  home-manager.users.${username}.programs.sketchybarJellyfin = lib.mkIf enable {
    enable = true;
    metricsUrl = "https://${beastConfig.networking.hostName}:${toString endpoint.port}${endpoint.path}";
    dashboardUrl = "https://grafana.${hostInventory.site.lan.domain}/d/fana-media-pipe";
    clientCertificate = config.sops.secrets.${clientCertificateSecret}.path;
    clientKey = config.sops.secrets.${clientKeySecret}.path;
  };
}
