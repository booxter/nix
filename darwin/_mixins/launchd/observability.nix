{
  config,
  lib,
  pkgs,
  ...
}:
let
  launchdLib = import ./lib.nix { inherit lib; };
  exporterName = "observability-launchd-export";
  userExporterName = "observability-launchd-user-export";
  stateDir = "/var/lib/observability-launchd";
  textfileDir = "${stateDir}/textfile";
  userTextfileDir = "${stateDir}/user-textfile";
  exporter = pkgs.callPackage ./pkgs/launchd-exporter { };
  username = config.host.username;
  userHome = config.users.users.${username}.home;
  userLogDir = "${userHome}/Library/Logs/nix-darwin";
  homeManagerConfig = config.home-manager.users.${username};

  expectedFromNixDarwin =
    domain: jobs:
    lib.mapAttrsToList (_: job: {
      inherit domain;
      label = job.serviceConfig.Label;
      mode = launchdLib.inferMode job.serviceConfig;
    }) (launchdLib.managedJobs jobs);
  homeManagerJobs = lib.filterAttrs (
    _: job: job.enable && job.config.Disabled != true && launchdLib.hasProgramConfig job.config
  ) homeManagerConfig.launchd.agents;
  expectedFromHomeManager = lib.mapAttrsToList (_: job: {
    domain = "user";
    label = job.config.Label;
    mode = launchdLib.inferMode job.config;
  }) (lib.optionalAttrs homeManagerConfig.launchd.enable homeManagerJobs);

  systemJobs = expectedFromNixDarwin "system" (removeAttrs config.launchd.daemons [ exporterName ]);
  userJobs =
    expectedFromNixDarwin "user" config.launchd.agents
    ++ expectedFromNixDarwin "user" (removeAttrs config.launchd.user.agents [ userExporterName ])
    ++ expectedFromHomeManager;
  sortJobs = builtins.sort (left: right: left.label < right.label);
  sortedSystemJobs = sortJobs systemJobs;
  sortedUserJobs = sortJobs userJobs;
  allJobs = sortedSystemJobs ++ sortedUserJobs;
  userJobLabels = map (job: job.label) sortedUserJobs;
  duplicateUserLabels = lib.filter (
    label: lib.count (candidate: candidate == label) userJobLabels > 1
  ) (lib.unique userJobLabels);

  mkConfigurationFile =
    {
      domain,
      jobs,
      monitoredUser ? null,
    }:
    pkgs.writeText "darwin-launchd-${domain}-export.json" (
      builtins.toJSON {
        inherit domain monitoredUser;
        jobs = map (job: { name = job.label; }) jobs;
      }
    );
  systemConfigurationFile = mkConfigurationFile {
    domain = "system";
    jobs = sortedSystemJobs;
    monitoredUser = username;
  };
  userConfigurationFile = mkConfigurationFile {
    domain = "user";
    jobs = sortedUserJobs;
  };

  escapeLabel = value: lib.replaceStrings [ "\\" "\"" "\n" ] [ "\\\\" "\\\"" "\\n" ] value;
  formatLabels =
    job:
    lib.concatStringsSep "," (
      lib.mapAttrsToList (name: value: ''${name}="${escapeLabel value}"'') {
        inherit (job) domain mode;
        name = job.label;
      }
    );
  expectationsFile = pkgs.writeText "darwin-launchd-expectations.prom" (
    ''
      # HELP nix_darwin_launchd_domain_expected Whether launchd monitoring is configured for a domain.
      # TYPE nix_darwin_launchd_domain_expected gauge
      nix_darwin_launchd_domain_expected{domain="system"} 1
      nix_darwin_launchd_domain_expected{domain="user"} 1
      # HELP nix_darwin_launchd_job_expected Whether the evaluated configuration expects a launchd job to be loaded.
      # TYPE nix_darwin_launchd_job_expected gauge
    ''
    + lib.concatMapStrings (job: ''
      nix_darwin_launchd_job_expected{${formatLabels job}} 1
    '') allJobs
  );

  exporterCommand =
    configurationFile: output:
    lib.escapeShellArgs [
      (lib.getExe exporter)
      "--config"
      configurationFile
      "--output"
      output
    ];
in
{
  config = lib.mkIf config.host.observability.enable {
    assertions = [
      {
        assertion = duplicateUserLabels == [ ];
        message = "User launchd monitoring requires unique labels; duplicates: ${lib.concatStringsSep ", " duplicateUserLabels}";
      }
    ];

    host.observability.nodeExporter.textfile.directories = {
      launchd = textfileDir;
      launchd-user = userTextfileDir;
    };

    system.activationScripts.launchd.text = lib.mkBefore ''
      install -d -m 0755 -o root -g wheel ${stateDir}
      install -d -m 0755 -o root -g wheel ${textfileDir}
      install -d -m 0755 -o ${lib.escapeShellArg username} -g staff ${userTextfileDir}
      install -d -m 0755 -o ${lib.escapeShellArg username} -g staff ${lib.escapeShellArg userLogDir}
      ln -sfn ${expectationsFile} ${textfileDir}/launchd-expectations.prom
    '';

    launchd.daemons.${exporterName} = {
      command = exporterCommand systemConfigurationFile "${textfileDir}/launchd-state.prom";
      serviceConfig = {
        RunAtLoad = true;
        StartInterval = 30;
        ProcessType = "Background";
        StandardOutPath = "/var/log/${exporterName}.log";
        StandardErrorPath = "/var/log/${exporterName}.log";
      };
    };

    launchd.user.agents.${userExporterName} = {
      command = exporterCommand userConfigurationFile "${userTextfileDir}/launchd-state.prom";
      serviceConfig = {
        RunAtLoad = true;
        StartInterval = 30;
        ProcessType = "Background";
        StandardOutPath = "${userLogDir}/${userExporterName}.log";
        StandardErrorPath = "${userLogDir}/${userExporterName}.log";
      };
    };
  };
}
