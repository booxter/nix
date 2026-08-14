{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.host.bazarr;
  enforceAuthCommand = utils.escapeSystemdExecArgs [
    (lib.getExe cfg.authConfigPackage)
    "--config"
    "${cfg.stateDir}/config/config.yaml"
    "--uid"
    (toString config.users.users.${cfg.user}.uid)
    "--gid"
    (toString config.users.groups.${cfg.group}.gid)
  ];
in
{
  options.host.bazarr = {
    enable = lib.mkEnableOption "Bazarr subtitle manager";

    stateDir = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "/var/lib/bazarr";
    };

    storage.claim = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "media";
    };

    authConfigPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package {
        atomicFileWrites = pkgs.atomic-file-writes;
      };
      internal = true;
    };

    user = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "bazarr";
      internal = true;
    };

    group = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "media";
      internal = true;
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.hasAttr cfg.storage.claim config.host.storage.claims;
        message = "host.bazarr.storage.claim must select a known storage claim";
      }
    ];

    services.bazarr = {
      enable = true;
      dataDir = cfg.stateDir;
      group = cfg.group;
      user = cfg.user;
    };

    host.storage.claims.${cfg.storage.claim}.attachments.bazarr.unit = "bazarr";

    host.backups.sources.bazarr = {
      title = "Bazarr";
      capture.type = "scheduled";
      capture.scheduled.outputPaths = [ "${cfg.stateDir}/backup" ];
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
      auth = {
        policy = "media-admin";
        sessionClearPaths = [ "/api/system/account" ];
      };
    };

    systemd.tmpfiles.rules = [
      "d '${cfg.stateDir}' 0700 ${cfg.user} root - -"
    ];

    users.users.${cfg.user} = {
      home = lib.mkForce "/var/empty";
      isSystemUser = true;
    };

    systemd.services.bazarr.serviceConfig = {
      ExecStartPre = "+${enforceAuthCommand}";
      UMask = lib.mkForce "0002";
    };
  };
}
