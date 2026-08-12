{
  lib,
  utils,
  ...
}:
let
  inherit (utils.systemdUtils.unitOptions) unitOption;
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
}
