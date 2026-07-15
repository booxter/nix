{
  config,
  hostInventory,
  isDesktop,
  isWork,
  lib,
  username,
  ...
}:
let
  clientName = "sketchybar-alertmanager";
  secretAttrName = "internal-https-client-${clientName}";
  lanDomain = hostInventory.site.lan.domain;
  enable = isDesktop && !isWork;
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
