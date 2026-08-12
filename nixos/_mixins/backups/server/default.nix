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
  cloudGroup = "restic-cloud";
  cloudDependencyUnits = [
    "network-online.target"
    "sops-install-secrets.service"
  ];
  cloudRequiredUnits = lib.optional (cfg.offsite.enable && cfg.offsite.qos.enable) "qos-wan.service";
  applicationKeyIdFile = config.sops.secrets."backup/restic/cloud/b2/applicationKeyId".path;
  applicationKeyFile = config.sops.secrets."backup/restic/cloud/b2/applicationKey".path;
  backupServerTools = pkgs.callPackage ./pkgs/backup-server-tools { };
  resticTools = pkgs.callPackage ./pkgs/restic-tools {
    atomicFileWrites = pkgs.atomic-file-writes;
  };
  enabledCloudClients = lib.filterAttrs (_: client: client.cloud.enable) cfg.repositories;
  credentialedCloudClients = lib.filterAttrs (
    _: client: client.cloud.backend != "local"
  ) enabledCloudClients;
  b2StorageClients = lib.filterAttrs (
    _: client: client.cloud.storageProvider == "b2"
  ) enabledCloudClients;
  usageEnabled = b2StorageClients != { };
  sshClients = lib.filterAttrs (_: client: client.publicKey != null) cfg.repositories;
  ingestUser = name: "restic-${name}";
  repositoryPath = name: "${cfg.repositoryRoot}/${cfg.repositories.${name}.storageName}";
  offloadUser = name: if name == cfg.localClient then cloudGroup else "restic-${name}-offload";
  offloadService = name: "restic-${name}-cloud-offload";
  pruneService = name: "restic-${name}-cloud-prune";
  aclService = name: "restic-${name}-repo-acl";
  cloudStateDir = name: "restic-cloud-${name}";
  aclConfig =
    name:
    (pkgs.formats.json { }).generate "${aclService name}.json" {
      repository = repositoryPath name;
      user = offloadUser name;
      setfaclExecutable = lib.getExe' pkgs.acl "setfacl";
    };
  cloudConfig =
    name:
    let
      client = cfg.repositories.${name};
    in
    (pkgs.formats.json { }).generate "restic-${name}-cloud.json" (
      {
        backend = client.cloud.backend;
        sourceRepository = repositoryPath name;
        sourcePasswordFile = client.cloud.sourcePasswordFile;
        destinationRepository = client.cloud.repository;
        destinationPasswordFile = client.cloud.passwordFile;
        packSizeMib = 16;
        pruneOptions = client.cloud.pruneOpts;
      }
      // lib.optionalAttrs (builtins.hasAttr name credentialedCloudClients) {
        inherit applicationKeyFile applicationKeyIdFile;
        backendConnections = 2;
      }
    );
  usageConfig = (pkgs.formats.json { }).generate "restic-cloud-usage.json" {
    buckets = [ cfg.offsite.bucketName ];
    b2ApplicationKeyIdFile = applicationKeyIdFile;
    b2ApplicationKeyFile = applicationKeyFile;
    repositories = lib.mapAttrsToList (name: client: {
      inherit name;
      backupJob = offloadService name;
      backupTitle = "${name} Cloud Offload";
      bucket = cfg.offsite.bucketName;
      inherit (client.cloud) prefix repository;
      passwordFile = client.cloud.passwordFile;
    }) b2StorageClients;
  };
  command = executable: arguments: utils.escapeSystemdExecArgs ([ executable ] ++ arguments);
  cloudService =
    name: description: executable:
    let
      aclDependency = lib.optional (builtins.hasAttr name sshClients) "${aclService name}.service";
      dependencies = cloudDependencyUnits ++ cloudRequiredUnits ++ aclDependency;
    in
    {
      inherit description;
      restartIfChanged = false;
      stopIfChanged = false;
      wants = cloudDependencyUnits ++ aclDependency;
      requires = cloudRequiredUnits;
      after = dependencies;
      unitConfig.RequiresMountsFor = cfg.repositoryRoot;
      serviceConfig = {
        Type = "oneshot";
        User = offloadUser name;
        Group = offloadUser name;
        StateDirectory = cloudStateDir name;
        Environment = "RESTIC_CACHE_DIR=/var/lib/${cloudStateDir name}/cache";
        ExecStart = command executable [
          "--config"
          (cloudConfig name)
        ];
      };
    };
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
      internal = true;
      description = "Client whose repository is written locally by the cloud service account.";
    };

    repositories = lib.mkOption {
      default = { };
      description = "Restic repositories accepted and optionally offloaded by this server.";
      internal = true;
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

                  backend = lib.mkOption {
                    type = enum [
                      "local"
                      "b2"
                      "s3"
                    ];
                    default = "local";
                    description = "Restic backend used by the cloud repository.";
                  };

                  repository = lib.mkOption {
                    type = str;
                    default = "";
                    description = "Destination Restic repository.";
                  };

                  storageProvider = lib.mkOption {
                    type = nullOr (enum [ "b2" ]);
                    default = null;
                    description = "Object-storage provider used for provider-specific usage metrics.";
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

                  pruneTimerConfig = lib.mkOption {
                    type = attrsOf unitOption;
                    default = {
                      OnCalendar = "Sun *-*-* 07:00:00";
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

    offsite = {
      enable = lib.mkEnableOption "server-managed offsite replication of accepted repositories";

      backend = lib.mkOption {
        type = lib.types.enum [
          "b2"
          "s3"
        ];
        default = "s3";
        description = "Restic backend used for offsite repositories.";
      };

      repositoryRoot = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Base Restic repository URL containing one repository per client.";
      };

      bucketName = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
        description = "Object-storage bucket used for provider usage metrics.";
      };

      storageProvider = lib.mkOption {
        type = with lib.types; nullOr (enum [ "b2" ]);
        default = null;
        description = "Object-storage provider used for provider-specific usage metrics.";
      };

      qos.enable = lib.mkEnableOption "traffic shaping for offsite backup uploads";
    };

  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.restic ];

    services.openssh.enable = true;

    systemd.tmpfiles.rules =
      lib.mapAttrsToList (
        name: _:
        let
          owner = if name == cfg.localClient then cloudGroup else ingestUser name;
        in
        "d ${repositoryPath name} 0750 ${owner} ${owner} - -"
      ) cfg.repositories
      ++ lib.optional (
        enabledCloudClients != { }
      ) "d /var/lib/prometheus-node-exporter-textfile 0755 root root - -";

    users.groups =
      lib.optionalAttrs (enabledCloudClients != { }) {
        ${cloudGroup} = { };
      }
      // lib.mapAttrs' (name: _: lib.nameValuePair (ingestUser name) { }) sshClients
      // lib.mapAttrs' (name: _: lib.nameValuePair (offloadUser name) { }) (
        lib.filterAttrs (name: _: name != cfg.localClient) enabledCloudClients
      );

    users.users =
      lib.optionalAttrs (enabledCloudClients != { }) {
        ${cloudGroup} = {
          isSystemUser = true;
          group = cloudGroup;
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
          extraGroups = [ cloudGroup ];
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
        lib.nameValuePair (offloadService name) (
          cloudService name "Offload ${name} Restic repository to the cloud" (
            lib.getExe' resticTools "restic-cloud-offload"
          )
        )
      ) enabledCloudClients
      // lib.mapAttrs' (
        name: _:
        lib.nameValuePair (pruneService name) (
          cloudService name "Prune ${name} cloud Restic repository" (
            lib.getExe' resticTools "restic-cloud-prune"
          )
        )
      ) enabledCloudClients
      // lib.optionalAttrs usageEnabled {
        restic-cloud-usage-export = {
          description = "Export Restic cloud and B2 usage metrics";
          wants = cloudDependencyUnits;
          after = cloudDependencyUnits ++ cloudRequiredUnits;
          requires = cloudRequiredUnits;
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
      // lib.mapAttrs' (
        name: client:
        lib.nameValuePair (pruneService name) {
          wantedBy = [ "timers.target" ];
          timerConfig = client.cloud.pruneTimerConfig;
        }
      ) enabledCloudClients
      // lib.optionalAttrs usageEnabled {
        restic-cloud-usage-export = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "*-*-* 00/4:00:00";
            RandomizedDelaySec = "10m";
            Persistent = true;
          };
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
