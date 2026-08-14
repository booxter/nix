{
  lib,
  utils,
  ...
}:
let
  inherit (utils.systemdUtils.unitOptions) unitOption;
  repositoryModule =
    { name, ... }:
    {
      options = {
        storageName = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "Durable repository directory name.";
        };
        publicKey = lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
          description = "SSH public key accepted by this repository's SFTP account.";
        };
        cloud = {
          enable = lib.mkEnableOption "cloud offload for this repository";
          backend = lib.mkOption {
            type =
              with lib.types;
              enum [
                "local"
                "b2"
                "s3"
              ];
            default = "local";
            description = "Restic backend used by the cloud repository.";
          };
          repository = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Destination Restic repository.";
          };
          storageProvider = lib.mkOption {
            type = with lib.types; nullOr (enum [ "b2" ]);
            default = null;
            description = "Object-storage provider used for provider-specific usage metrics.";
          };
          prefix = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Object prefix used by cloud usage metrics.";
          };
          sourcePasswordFile = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Password file for the local source repository.";
          };
          passwordFile = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Password file for the destination repository.";
          };
          pruneOpts = lib.mkOption {
            type = with lib.types; listOf str;
            default = [
              "--keep-daily=14"
              "--keep-weekly=8"
              "--keep-monthly=12"
            ];
          };
          timerConfig = lib.mkOption {
            type = with lib.types; attrsOf unitOption;
            default = {
              OnCalendar = "06:00";
              RandomizedDelaySec = "5m";
              Persistent = true;
            };
          };
          pruneTimerConfig = lib.mkOption {
            type = with lib.types; attrsOf unitOption;
            default = {
              OnCalendar = "Sun *-*-* 07:00:00";
              RandomizedDelaySec = "5m";
              Persistent = true;
            };
          };
        };
      };
    };
  serverModule = {
    options = {
      repositoryRoot = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Directory containing one Restic repository per client.";
      };

      offsite = lib.mkOption {
        type =
          with lib.types;
          nullOr (submodule {
            options = {
              backend = lib.mkOption {
                type = enum [
                  "b2"
                  "s3"
                ];
                default = "s3";
                description = "Restic backend used for offsite repositories.";
              };
              endpoint = lib.mkOption {
                type = nullOr nonEmptyStr;
                default = null;
                description = "S3-compatible API endpoint.";
              };
              bucket = lib.mkOption {
                type = nonEmptyStr;
                description = "Object-storage bucket containing the repositories.";
              };
              prefix = lib.mkOption {
                type = str;
                default = "";
                description = "Object prefix containing one repository per client.";
              };
              storageProvider = lib.mkOption {
                type = nullOr (enum [ "b2" ]);
                default = null;
                description = "Provider used for provider-specific usage metrics.";
              };
              qos = lib.mkOption {
                type = bool;
                default = false;
                description = "Whether to shape offsite backup uploads.";
              };
            };
          });
        default = null;
        description = "Server-managed offsite replication configuration.";
      };
    };
  };
in
{
  options.host.backups = {
    server = lib.mkOption {
      type = with lib.types; nullOr (submodule serverModule);
      default = null;
      description = "Restic SFTP repository and cloud-offload server configuration.";
    };
    internal.server = {
      localClient = lib.mkOption {
        type = with lib.types; nullOr str;
        default = null;
        internal = true;
      };
      repositories = lib.mkOption {
        type = with lib.types; attrsOf (submodule repositoryModule);
        default = { };
        internal = true;
      };
    };
  };
}
