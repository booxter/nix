{
  config,
  lib,
  ...
}:
let
  username = config.host.username;
  clientName = "sketchybar-alertmanager";
  client = config.host.internalPki.clients.${clientName};
  lanDomain = config.host.network.lanDomain;
  enable = config.host.userEnvironment.features.gui.enable && config.host.observability.enable;
in
{
  host.internalPki.clients.${clientName} = {
    inherit enable;
    category = "internal";
    materializations.default = {
      owner = username;
      group = "staff";
    };
  };

  home-manager.users.${username}.host.hm.sketchybar.alertmanager = lib.mkIf enable {
    enable = true;
    url = "https://alertmanager.${lanDomain}/api/v2/alerts";
    grafanaUrl = "https://grafana.${lanDomain}/alerting/groups";
    clientCertificate =
      config.sops.secrets.${client.materializations.default.certificateSecretName}.path;
    clientKey = config.sops.secrets.${client.materializations.default.keySecretName}.path;
  };
}
