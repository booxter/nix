{
  config,
  hostInventory,
  lib,
  ...
}:
let
  accounts = import ./accounts.nix;
  stateDir = "${config.host.srvarrPaths.stateDir}/seerr";
  user = "seerr";
  group = "seerr";
  seerrService = hostInventory.servicesById.seerr;
in
{
  services.seerr = {
    enable = true;
    configDir = stateDir;
  };

  systemd.tmpfiles.rules = [
    "d '${stateDir}' 0700 ${user} root - -"
  ];

  systemd.services.seerr.serviceConfig = {
    Group = group;
    ReadWritePaths = [ stateDir ];
    StateDirectory = lib.mkForce "seerr";
    User = user;
  };

  users.groups.${group}.gid = accounts.gids.seerr;
  users.users.${user} = {
    group = group;
    home = "/var/empty";
    isSystemUser = true;
    uid = accounts.uids.seerr;
  };

  host.internalHttps.services.seerr = {
    enable = true;
    upstream = "http://127.0.0.1:${toString config.services.seerr.port}";
    serverAliases = [ seerrService.publicHost ];
    mtls.enable = true;
  };
}
