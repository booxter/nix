{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.host.bazarr;
  serviceCfg = config.services.bazarr;
  authConfigPackage = pkgs.callPackage ./package {
    atomicFileWrites = pkgs.atomic-file-writes;
  };
  enforceAuthCommand = utils.escapeSystemdExecArgs [
    (lib.getExe authConfigPackage)
    "--config"
    "${cfg.stateDir}/config/config.yaml"
    "--uid"
    (toString config.users.users.${serviceCfg.user}.uid)
    "--gid"
    (toString config.users.groups.${serviceCfg.group}.gid)
  ];
in
{
  options.host.bazarr = {
    enable = lib.mkEnableOption "Bazarr subtitle manager";

    stateDir = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "/var/lib/bazarr";
    };

  };

  config = lib.mkIf cfg.enable {
    services.bazarr = {
      enable = true;
      dataDir = cfg.stateDir;
      group = "media";
    };

    host.storage.claims.media.attachments.bazarr = { };

    host.backups.sources.bazarr = {
      title = "Bazarr";
      paths = [ "${cfg.stateDir}/backup" ];
    };

    host.web.services.bazarr = {
      upstream = "http://127.0.0.1:${toString config.services.bazarr.listenPort}";
      health = {
        frontend = {
          path = "/oauth2/sign_in";
        };
        backend = {
          path = "/api/system/ping";
        };
      };
      dashboard = {
        section = "media-admin";
      };
      auth = {
        policy = "media-admin";
        sessionClearPaths = [ "/api/system/account" ];
      };
    };

    systemd.services.bazarr.serviceConfig = {
      ExecStartPre = "+${enforceAuthCommand}";
      UMask = lib.mkForce "0002";
    };
  };
}
