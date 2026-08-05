{
  config,
  hostInventory,
  lib,
  ...
}:
let
  username = config.host.username;
  clientName = "sketchybar-alertmanager";
  secretAttrName = "internal-https-client-${clientName}";
  lanDomain = hostInventory.site.lan.domain;
  enable = config.host.isDesktop && !config.host.isWork;
in
{
  host.internalHttps.mtlsClients.${clientName} = {
    inherit enable;
    owner = username;
    group = "staff";
  };

  home-manager.users.${username}.programs.sketchybarAlertmanager = lib.mkIf enable {
    enable = true;
    alertmanagerUrl = "https://alertmanager.${lanDomain}/api/v2/alerts";
    grafanaUrl = "https://grafana.${lanDomain}/alerting/groups";
    clientCertificate = config.sops.secrets."${secretAttrName}-crt".path;
    clientKey = config.sops.secrets."${secretAttrName}-key".path;
  };
}
