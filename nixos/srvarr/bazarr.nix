{
  config,
  hostInventory,
  lib,
  srvarrPkgs,
  utils,
  ...
}:
let
  bazarrAccount = hostInventory.serviceAccounts.bazarr;
  mediaGroup = hostInventory.storage.nfs.exports.media.sharedGroup;
  group = mediaGroup.name;
  stateDir = "${config.host.srvarrPaths.stateDir}/bazarr";
  user = "bazarr";
  enforceBazarrAuthCommand = utils.escapeSystemdExecArgs [
    (lib.getExe srvarrPkgs.bazarr-auth-config)
    "--config"
    "${stateDir}/config/config.yaml"
    "--uid"
    (toString bazarrAccount.uid)
    "--gid"
    (toString mediaGroup.gid)
  ];
in
{
  services.bazarr = {
    enable = true;
    dataDir = stateDir;
    inherit group;
    user = user;
  };

  systemd.tmpfiles.rules = [
    "d '${stateDir}' 0700 ${user} root - -"
  ];

  users.users.${user} = {
    extraGroups = lib.mkForce [ group ];
    home = lib.mkForce "/var/empty";
    isSystemUser = true;
    uid = bazarrAccount.uid;
  };

  systemd.services.bazarr.serviceConfig.ExecStartPre = "+${enforceBazarrAuthCommand}";

  host.internalService.services.bazarr = {
    enable = true;
    upstream = "http://127.0.0.1:${toString config.services.bazarr.listenPort}";
  };
}
