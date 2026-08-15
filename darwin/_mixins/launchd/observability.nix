{
  config,
  lib,
  pkgs,
  ...
}:
let
  launchdLib = import ./lib.nix { inherit lib; };
  exporterName = "observability-launchd-export";
  textfileDir = "/var/lib/observability-launchd/textfile";
  exporter = pkgs.callPackage ./pkgs/launchd-exporter { };
  jobs = launchdLib.managedJobs (removeAttrs config.launchd.daemons [ exporterName ]);
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
  expectedJobs = lib.mapAttrsToList (name: job: {
    inherit name;
    label = job.serviceConfig.Label;
    mode = inferMode job;
  }) jobs;
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
      lib.mapAttrsToList (name: value: ''${name}="${escapeLabel value}"'') ({
        domain = "system";
        name = job.label;
        inherit (job) mode;
      })
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
  config = lib.mkIf config.host.observability.enable {
    host.observability.nodeExporter.textfile.directories.launchd = textfileDir;

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
