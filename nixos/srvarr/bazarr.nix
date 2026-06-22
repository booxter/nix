{
  config,
  lib,
  ...
}:
let
  accounts = import ./accounts.nix;
  stateDir = "${config.host.srvarrPaths.stateDir}/bazarr";
  user = "bazarr";
in
{
  services.bazarr = {
    enable = true;
    dataDir = stateDir;
    group = "media";
    user = user;
  };

  systemd.tmpfiles.rules = [
    "d '${stateDir}' 0700 ${user} root - -"
  ];

  users.users.${user} = {
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
