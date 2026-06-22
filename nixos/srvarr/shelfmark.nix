{
  config,
  hostInventory,
  lib,
  ...
}:
let
  accounts = import ./accounts.nix;
  stateDir = "${config.host.srvarrPaths.stateDir}/shelfmark";
  mediaDir = config.host.srvarrPaths.mediaDir;
  user = "shelfmark";
  shelfmarkService = hostInventory.servicesById.shelfmark;
in
{
  services.shelfmark = {
    enable = true;
    environment = {
      CONFIG_DIR = stateDir;
      FLASK_HOST = "127.0.0.1";
    };
  };

  systemd.tmpfiles.rules = [
    "d '${stateDir}' 0700 ${user} root - -"
  ];

  systemd.services.shelfmark.serviceConfig = {
    Group = "media";
    ReadWritePaths = [
      stateDir
      mediaDir
    ];
    StateDirectory = lib.mkForce "";
    User = user;
  };

  users.users.${user} = {
    group = "media";
    home = "/var/empty";
    isSystemUser = true;
    uid = accounts.uids.shelfmark;
  };

  host.internalHttps.services.shelfmark = {
    enable = true;
    upstream = "http://127.0.0.1:${toString config.services.shelfmark.environment.FLASK_PORT}";
    serverAliases = [ shelfmarkService.publicHost ];
    mtls.enable = true;
  };
}
