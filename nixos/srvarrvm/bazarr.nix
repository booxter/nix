{
  config,
  lib,
  ...
}:
let
  accounts = import ./accounts.nix;
  cfg = config.host.srvarr.services.bazarr;
in
{
  services.bazarr = {
    enable = true;
    dataDir = cfg.stateDir;
    group = cfg.group;
    user = cfg.user;
  };

  systemd.tmpfiles.rules = [
    "d '${cfg.stateDir}' 0700 ${cfg.user} root - -"
  ];

  users.users.${cfg.user} = {
    extraGroups = lib.mkForce [ "media" ];
    home = lib.mkForce "/var/empty";
    isSystemUser = true;
    uid = accounts.uids.bazarr;
  };

  host.internalHttps.services.bazarr = {
    enable = true;
    upstream = "http://127.0.0.1:${toString config.services.bazarr.listenPort}";
  };
}
