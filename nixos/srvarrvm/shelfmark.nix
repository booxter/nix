{
  config,
  lib,
  ...
}:
let
  accounts = import ./accounts.nix;
  cfg = config.host.srvarr.services.shelfmark;
  mediaDir = config.host.srvarr.mediaDir;
in
{
  services.shelfmark = {
    enable = true;
    environment = {
      CONFIG_DIR = cfg.stateDir;
      FLASK_HOST = "127.0.0.1";
      FLASK_PORT = cfg.port;
    };
  };

  systemd.tmpfiles.rules = [
    "d '${cfg.stateDir}' 0700 ${cfg.user} root - -"
    "d '${mediaDir}/library' 0775 root media - -"
    "d '${mediaDir}/library/books' 0775 root media - -"
    "d '${mediaDir}/library/audiobooks' 0775 root media - -"
  ];

  systemd.services.shelfmark.serviceConfig = {
    DynamicUser = lib.mkForce false;
    Group = cfg.group;
    ReadWritePaths = [
      cfg.stateDir
      mediaDir
    ];
    StateDirectory = lib.mkForce "";
    UMask = lib.mkForce "0002";
    User = cfg.user;
  };

  users.users.${cfg.user} = {
    group = cfg.group;
    home = "/var/empty";
    isSystemUser = true;
    uid = accounts.uids.shelfmark;
  };
}
