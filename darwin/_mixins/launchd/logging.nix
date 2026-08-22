{
  config,
  launchdModel,
  lib,
  pkgs,
  ...
}:
let
  logDirectory = "/var/log/nix-darwin";
  privateLogDirectory = "/var/log/nix-darwin-private";
  userLogDirectory = "/Users/${config.host.username}/Library/Logs/nix-darwin";
  privateUserLogDirectory = "/Users/${config.host.username}/Library/Logs/nix-darwin-private";
  stateDirectory = "/var/lib/nix-darwin-logrotate";
  rotationJobName = "launchd-logrotate";
  enabledSystemJobsByDomain = lib.mapAttrs (
    _: lib.filterAttrs (_: job: job.enabled)
  ) launchdModel.systemJobsByDomain;
  managedSystemJobsByDomain = lib.mapAttrs (
    _: lib.filterAttrs (_: job: job.managed)
  ) launchdModel.systemJobsByDomain;
  homeManagerUserAgents = lib.filterAttrs (_: job: job.enabled) launchdModel.homeManagerJobs;
  managedHomeManagerUserAgents = lib.filterAttrs (_: job: job.managed) launchdModel.homeManagerJobs;
  pathsFor =
    jobs:
    builtins.sort builtins.lessThan (
      lib.unique (
        lib.concatMap (
          job:
          let
            serviceConfig = job.serviceConfig;
          in
          builtins.filter (path: path != null) [
            serviceConfig.StandardOutPath
            serviceConfig.StandardErrorPath
          ]
        ) (builtins.attrValues jobs)
      )
    );
  systemLogPaths = lib.unique (
    pathsFor enabledSystemJobsByDomain.daemons ++ pathsFor enabledSystemJobsByDomain.agents
  );
  userLogPaths = pathsFor homeManagerUserAgents;
  quotePath = path: ''"${lib.replaceStrings [ "\\" "\"" ] [ "\\\\" "\\\"" ] path}"'';
  rotationBlock =
    {
      paths,
      runAs ? null,
    }:
    lib.optionalString (paths != [ ]) ''
      ${lib.concatMapStringsSep " " quotePath paths} {
        daily
        maxsize 10M
        rotate 7
        compress
        copytruncate
        missingok
        notifempty
        ${lib.optionalString (runAs != null) "su ${runAs.user} ${runAs.group}"}
      }
    '';
  rotationConfig = pkgs.writeText "nix-darwin-launchd-logrotate.conf" (
    rotationBlock {
      paths = systemLogPaths;
    }
    + rotationBlock {
      paths = userLogPaths;
      runAs = {
        user = config.host.username;
        group = "staff";
      };
    }
  );
in
{
  options.host.launchd.logging.locations = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          directory = lib.mkOption {
            type = lib.types.nonEmptyStr;
            description = "Directory containing launchd log files.";
          };
          collect = lib.mkOption {
            type = lib.types.bool;
            description = "Whether Grafana Alloy should collect log files from this directory.";
          };
          scope = lib.mkOption {
            type = lib.types.enum [
              "system"
              "user"
            ];
            description = "Launchd service scope allowed to use this directory.";
          };
        };
      }
    );
    default = { };
    internal = true;
    description = "Registered directories for launchd service logs.";
  };

  config = {
    host.launchd.logging.locations = {
      system = {
        directory = logDirectory;
        collect = true;
        scope = "system";
      };
      system-private = {
        directory = privateLogDirectory;
        collect = false;
        scope = "system";
      };
      user = {
        directory = userLogDirectory;
        collect = true;
        scope = "user";
      };
      user-private = {
        directory = privateUserLogDirectory;
        collect = false;
        scope = "user";
      };
    };

    assertions = import ./logging/assertions.nix {
      inherit
        managedSystemJobsByDomain
        lib
        managedHomeManagerUserAgents
        ;
      homeManagerUsername = config.host.username;
      logLocations = config.host.launchd.logging.locations;
    };

    system.activationScripts.launchd.text = lib.mkBefore ''
      install -d -m 0755 -o root -g wheel ${logDirectory}
      install -d -m 0700 -o root -g wheel ${privateLogDirectory}
      install -d -m 0755 -o ${lib.escapeShellArg config.host.username} -g staff ${lib.escapeShellArg userLogDirectory}
      install -d -m 0700 -o ${lib.escapeShellArg config.host.username} -g staff ${lib.escapeShellArg privateUserLogDirectory}
      install -d -m 0700 -o root -g wheel ${stateDirectory}

      if [[ ! -e ${privateLogDirectory}/sops-install-secrets.log ]]; then
        install -m 0600 -o root -g wheel /dev/null ${privateLogDirectory}/sops-install-secrets.log
      fi
      chown root:wheel ${privateLogDirectory}/sops-install-secrets.log
      chmod 0600 ${privateLogDirectory}/sops-install-secrets.log
    '';

    launchd.daemons = {
      activate-system.serviceConfig = {
        StandardOutPath = lib.mkOverride 90 "${logDirectory}/activate-system.log";
        StandardErrorPath = lib.mkOverride 90 "${logDirectory}/activate-system.log";
      };

      nix-daemon.serviceConfig = {
        StandardOutPath = lib.mkOverride 90 "${logDirectory}/nix-daemon.log";
        StandardErrorPath = lib.mkOverride 90 "${logDirectory}/nix-daemon.log";
      };

      nix-gc.serviceConfig = {
        StandardOutPath = lib.mkOverride 90 "${logDirectory}/nix-gc.log";
        StandardErrorPath = lib.mkOverride 90 "${logDirectory}/nix-gc.log";
      };

      nix-optimise.serviceConfig = {
        StandardOutPath = lib.mkOverride 90 "${logDirectory}/nix-optimise.log";
        StandardErrorPath = lib.mkOverride 90 "${logDirectory}/nix-optimise.log";
      };

      sops-install-secrets.serviceConfig = {
        StandardOutPath = lib.mkOverride 90 "${privateLogDirectory}/sops-install-secrets.log";
        StandardErrorPath = lib.mkOverride 90 "${privateLogDirectory}/sops-install-secrets.log";
      };

      ${rotationJobName} = {
        command = lib.escapeShellArgs [
          (lib.getExe pkgs.logrotate)
          "--verbose"
          "--state"
          "${stateDirectory}/status"
          rotationConfig
        ];
        serviceConfig = {
          RunAtLoad = false;
          StartCalendarInterval = [
            {
              Hour = 0;
              Minute = 45;
            }
          ];
          StandardOutPath = "${logDirectory}/${rotationJobName}.log";
          StandardErrorPath = "${logDirectory}/${rotationJobName}.log";
        };
      };
    };
  };
}
