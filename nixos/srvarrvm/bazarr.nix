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
    listenPort = cfg.port;
    openFirewall = false;
    user = cfg.user;
  };

  systemd.tmpfiles.rules = [
    "d '${cfg.stateDir}' 0700 ${cfg.user} root - -"
  ];

  systemd.services.bazarr.serviceConfig.UMask = lib.mkForce "0002";

  users.users.${cfg.user} = {
    extraGroups = lib.mkForce [ "media" ];
    home = lib.mkForce "/var/empty";
    isSystemUser = true;
    uid = accounts.uids.bazarr;
  };
}
