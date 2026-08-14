{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.observability.launchd;
  exporterName = "observability-launchd-export";
  textfileDir = "/var/lib/observability-launchd/textfile";
  exporter = pkgs.callPackage ./pkgs/launchd-exporter { };
  hasProgram =
    job:
    job.command != ""
    || job.serviceConfig.Program != null
    || job.serviceConfig.ProgramArguments != null;
  jobs = lib.filterAttrs (
    name: job: name != exporterName && hasProgram job && job.serviceConfig.Disabled != true
  ) config.launchd.daemons;
  inferMode =
    job:
    if job.serviceConfig.KeepAlive == true then
      "continuous"
    else if
      job.serviceConfig.StartInterval != null || job.serviceConfig.StartCalendarInterval != null
    then
      "scheduled"
    else if job.serviceConfig.RunAtLoad == true then
      "oneshot"
    else
      "on-demand";
  monitoredJobs = lib.filterAttrs (name: _: !builtins.elem name cfg.excludedJobs) jobs;
  expectedJobs = lib.mapAttrsToList (name: job: {
    inherit name;
    label = job.serviceConfig.Label;
    mode = cfg.jobModes.${name} or (inferMode job);
    extraLabels = cfg.jobLabels.${name} or { };
  }) monitoredJobs;
  sortedJobs = builtins.sort (left: right: left.name < right.name) expectedJobs;
  configurationFile = pkgs.writeText "darwin-launchd-export.json" (
    builtins.toJSON {
      jobs = map (job: { name = job.label; }) sortedJobs;
    }
  );
  escapeLabel = value: lib.replaceStrings [ "\\" "\"" "\n" ] [ "\\\\" "\\\"" "\\n" ] value;
  formatLabels =
    job:
    lib.concatStringsSep "," (
      lib.mapAttrsToList (name: value: ''${name}="${escapeLabel value}"'') (
        {
          domain = "system";
          name = job.label;
          inherit (job) mode;
        }
        // job.extraLabels
      )
    );
  expectationsFile = pkgs.writeText "darwin-launchd-expectations.prom" (
    ''
      # HELP nix_darwin_launchd_job_expected Whether nix-darwin expects a system launchd job to be loaded.
      # TYPE nix_darwin_launchd_job_expected gauge
    ''
    + lib.concatMapStrings (job: ''
      nix_darwin_launchd_job_expected{${formatLabels job}} 1
    '') sortedJobs
  );
in
{
  options.host.observability.launchd = {
    excludedJobs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "System LaunchDaemons excluded from expected-state monitoring.";
    };

    jobModes = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.enum [
          "continuous"
          "scheduled"
          "oneshot"
          "on-demand"
        ]
      );
      default = { };
      description = "Expected-state mode overrides for system LaunchDaemons.";
    };

    jobLabels = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.str);
      default = { };
      description = "Prometheus labels attached to expected system LaunchDaemons.";
    };
  };

  config = lib.mkIf config.host.observability.enable {
    host.observability.nodeExporter.textfile.directories.launchd = textfileDir;

    assertions = import ./observability/assertions.nix {
      inherit
        cfg
        jobs
        lib
        monitoredJobs
        ;
    };

    system.activationScripts.launchd.text = lib.mkAfter ''
      mkdir -p ${textfileDir}
      chown root:wheel ${textfileDir}
      chmod 0755 ${textfileDir}
      ln -sfn ${expectationsFile} ${textfileDir}/launchd-expectations.prom
    '';

    launchd.daemons.${exporterName} = {
      command = lib.escapeShellArgs [
        (lib.getExe exporter)
        "--config"
        configurationFile
        "--output"
        "${textfileDir}/launchd-state.prom"
      ];
      serviceConfig = {
        RunAtLoad = true;
        StartInterval = 30;
        ProcessType = "Background";
        StandardOutPath = "/var/log/${exporterName}.log";
        StandardErrorPath = "/var/log/${exporterName}.log";
      };
    };
  };
}
