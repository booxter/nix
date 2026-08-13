{
  config,
  lib,
  srvarrPkgs,
  utils,
  ...
}:
let
  accounts = import ./accounts.nix { hostAccounts = config.host.accounts; };
  group = "media";
  stateDir = "/data/.state/nixarr/bazarr";
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

  host.storage.claims.media.attachments.bazarr.unit = "bazarr";

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
    home = lib.mkForce "/var/empty";
    isSystemUser = true;
    uid = accounts.uids.bazarr;
  };

  systemd.services.bazarr.serviceConfig = {
    ExecStartPre = "+${enforceBazarrAuthCommand}";
    UMask = lib.mkForce "0002";
  };

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
    dashboard = {
      enable = true;
      section = "media-admin";
    };
  };
}
