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

  destinationModule =
    {
      config,
      name,
      ...
    }:
    {
      options = {
        provider = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          internal = true;
        };
        transport = lib.mkOption {
          type = lib.types.enum [
            "local"
            "sftp"
          ];
          default = "sftp";
          internal = true;
        };
        repositoryPath = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          internal = true;
        };
        ingestUser = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          internal = true;
        };
        publicKey = lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
          internal = true;
        };
        offsite = lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
          internal = true;
        };
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
        generated = {
          jobName = lib.mkOption {
            type = lib.types.str;
            default = if name == "primary" then config.provider else "${config.provider}-${name}";
            readOnly = true;
            internal = true;
          };
          providerHost = lib.mkOption {
            type = lib.types.str;
            default = config.provider;
            readOnly = true;
            internal = true;
          };
          repositoryPasswordSecret = lib.mkOption {
            type = lib.types.str;
            default =
              if config.transport == "local" then
                "backup/restic/${hostName}/cloud/localPassword"
              else
                "backup/restic/local/password${secretSuffix name}";
            readOnly = true;
            internal = true;
          };
          sshPrivateKeySecret = lib.mkOption {
            type = lib.types.str;
            default = "backup/restic/local/ssh/privateKey${secretSuffix name}";
            readOnly = true;
            internal = true;
          };
        };
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
          description = "Fleet backup link that receives this source.";
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

  referencedDestinationNames = lib.unique (
    map (source: source.destination) (builtins.attrValues sources)
  );
  activeDestinations = lib.filterAttrs (
    name: _: builtins.elem name referencedDestinationNames
  ) cfg.destinations;
  destinationFor = source: cfg.destinations.${source.destination};
  jobNameFor = source: (destinationFor source).generated.jobName;
  passwordSecretFor = destination: destination.generated.repositoryPasswordSecret;
  sshKeySecretFor = destination: destination.generated.sshPrivateKeySecret;
  directPathsFor =
    source:
    source.paths
    ++ lib.optionals (source.capture.type == "unit") source.capture.unit.outputPaths
    ++ lib.optionals (source.capture.type == "scheduled") source.capture.scheduled.outputPaths;
  databaseCapture =
    source:
    builtins.elem source.capture.type [
      "sqlite"
      "postgresql"
      "mariadb"
    ];
  livePathsForJob =
    jobName:
    lib.concatMap directPathsFor (
      builtins.attrValues (lib.filterAttrs (_: source: jobNameFor source == jobName) sources)
    );
  pathCovers = root: path: path == root || lib.hasPrefix "${lib.removeSuffix "/" root}/" path;
  pathsForJob = jobName: lib.unique (livePathsForJob jobName);
  minimalPathsForJob =
    jobName:
    let
      paths = pathsForJob jobName;
    in
    builtins.filter (path: !builtins.any (root: root != path && pathCovers root path) paths) paths;
  excludesForJob =
    jobName:
    lib.unique (
      lib.concatMap (source: source.exclude) (
        builtins.attrValues (lib.filterAttrs (_: source: jobNameFor source == jobName) sources)
      )
    );
  outputCoveredByJob =
    jobName: output: builtins.any (root: pathCovers root output) (livePathsForJob jobName);
in
{
  options.host.backups = {
    destinations = lib.mkOption {
      type = with lib.types; attrsOf (submodule destinationModule);
      default = { };
      description = "Backup destinations assigned to this host by fleet inventory.";
    };

    sources = lib.mkOption {
      type = with lib.types; attrsOf (submodule sourceModule);
      default = { };
      description = "Service-owned data sources and consistency strategies.";
    };
  };

  config = lib.mkIf (sources != { }) {
    assertions =
      lib.mapAttrsToList (name: source: {
        assertion = builtins.hasAttr source.destination cfg.destinations;
        message = "host.backups.sources.${name} references unknown destination '${source.destination}'";
      }) sources
      ++ lib.mapAttrsToList (name: source: {
        assertion =
          source.paths != [ ]
          || (source.capture.type == "unit" && source.capture.unit.outputPaths != [ ])
          || (source.capture.type == "scheduled" && source.capture.scheduled.outputPaths != [ ])
          || databaseCapture source;
        message = "host.backups.sources.${name} must contribute a path or database capture";
      }) sources
      ++ lib.mapAttrsToList (name: source: {
        assertion = source.capture.type != "unit" || source.capture.unit.service != null;
        message = "host.backups.sources.${name} unit capture requires a service";
      }) sources
      ++ lib.mapAttrsToList (name: source: {
        assertion =
          !databaseCapture source
          || (
            source.capture.database.destinationDir != null
            && (source.capture.type != "sqlite" || source.capture.database.path != null)
          );
        message = "host.backups.sources.${name} database capture is incomplete";
      }) sources;

    sops.secrets = lib.mkMerge (
      lib.mapAttrsToList (
        _: destination:
        lib.optionalAttrs (destination.transport == "sftp") {
          ${passwordSecretFor destination} = { };
          ${sshKeySecretFor destination} = {
            owner = destination.user;
            group = if destination.user == "root" then "root" else destination.user;
            mode = "0400";
          };
        }
      ) activeDestinations
    );

    host.backups.jobs = lib.mkMerge (
      lib.mapAttrsToList (
        _: destination:
        let
          jobName = destination.generated.jobName;
        in
        {
          ${jobName} = {
            title =
              if destination.transport == "local" then
                "${lib.strings.toSentenceCase hostName} Local Restic"
              else
                "Restic To ${lib.strings.toSentenceCase destination.provider}";
            inherit (destination)
              check
              retention
              timerConfig
              user
              ;
            paths = minimalPathsForJob jobName;
            exclude = excludesForJob jobName;
            repository = {
              type = destination.transport;
              path = destination.repositoryPath;
              passwordFile = config.sops.secrets.${passwordSecretFor destination}.path;
              dependencyUnits = [ "sops-install-secrets.service" ];
              sftp = lib.optionalAttrs (destination.transport == "sftp") {
                host = destination.generated.providerHost;
                user = destination.ingestUser;
                identityFile = config.sops.secrets.${sshKeySecretFor destination}.path;
              };
            };
          };
        }
      ) activeDestinations
      ++ lib.mapAttrsToList (
        _name: source:
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
      ) sources
    );

    host.backups.artifacts = lib.mkMerge (
      lib.mapAttrsToList (
        name: source:
        let
          database = source.capture.database;
          common = {
            job = jobNameFor source;
            displayName = source.title;
            destinationDir = database.destinationDir;
            includeInJob = !outputCoveredByJob (jobNameFor source) database.destinationDir;
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
      ) sources
    );
  };
}
