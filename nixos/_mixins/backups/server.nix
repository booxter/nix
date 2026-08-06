{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.host.backups.server;
  inherit (utils.systemdUtils.unitOptions) unitOption;
  backupServerTools = pkgs.callPackage ./server/pkgs/backup-server-tools { };
  resticTools = pkgs.callPackage ./server/pkgs/restic-tools {
    atomicFileWrites = pkgs.atomic-file-writes;
  };
  enabledCloudClients = lib.filterAttrs (_: client: client.cloud.enable) cfg.clients;
  b2Clients = lib.filterAttrs (
    _: client: lib.hasPrefix "b2:" client.cloud.repository
  ) enabledCloudClients;
  usageEnabled = b2Clients != { };
  sshClients = lib.filterAttrs (_: client: client.publicKey != null) cfg.clients;
  ingestUser = name: "restic-${name}";
  repositoryPath = name: "${cfg.repositoryRoot}/${cfg.clients.${name}.storageName}";
  offloadUser = name: if name == cfg.localClient then cfg.cloud.group else "restic-${name}-offload";
  offloadService = name: "restic-${name}-cloud-offload";
  aclService = name: "restic-${name}-repo-acl";
  cloudStateDir = name: "restic-cloud-${name}";
  offloadUsers = map offloadUser (builtins.attrNames enabledCloudClients);
  aclConfig =
    name:
    (pkgs.formats.json { }).generate "${aclService name}.json" {
      repository = repositoryPath name;
      user = offloadUser name;
      setfaclExecutable = lib.getExe' pkgs.acl "setfacl";
    };
  offloadConfig =
    name:
    let
      client = cfg.clients.${name};
    in
    (pkgs.formats.json { }).generate "${offloadService name}.json" (
      {
        sourceRepository = repositoryPath name;
        sourcePasswordFile = client.cloud.sourcePasswordFile;
        destinationRepository = client.cloud.repository;
        destinationPasswordFile = client.cloud.passwordFile;
        packSizeMib = cfg.cloud.packSizeMib;
        pruneOptions = client.cloud.pruneOpts;
      }
      // lib.optionalAttrs (builtins.hasAttr name b2Clients) {
        b2ApplicationKeyIdFile = cfg.cloud.applicationKeyIdFile;
        b2ApplicationKeyFile = cfg.cloud.applicationKeyFile;
        b2Connections = cfg.cloud.b2Connections;
      }
    );
  usageConfig = (pkgs.formats.json { }).generate "restic-cloud-usage.json" {
    buckets = [ cfg.cloud.bucketName ];
    b2ApplicationKeyIdFile = cfg.cloud.applicationKeyIdFile;
    b2ApplicationKeyFile = cfg.cloud.applicationKeyFile;
    repositories = lib.mapAttrsToList (name: client: {
      inherit name;
      backupJob = offloadService name;
      backupTitle = "${name} Cloud Offload";
      bucket = cfg.cloud.bucketName;
      inherit (client.cloud) prefix repository;
      passwordFile = client.cloud.passwordFile;
    }) b2Clients;
  };
  command = executable: arguments: utils.escapeSystemdExecArgs ([ executable ] ++ arguments);
in
{
  options.host.backups.server = {
    enable = lib.mkEnableOption "a Restic SFTP repository and cloud-offload server";

    repositoryRoot = lib.mkOption {
      type = lib.types.str;
      description = "Directory containing one Restic repository per client.";
    };

    localClient = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      description = "Client whose repository is written locally by the cloud service account.";
    };

    clients = lib.mkOption {
      default = { };
      description = "Restic repositories accepted and optionally offloaded by this server.";
      type =
        with lib.types;
        attrsOf (
          submodule (
            { name, ... }:
            {
              options = {
                storageName = lib.mkOption {
                  type = str;
                  default = name;
                  description = "Durable repository directory name.";
                };

                publicKey = lib.mkOption {
                  type = nullOr str;
                  default = null;
                  description = "SSH public key accepted by this repository's SFTP account.";
                };

                cloud = {
                  enable = lib.mkEnableOption "cloud offload for this repository";

                  repository = lib.mkOption {
                    type = str;
                    default = "";
                    description = "Destination Restic repository.";
                  };

                  prefix = lib.mkOption {
                    type = str;
                    default = "";
                    description = "Object prefix used by cloud usage metrics.";
                  };

                  sourcePasswordFile = lib.mkOption {
                    type = str;
                    default = "";
                    description = "Password file for the local source repository.";
                  };

                  passwordFile = lib.mkOption {
                    type = str;
                    default = "";
                    description = "Password file for the destination repository.";
                  };

                  pruneOpts = lib.mkOption {
                    type = listOf str;
                    default = [
                      "--keep-daily=14"
                      "--keep-weekly=8"
                      "--keep-monthly=12"
                    ];
                  };

                  timerConfig = lib.mkOption {
                    type = attrsOf unitOption;
                    default = {
                      OnCalendar = "06:00";
                      RandomizedDelaySec = "5m";
                      Persistent = true;
                    };
                  };
                };
              };
            }
          )
        );
    };

    cloud = {
      group = lib.mkOption {
        type = lib.types.str;
        default = "restic-cloud";
      };

      bucketName = lib.mkOption {
        type = with lib.types; nullOr str;
        default = null;
      };

      applicationKeyIdFile = lib.mkOption {
        type = with lib.types; nullOr str;
        default = null;
      };

      applicationKeyFile = lib.mkOption {
        type = with lib.types; nullOr str;
        default = null;
      };

      b2Connections = lib.mkOption {
        type = lib.types.ints.positive;
        default = 1;
      };

      packSizeMib = lib.mkOption {
        type = lib.types.ints.positive;
        default = 4;
      };

      dependencyUnits = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
      };

      requiredUnits = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
      };

      usageTimerConfig = lib.mkOption {
        type = with lib.types; attrsOf unitOption;
        default = {
          OnCalendar = "*-*-* 00/4:00:00";
          RandomizedDelaySec = "10m";
          Persistent = true;
        };
      };
    };

    generated.offloadUsers = lib.mkOption {
      type = with lib.types; listOf str;
      readOnly = true;
      internal = true;
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.clients != { };
        message = "host.backups.server.clients must not be empty";
      }
      {
        assertion = cfg.localClient == null || builtins.hasAttr cfg.localClient cfg.clients;
        message = "host.backups.server.localClient must reference a configured client";
      }
      {
        assertion =
          cfg.localClient == null
          || !builtins.hasAttr cfg.localClient cfg.clients
          || cfg.clients.${cfg.localClient}.cloud.enable;
        message = "host.backups.server.localClient must have cloud offload enabled";
      }
    ]
    ++ lib.mapAttrsToList (name: client: {
      assertion =
        !client.cloud.enable
        || (
          client.cloud.repository != ""
          && client.cloud.sourcePasswordFile != ""
          && client.cloud.passwordFile != ""
          && (
            !lib.hasPrefix "b2:" client.cloud.repository
            || (
              client.cloud.prefix != ""
              && cfg.cloud.bucketName != null
              && cfg.cloud.applicationKeyIdFile != null
              && cfg.cloud.applicationKeyFile != null
            )
          )
        );
      message = "host.backups.server.clients.${name}.cloud requires complete repository credentials";
    }) cfg.clients;

    host.backups.server.generated.offloadUsers = offloadUsers;

    systemd.tmpfiles.rules =
      lib.mapAttrsToList (
        name: _:
        let
          owner = if name == cfg.localClient then cfg.cloud.group else ingestUser name;
        in
        "d ${repositoryPath name} 0750 ${owner} ${owner} - -"
      ) cfg.clients
      ++ lib.optional (
        enabledCloudClients != { }
      ) "d /var/lib/prometheus-node-exporter-textfile 0755 root root - -";

    users.groups =
      lib.optionalAttrs (enabledCloudClients != { }) {
        ${cfg.cloud.group} = { };
      }
      // lib.mapAttrs' (name: _: lib.nameValuePair (ingestUser name) { }) sshClients
      // lib.mapAttrs' (name: _: lib.nameValuePair (offloadUser name) { }) (
        lib.filterAttrs (name: _: name != cfg.localClient) enabledCloudClients
      );

    users.users =
      lib.optionalAttrs (enabledCloudClients != { }) {
        ${cfg.cloud.group} = {
          isSystemUser = true;
          group = cfg.cloud.group;
          createHome = false;
          home = cfg.repositoryRoot;
          shell = pkgs.bash;
        };
      }
      // lib.mapAttrs' (
        name: client:
        lib.nameValuePair (ingestUser name) {
          isSystemUser = true;
          group = ingestUser name;
          createHome = false;
          home = cfg.repositoryRoot;
          shell = pkgs.bash;
          openssh.authorizedKeys.keys = [ client.publicKey ];
        }
      ) sshClients
      // lib.mapAttrs' (
        name: _:
        lib.nameValuePair (offloadUser name) {
          isSystemUser = true;
          group = offloadUser name;
          createHome = false;
          home = cfg.repositoryRoot;
          shell = pkgs.bash;
          extraGroups = [ cfg.cloud.group ];
        }
      ) (lib.filterAttrs (name: _: name != cfg.localClient) enabledCloudClients);

    services.openssh.extraConfig = lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: _: ''
        Match User ${ingestUser name}
          ForceCommand internal-sftp
          PasswordAuthentication no
          PermitTTY no
          X11Forwarding no
          AllowTcpForwarding no
      '') sshClients
    );

    systemd.services =
      lib.mapAttrs' (
        name: _:
        lib.nameValuePair (aclService name) {
          description = "Grant cloud offload access to the ${name} Restic repository";
          wantedBy = [ "multi-user.target" ];
          after = [ "local-fs.target" ];
          unitConfig.RequiresMountsFor = cfg.repositoryRoot;
          serviceConfig = {
            Type = "oneshot";
            ExecStart = command (lib.getExe' backupServerTools "restic-repo-acl") [
              "--config"
              (aclConfig name)
            ];
          };
        }
      ) (lib.filterAttrs (name: _: builtins.hasAttr name sshClients) enabledCloudClients)
      // lib.mapAttrs' (
        name: _:
        let
          aclDependency = lib.optional (builtins.hasAttr name sshClients) "${aclService name}.service";
          dependencies = cfg.cloud.dependencyUnits ++ cfg.cloud.requiredUnits ++ aclDependency;
        in
        lib.nameValuePair (offloadService name) {
          description = "Offload ${name} Restic repository to the cloud";
          restartIfChanged = false;
          stopIfChanged = false;
          wants = cfg.cloud.dependencyUnits ++ aclDependency;
          requires = cfg.cloud.requiredUnits;
          after = dependencies;
          unitConfig.RequiresMountsFor = cfg.repositoryRoot;
          serviceConfig = {
            Type = "oneshot";
            User = offloadUser name;
            Group = offloadUser name;
            StateDirectory = cloudStateDir name;
            Environment = "RESTIC_CACHE_DIR=/var/lib/${cloudStateDir name}/cache";
            ExecStart = command (lib.getExe' resticTools "restic-cloud-offload") [
              "--config"
              (offloadConfig name)
            ];
          };
        }
      ) enabledCloudClients
      // lib.optionalAttrs usageEnabled {
        restic-cloud-usage-export = {
          description = "Export Restic cloud and B2 usage metrics";
          wants = cfg.cloud.dependencyUnits;
          after = cfg.cloud.dependencyUnits ++ cfg.cloud.requiredUnits;
          requires = cfg.cloud.requiredUnits;
          serviceConfig = {
            Type = "oneshot";
            StateDirectory = "restic-cloud-usage-metrics";
            TimeoutStartSec = "2h";
            ExecStart = command (lib.getExe' resticTools "restic-cloud-usage") [
              "--config"
              usageConfig
              "--state-file"
              "/var/lib/restic-cloud-usage-metrics/state.json"
              "--metrics-file"
              "/var/lib/prometheus-node-exporter-textfile/restic-cloud-usage.prom"
              "--restic-cache-dir"
              "/var/lib/restic-cloud-usage-metrics/restic-cache"
            ];
          };
        };
      };

    systemd.timers =
      lib.mapAttrs' (
        name: client:
        lib.nameValuePair (offloadService name) {
          wantedBy = [ "timers.target" ];
          timerConfig = client.cloud.timerConfig;
        }
      ) enabledCloudClients
      // lib.optionalAttrs usageEnabled {
        restic-cloud-usage-export = {
          wantedBy = [ "timers.target" ];
          timerConfig = cfg.cloud.usageTimerConfig;
        };
      };

    host.observability.backupMetrics.jobs = lib.mapAttrs' (
      name: _:
      lib.nameValuePair (offloadService name) {
        service = offloadService name;
        title = "${name} Cloud Offload";
        phase = "cloud";
      }
    ) enabledCloudClients;
  };
}
