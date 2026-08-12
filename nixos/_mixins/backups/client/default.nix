{
  config,
  lib,
  utils,
  ...
}:
let
  hostName = config.networking.hostName;
  cfg = config.host.backups;
  sources = lib.filterAttrs (_: source: source.enable) cfg.sources;
  inherit (utils.systemdUtils.unitOptions) unitOption;
  positiveInt = lib.types.addCheck lib.types.int (value: value > 0);
  secretSuffix = name: lib.optionalString (name != "primary") "/${name}";

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

  sourceEntries = lib.mapAttrsToList (name: source: source // { inherit name; }) sources;
  sourcesByDestination = lib.groupBy (source: source.destination) sourceEntries;
  activeDestinations = lib.mapAttrs (name: resolved: cfg.destinations.${name} // resolved) (
    lib.filterAttrs (name: _: builtins.hasAttr name sourcesByDestination) cfg.internal.destinations
  );
  destinationFor =
    source: cfg.destinations.${source.destination} // cfg.internal.destinations.${source.destination};
  jobNameForDestination =
    name: destination:
    if name == "primary" then destination.server else "${destination.server}-${name}";
  jobNameFor = source: jobNameForDestination source.destination (destinationFor source);
  passwordSecretFor =
    name: destination:
    if destination.transport == "local" then
      "backup/restic/${hostName}/cloud/localPassword"
    else
      "backup/restic/local/password${secretSuffix name}";
  sshKeySecretFor = name: "backup/restic/local/ssh/privateKey${secretSuffix name}";
  directPathsFor =
    source:
    source.paths
    ++ lib.optionals (source.capture.type == "unit") source.capture.unit.outputPaths
    ++ lib.optionals (source.capture.type == "scheduled") source.capture.scheduled.outputPaths;
  pathCovers = root: path: path == root || lib.hasPrefix "${lib.removeSuffix "/" root}/" path;
  livePathsFor = selectedSources: lib.concatMap directPathsFor selectedSources;
  minimalPathsFor =
    selectedSources:
    let
      paths = lib.unique (livePathsFor selectedSources);
    in
    builtins.filter (path: !builtins.any (root: root != path && pathCovers root path) paths) paths;
  excludesFor = selectedSources: lib.unique (lib.concatMap (source: source.exclude) selectedSources);
  outputCoveredByJob =
    source: output:
    builtins.any (root: pathCovers root output) (
      livePathsFor sourcesByDestination.${source.destination}
    );
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

  config = lib.mkIf (sources != { }) {
    sops.secrets = lib.mkMerge (
      lib.mapAttrsToList (
        name: destination:
        lib.optionalAttrs (destination.transport == "sftp") {
          ${passwordSecretFor name destination} = { };
          ${sshKeySecretFor name} = {
            owner = destination.user;
            group = if destination.user == "root" then "root" else destination.user;
            mode = "0400";
          };
        }
      ) activeDestinations
    );

    host.backups.jobs = lib.mkMerge (
      lib.mapAttrsToList (
        name: destination:
        let
          jobName = jobNameForDestination name destination;
          destinationSources = sourcesByDestination.${name};
        in
        {
          ${jobName} = {
            title =
              if destination.transport == "local" then
                "${lib.strings.toSentenceCase hostName} Local Restic"
              else
                "Restic To ${lib.strings.toSentenceCase destination.server}";
            inherit (destination)
              check
              retention
              timerConfig
              user
              ;
            paths = minimalPathsFor destinationSources;
            exclude = excludesFor destinationSources;
            repository = {
              type = destination.transport;
              path = destination.repositoryPath;
              passwordFile = config.sops.secrets.${passwordSecretFor name destination}.path;
              dependencyUnits = [ "sops-install-secrets.service" ];
              sftp = lib.optionalAttrs (destination.transport == "sftp") {
                host = destination.server;
                user = destination.ingestUser;
                identityFile = config.sops.secrets.${sshKeySecretFor name}.path;
              };
            };
          };
        }
      ) activeDestinations
      ++ map (
        source:
        let
          jobName = jobNameFor source;
          unitName = source.capture.unit.service;
        in
        {
          ${jobName} = {
            preparations = lib.optionalAttrs (source.capture.type == "unit") {
              ${unitName} = {
                service = unitName;
                title = "${source.title} Capture";
                # Source output paths are aggregated into the job above. Keep
                # the preparation concerned only with service ordering.
                paths = [ ];
              };
            };
          };
        }
      ) sourceEntries
    );

    host.backups.artifacts = lib.mkMerge (
      map (
        source:
        let
          name = source.name;
          database = source.capture.database;
          common = {
            job = jobNameFor source;
            displayName = source.title;
            destinationDir = database.destinationDir;
            includeInJob = !outputCoveredByJob source database.destinationDir;
            inherit (database) requiresMountsFor;
          };
        in
        if source.capture.type == "sqlite" then
          {
            sqlite.${name} = common // {
              databasePath = database.path;
              inherit (database) conditionPathExists extraCopies;
            };
          }
        else if source.capture.type == "postgresql" then
          { postgresql.${database.name} = common; }
        else if source.capture.type == "mariadb" then
          {
            mariadb.${database.name} = common // {
              inherit (database) after requires;
            };
          }
        else
          { }
      ) sourceEntries
    );
  };
}
