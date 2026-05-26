{
  config,
  lib,
  ...
}:
let
  accounts = import ./accounts.nix;
  cfg = config.host.srvarr.services.seerr;
in
{
  services.seerr = {
    enable = true;
    configDir = cfg.stateDir;
  };

  systemd.tmpfiles.rules = [
    "d '${cfg.stateDir}' 0700 ${cfg.user} root - -"
  ];

  systemd.services.seerr.serviceConfig = {
    DynamicUser = lib.mkForce false;
    Group = cfg.group;
    ReadWritePaths = [ cfg.stateDir ];
    StateDirectory = lib.mkForce "seerr";
    User = cfg.user;
  };

  users.groups.${cfg.group}.gid = accounts.gids.seerr;
  users.users.${cfg.user} = {
    group = cfg.group;
    home = "/var/empty";
    isSystemUser = true;
    uid = accounts.uids.seerr;
  };
}
