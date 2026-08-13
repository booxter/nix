{
  config,
  lib,
  outputs,
  ...
}:
let
  model = import ./model.nix { inherit config lib outputs; };
  inherit (model) cfg;
  baseSettings = import ./settings.nix {
    hostWhitelist = [
      config.networking.hostName
      "sabnzbd.${config.host.network.lanDomain}"
      "sabnzbd"
      "sabnzbd.local"
    ];
    mediaDir = model.claim.mountPoint;
    port = cfg.port;
    vpnNamespaceAddress = model.vpnNamespace.namespaceAddress;
  };
in
{
  config = lib.mkIf (cfg.enable && model.ready && model.storageGroup == cfg.group) {
    services.sabnzbd = {
      enable = true;
      package = cfg.package;
      allowConfigWrite = false;
      configFile = null;
      group = cfg.group;
      secretFiles = [ config.sops.templates."sabnzbd-secret.ini".path ];
      settings = baseSettings // {
        categories = baseSettings.categories // model.routeCategories;
        inherit (model) servers;
      };
      user = cfg.user;
    };

    systemd.services.sabnzbd.serviceConfig.Restart = "on-failure";
  };
}
