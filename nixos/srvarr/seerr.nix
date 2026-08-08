{
  config,
  hostInventory,
  lib,
  srvarrPkgs,
  ...
}:
let
  seerrAccount = hostInventory.serviceAccounts.seerr;
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

  environment.systemPackages = [ srvarrPkgs.seerr-tools ];

  systemd.tmpfiles.rules = [
    "d '${stateDir}' 0700 ${user} root - -"
  ];

  systemd.services.seerr.serviceConfig = {
    Group = group;
    ReadWritePaths = [ stateDir ];
    StateDirectory = lib.mkForce "seerr";
    User = user;
  };

  users.groups.${group}.gid = seerrAccount.gid;
  users.users.${user} = {
    group = group;
    home = "/var/empty";
    isSystemUser = true;
    uid = seerrAccount.uid;
  };

  host.internalHttps.services.seerr = {
    enable = true;
    upstream = "http://127.0.0.1:${toString config.services.seerr.port}";
    publicAliases = [ seerrService.publicHost ];
    mtls.enable = true;
  };
}
