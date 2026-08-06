{
  config,
  hostInventory,
  lib,
  ...
}:
let
  username = config.host.username;
  clientName = "sketchybar-alertmanager";
  client = config.host.internalPki.clients.${clientName};
  lanDomain = hostInventory.site.lan.domain;
  enable = config.host.isDesktop && !config.host.isWork;
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

  home-manager.users.${username}.programs.sketchybarAlertmanager = lib.mkIf enable {
    enable = true;
    alertmanagerUrl = "https://alertmanager.${lanDomain}/api/v2/alerts";
    grafanaUrl = "https://grafana.${lanDomain}/alerting/groups";
    clientCertificate =
      config.sops.secrets.${client.materializations.default.certificateSecretName}.path;
    clientKey = config.sops.secrets.${client.materializations.default.keySecretName}.path;
  };
}
