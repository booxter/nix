{
  config,
  lib,
  pkgs,
  sabnzbdModel,
  ...
}:
let
  model = sabnzbdModel;
  inherit (model) cfg;
  baseSettings = import ./settings.nix {
    hostWhitelist = [
      config.networking.hostName
      "sabnzbd.${config.host.network.lanDomain}"
      "sabnzbd"
      "sabnzbd.local"
    ];
    mediaDir = model.claim.mountPoint;
    inherit (model) port;
    vpnNamespaceAddress = model.vpnNamespace.namespaceAddress;
  };
in
{
  config = lib.mkIf (cfg != null && model.ready && model.storageGroup == "media") {
    services.sabnzbd = {
      enable = true;
      package = pkgs.sabnzbd;
      allowConfigWrite = false;
      configFile = null;
      group = "media";
      secretFiles = [ config.sops.templates."sabnzbd-secret.ini".path ];
      settings = baseSettings // {
        categories = baseSettings.categories // model.routeCategories;
        inherit (model) servers;
      };
      user = "sabnzbd";
    };

    systemd.services.sabnzbd.serviceConfig.Restart = "on-failure";
  };
}
