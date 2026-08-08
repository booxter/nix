{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.seerr;
  hostCfg = config.host.seerr;
  hostname = config.networking.hostName;
  backupJob = config.host.backups.destinationJob;
  seerrAccount = hostInventory.serviceAccounts.seerr;
  seerrService = hostInventory.servicesById.seerr;
  instance = seerrService.instances.${hostname} or { };
  stateDir = cfg.configDir;
  user = "seerr";
  group = "seerr";
  tools = pkgs.callPackage ./packages/seerr-tools { };
in
{
  options = {
    host.seerr.enable = lib.mkOption {
      type = lib.types.bool;
      default = seerrService.owner == hostname;
      readOnly = true;
      internal = true;
      description = "Whether inventory assigns Seerr to this host.";
    };

    services.seerr.tools.package = lib.mkOption {
      type = lib.types.package;
      default = tools.package;
      description = "Package providing Seerr maintenance tools.";
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = builtins.hasAttr seerrService.owner hostInventory.nixosHosts;
          message = "Seerr owner '${seerrService.owner}' must be a managed NixOS host";
        }
        {
          assertion =
            !hostCfg.enable || hostInventory.nixosHosts.${seerrService.owner}.realm == config.host.realm;
          message = "Seerr owner '${seerrService.owner}' must belong to realm '${config.host.realm}'";
        }
      ];
    }

    (lib.mkIf hostCfg.enable {
      assertions = [
        {
          assertion = config.host.backups.client.enable;
          message = "The Seerr owner must be a declared backup client.";
        }
      ];

      services.seerr = {
        enable = true;
        configDir = instance.dataDir;
      };

      environment.systemPackages = [ cfg.tools.package ];

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

      host.internalService.services.seerr = {
        enable = true;
        upstream = "http://127.0.0.1:${toString cfg.port}";
        publicAliases = [ seerrService.publicHost ];
        mtls.enable = true;
      };

      host.backups.artifacts.sqlite.seerr = {
        job = backupJob;
        displayName = "Seerr";
        databasePath = "${stateDir}/db/db.sqlite3";
        destinationDir = "${stateDir}-backup/latest";
        extraCopies = [
          { source = "${stateDir}/settings.json"; }
        ];
      };
    })
  ];
}
