{
  config,
  lib,
  utils,
  ...
}:
let
  hostName = config.networking.hostName;
  inherit (utils.systemdUtils.unitOptions) unitOption;
  positiveInt = lib.types.addCheck lib.types.int (value: value > 0);

  destinationPolicyOptions = {
    user = lib.mkOption {
      type = lib.types.str;
      default = "root";
      description = "User running the local Restic pipeline.";
    };
    timerConfig = lib.mkOption {
      type = with lib.types; nullOr (attrsOf unitOption);
      default = {
        OnCalendar = "04:45";
        RandomizedDelaySec = "5m";
        Persistent = true;
      };
      description = "Timer configuration for the complete local backup pipeline.";
    };
    retention = {
      daily = lib.mkOption {
        type = positiveInt;
        default = 7;
      };
      weekly = lib.mkOption {
        type = positiveInt;
        default = 8;
      };
      monthly = lib.mkOption {
        type = positiveInt;
        default = 6;
      };
    };
    check = {
      enable = lib.mkEnableOption "Restic repository checks after backup";
      options = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
      };
    };
  };

  destinationRequestModule =
    {
      name,
      ...
    }:
    {
      options = destinationPolicyOptions // {
        enable = lib.mkEnableOption "the ${name} backup destination" // {
          default = true;
        };
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
        destination = lib.mkOption {
          type = lib.types.str;
          default = "primary";
          description = "Named backup destination that receives this source.";
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
    destinations = lib.mkOption {
      type = with lib.types; attrsOf (submodule destinationRequestModule);
      default = { };
      description = "Named backup repositories consumed by this host.";
    };

    internal.destinations = lib.mkOption {
      type = with lib.types; attrsOf (submodule resolvedDestinationModule);
      default = { };
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
