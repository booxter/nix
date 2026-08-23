{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.nix.builder;
  textfileDir = "/var/lib/nix-builder-metrics/textfile";
in
{
  config = lib.mkIf (cfg != null && config.host.observability.enable) {
    host.observability.nodeExporter.textfile.directories.nixBuilderMetrics = textfileDir;

    system.activationScripts.launchd.text = lib.mkAfter ''
      install -d -m 0755 -o root -g wheel ${textfileDir}
    '';

    launchd.daemons.nix-builder-metrics = {
      command = lib.escapeShellArgs [
        (lib.getExe pkgs.nix-builder-metrics)
        "--configured-slots"
        (toString config.nix.settings.max-jobs)
        "--darwin-ps"
        "/bin/ps"
        "--output-file"
        "${textfileDir}/nix-builder.prom"
      ];
      serviceConfig = {
        RunAtLoad = true;
        StartInterval = 15;
        ProcessType = "Background";
        StandardOutPath = "/var/log/nix-darwin/nix-builder-metrics.log";
        StandardErrorPath = "/var/log/nix-darwin/nix-builder-metrics.log";
      };
    };
  };
}
