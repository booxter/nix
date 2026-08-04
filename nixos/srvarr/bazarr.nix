{
  config,
  hostInventory,
  lib,
  srvarrPkgs,
  utils,
  ...
}:
let
  accounts = import ./accounts.nix;
  group = "media";
  stateDir = "${config.host.srvarrPaths.stateDir}/bazarr";
  user = "bazarr";
  enforceBazarrAuthCommand = utils.escapeSystemdExecArgs [
    (lib.getExe srvarrPkgs.bazarr-auth-config)
    "--config"
    "${stateDir}/config/config.yaml"
    "--uid"
    (toString accounts.uids.bazarr)
    "--gid"
    (toString hostInventory.site.gids.media)
  ];
in
{
  services.bazarr = {
    enable = true;
    dataDir = stateDir;
    group = group;
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

  systemd.services.bazarr.serviceConfig.ExecStartPre = "+${enforceBazarrAuthCommand}";

  host.internalHttps.services.bazarr = {
    enable = true;
    upstream = "http://127.0.0.1:${toString config.services.bazarr.listenPort}";
  };
}
