{
  config,
  hostInventory,
  lib,
  ...
}:
let
  cfg = config.services.prowlarr;
  hostCfg = config.host.prowlarr;
  hostname = config.networking.hostName;
  backupJob = config.host.backups.destinationJob;
  service = hostInventory.servicesById.prowlarr;
  instance = service.instances.${hostname} or { };
  account = hostInventory.serviceAccounts.prowlarr;
  stateDir = cfg.dataDir;
  user = "prowlarr";
  group = "prowlarr";
in
{
  options.host.prowlarr.enable = lib.mkOption {
    type = lib.types.bool;
    default = hostInventory.serviceRunsOn hostname service;
    readOnly = true;
    internal = true;
    description = "Whether inventory assigns Prowlarr to this host.";
  };

  config = lib.mkMerge [
    (lib.mkIf hostCfg.enable {
      assertions = [
        {
          assertion = instance ? dataDir;
          message = "The Prowlarr inventory instance must define dataDir.";
        }
        {
          assertion = config.host.backups.client.enable;
          message = "The Prowlarr host must be a declared backup client.";
        }
      ];

      services.prowlarr = {
        enable = true;
        dataDir = instance.dataDir;
        settings = {
          auth = {
            method = "External";
            required = "Enabled";
          };
          log.analyticsEnabled = false;
          server.bindaddress = "127.0.0.1";
          update = {
            automatically = false;
            mechanism = "external";
          };
        };
      };

      systemd.tmpfiles.rules = [
        "d '${stateDir}' 0700 ${user} root - -"
      ];

      systemd.services.prowlarr = {
        unitConfig = {
          Wants = [ "network-online.target" ];
          After = [ "network-online.target" ];
        };
        serviceConfig = {
          # Override DynamicUser from the upstream module because this service
          # shares its API group with local clients.
          User = user;
          Group = group;
          ExecStart = lib.mkForce "${cfg.package}/bin/Prowlarr -nobrowser -data=${stateDir}";
          ReadWritePaths = [ stateDir ];
        };
      };

      users = {
        groups = {
          ${group}.gid = account.gid;
          prowlarr-api = { };
        };
        users.${user} = {
          isSystemUser = true;
          inherit group;
          home = "/var/empty";
          uid = account.uid;
          extraGroups = [ "prowlarr-api" ];
        };
      };

      host.internalService.services.prowlarr = {
        enable = true;
        upstream = "http://127.0.0.1:${toString cfg.settings.server.port}";
      };

      host.backups.jobs.${backupJob} = {
        paths = [ stateDir ];
        exclude = [
          "${stateDir}/logs"
          "${stateDir}/logs/**"
          "${stateDir}/cache"
          "${stateDir}/cache/**"
        ];
      };
    })
  ];
}
