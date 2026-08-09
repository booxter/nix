{
  config,
  hostInventory,
  lib,
  srvarrPkgs,
  utils,
  ...
}:
let
  accounts = import ./accounts.nix { sharedAccounts = hostInventory.accounts; };
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
    (toString config.users.groups.media.gid)
  ];
in
{
  host.backups.sources.bazarr = {
    title = "Bazarr";
    capture.type = "scheduled";
    capture.scheduled.outputPaths = [ "${stateDir}/backup" ];
  };

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

  host.web.services.bazarr = {
    enable = true;
    upstream = "http://127.0.0.1:${toString config.services.bazarr.listenPort}";
    health = {
      frontend = {
        enable = true;
        path = "/oauth2/sign_in";
      };
      backend = {
        enable = true;
        path = "/api/system/ping";
      };
    };
    presentation.dashboard = {
      enable = true;
      category = "media-admin";
    };
  };
}
