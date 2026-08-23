{
  config,
  launchdModel,
  lib,
  pkgs,
  ...
}:
let
  exporterName = "observability-launchd-export";
  userExporterName = "observability-launchd-user-export";
  stateDir = "/var/lib/observability-launchd";
  textfileDir = "${stateDir}/textfile";
  userTextfileDir = "${stateDir}/user-textfile";
  exporter = pkgs.callPackage ./pkgs/launchd-exporter { };
  username = config.host.username;
  userHome = config.users.users.${username}.home;
  userLogDir = "${userHome}/Library/Logs/nix-darwin";
  expectedJobs = jobs: lib.mapAttrsToList (_: job: { inherit (job) domain label mode; }) jobs;
  managedJobs = jobs: lib.filterAttrs (_: job: job.managed) jobs;
  homeManagerJobs = lib.filterAttrs (_: job: job.managed && job.launchdEnabled) (
    removeAttrs launchdModel.homeManagerJobs [ userExporterName ]
  );

  systemJobs = expectedJobs (
    managedJobs (removeAttrs launchdModel.systemJobsByDomain.daemons [ exporterName ])
  );
  userJobs =
    expectedJobs (managedJobs launchdModel.systemJobsByDomain.agents)
    ++ expectedJobs (lib.optionalAttrs launchdModel.homeManagerLaunchdEnabled homeManagerJobs);
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

  exporterArguments =
    configurationFile: output:
    map toString [
      (lib.getExe exporter)
      "--config"
      configurationFile
      "--output"
      output
    ];
  exporterCommand =
    configurationFile: output: lib.escapeShellArgs (exporterArguments configurationFile output);
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
      ln -sfn ${expectationsFile} ${textfileDir}/launchd-expectations.prom
    '';

    launchd.daemons.${exporterName} = {
      command = exporterCommand systemConfigurationFile "${textfileDir}/launchd-state.prom";
      serviceConfig = {
        RunAtLoad = true;
        StartInterval = 30;
        ProcessType = "Background";
        StandardOutPath = "/var/log/nix-darwin/${exporterName}.log";
        StandardErrorPath = "/var/log/nix-darwin/${exporterName}.log";
      };
    };

    home-manager.users.${username}.launchd.agents.${userExporterName} = {
      enable = true;
      config = {
        Label = "org.nixos.${userExporterName}";
        ProgramArguments = exporterArguments userConfigurationFile "${userTextfileDir}/launchd-state.prom";
        RunAtLoad = true;
        StartInterval = 30;
        ProcessType = "Background";
        StandardOutPath = "${userLogDir}/${userExporterName}.log";
        StandardErrorPath = "${userLogDir}/${userExporterName}.log";
      };
    };
  };
}
