{
  config,
  lib,
  ...
}:
let
  hostName = config.networking.hostName;

  destinationRequestModule = {
    options = {
      server = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Host providing the backup repository.";
      };
      storageName = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = hostName;
        description = "Durable repository name on the backup server.";
      };
      publicKey = lib.mkOption {
        type = with lib.types; nullOr str;
        default = null;
        description = "SSH public key accepted by the backup server for this client.";
      };
    };
  };

  resolvedDestinationModule = {
    options = {
      transport = lib.mkOption {
        type = lib.types.enum [
          "local"
          "sftp"
        ];
      };
      repositoryPath = lib.mkOption { type = lib.types.str; };
      ingestUser = lib.mkOption { type = lib.types.str; };
      user = lib.mkOption { type = lib.types.str; };
    };
  };

  extraCopyModule = {
    options = {
      source = lib.mkOption { type = lib.types.str; };
      mode = lib.mkOption {
        type = lib.types.strMatching "^0[0-7]{3}$";
        default = "0640";
      };
      optional = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
    };
  };

  sourceModule =
    { name, ... }:
    {
      options = {
        enable = lib.mkEnableOption "the ${name} backup source" // {
          default = true;
        };
        title = lib.mkOption {
          type = lib.types.str;
          default = lib.strings.toSentenceCase name;
        };
        paths = lib.mkOption {
          type = with lib.types; listOf str;
          default = [ ];
          description = "Live paths included directly in Restic.";
        };
        exclude = lib.mkOption {
          type = with lib.types; listOf str;
          default = [ ];
          description = "Restic exclusions scoped to this source's paths.";
        };
        capture = {
          type = lib.mkOption {
            type = lib.types.enum [
              "live"
              "unit"
              "scheduled"
              "sqlite"
              "postgresql"
              "mariadb"
            ];
            default = "live";
            description = "Consistency strategy used before Restic reads this source.";
          };
          unit = {
            service = lib.mkOption {
              type = with lib.types; nullOr str;
              default = null;
              description = "On-demand systemd service run before Restic.";
            };
            outputPaths = lib.mkOption {
              type = with lib.types; listOf str;
              default = [ ];
              description = "Paths produced by the on-demand service.";
            };
          };
          scheduled.outputPaths = lib.mkOption {
            type = with lib.types; listOf str;
            default = [ ];
            description = "Paths maintained by an application-managed backup schedule.";
          };
          database = {
            name = lib.mkOption {
              type = lib.types.str;
              default = name;
            };
            path = lib.mkOption {
              type = with lib.types; nullOr str;
              default = null;
              description = "SQLite database path.";
            };
            destinationDir = lib.mkOption {
              type = with lib.types; nullOr str;
              default = null;
              description = "Directory where the consistent database artifact is staged.";
            };
            extraCopies = lib.mkOption {
              type = with lib.types; listOf (submodule extraCopyModule);
              default = [ ];
            };
            conditionPathExists = lib.mkOption {
              type = with lib.types; nullOr str;
              default = null;
            };
            requiresMountsFor = lib.mkOption {
              type = with lib.types; listOf str;
              default = [ ];
            };
            after = lib.mkOption {
              type = with lib.types; listOf str;
              default = [ ];
            };
            requires = lib.mkOption {
              type = with lib.types; listOf str;
              default = [ ];
            };
          };
        };
      };
    };
in
{
  options.host.backups = {
    destination = lib.mkOption {
      type = with lib.types; nullOr (submodule destinationRequestModule);
      default = null;
      description = "Backup repository consumed by this host.";
    };

    internal.destination = lib.mkOption {
      type = with lib.types; nullOr (submodule resolvedDestinationModule);
      default = null;
      internal = true;
      description = "Fleet-resolved runtime destination data.";
    };

    sources = lib.mkOption {
      type = with lib.types; attrsOf (submodule sourceModule);
      default = { };
      description = "Service-owned data sources and consistency strategies.";
    };
  };
}
