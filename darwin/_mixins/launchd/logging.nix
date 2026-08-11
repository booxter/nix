{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.launchd.logging;
  logDirectory = "/var/log/nix-darwin";
  privateLogDirectory = "/var/log/nix-darwin-private";
  stateDirectory = "/var/lib/nix-darwin-logrotate";
  rotationJobName = "launchd-logrotate";
  jobsByDomain = {
    daemons = config.launchd.daemons;
    agents = config.launchd.agents;
    userAgents = config.launchd.user.agents;
  };
  enabledJobs = lib.filterAttrs (_: job: job.serviceConfig.Disabled != true);
  pathsFor =
    jobs:
    builtins.sort builtins.lessThan (
      lib.unique (
        lib.concatMap (
          job:
          builtins.filter (path: path != null) [
            job.serviceConfig.StandardOutPath
            job.serviceConfig.StandardErrorPath
          ]
        ) (builtins.attrValues jobs)
      )
    );
  systemLogPaths = lib.unique (
    pathsFor (enabledJobs jobsByDomain.daemons) ++ pathsFor (enabledJobs jobsByDomain.agents)
  );
  userLogPaths = pathsFor (enabledJobs jobsByDomain.userAgents);
  quotePath = path: ''"${lib.replaceStrings [ "\\" "\"" ] [ "\\\\" "\\\"" ] path}"'';
  rotationBlock =
    {
      paths,
      runAs ? null,
    }:
    lib.optionalString (paths != [ ]) ''
      ${lib.concatMapStringsSep " " quotePath paths} {
        daily
        maxsize ${toString cfg.maxSizeMiB}M
        rotate ${toString cfg.retainedArchives}
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
  options.host.launchd.logging = {
    exclusions = {
      daemons = lib.mkOption {
        type = lib.types.attrsOf (lib.types.strMatching ".+");
        default = { };
        description = "System LaunchDaemons exempted from file logging, with rationales.";
      };

      agents = lib.mkOption {
        type = lib.types.attrsOf (lib.types.strMatching ".+");
        default = { };
        description = "System LaunchAgents exempted from file logging, with rationales.";
      };

      userAgents = lib.mkOption {
        type = lib.types.attrsOf (lib.types.strMatching ".+");
        default = { };
        description = "User LaunchAgents exempted from file logging, with rationales.";
      };
    };

    maxSizeMiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = "Maximum launchd log size before early rotation.";
    };

    retainedArchives = lib.mkOption {
      type = lib.types.ints.positive;
      default = 7;
      description = "Number of compressed launchd log archives to retain.";
    };
  };

  config = {
    assertions = import ./logging/assertions.nix {
      inherit cfg jobsByDomain lib;
    };

    system.activationScripts.launchd.text = lib.mkBefore ''
      install -d -m 0755 -o root -g wheel ${logDirectory}
      install -d -m 0700 -o root -g wheel ${privateLogDirectory}
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
