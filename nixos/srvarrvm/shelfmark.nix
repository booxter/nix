{
  config,
  hostInventory,
  lib,
  ...
}:
let
  accounts = import ./accounts.nix;
  cfg = config.host.srvarr.services.shelfmark;
  mediaDir = config.host.srvarr.mediaDir;
  shelfmarkService = hostInventory.servicesById.shelfmark;
in
{
  services.shelfmark = {
    enable = true;
    environment = {
      CONFIG_DIR = cfg.stateDir;
      FLASK_HOST = "127.0.0.1";
    };
  };

  systemd.tmpfiles.rules = [
    "d '${cfg.stateDir}' 0700 ${cfg.user} root - -"
  ];

  systemd.services.shelfmark.serviceConfig = {
    DynamicUser = lib.mkForce false;
    Group = cfg.group;
    ReadWritePaths = [
      cfg.stateDir
      mediaDir
    ];
    StateDirectory = lib.mkForce "";
    User = cfg.user;
  };

  users.users.${cfg.user} = {
    group = cfg.group;
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
