{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.transmission;
  common = pkgs.callPackage ./packages/common { };
  packages = pkgs.callPackage ./packages/tracker-policy {
    transmissionCommon = common;
  };
  nodeExporterTextfileDir = "/var/lib/prometheus-node-exporter-textfile";
  metricsFile = "${nodeExporterTextfileDir}/transmission-collector.prom";
  serviceDeps = [
    "network-online.target"
    "nginx.service"
    "transmission.service"
  ];
  commonExecStart = [
    "--rpc-url"
    "http://127.0.0.1:${toString config.services.transmission.settings.rpc-port}/transmission/rpc"
    "--trackers-file"
    config.sops.secrets.transmissionTrackerHosts.path
    "--non-preferred-low-priority-ratio"
    (toString cfg.prioritizer.nonPreferredLowPriorityRatio)
    "--non-preferred-pause-ratio"
    (toString cfg.prioritizer.nonPreferredPauseRatio)
    "--interval-seconds"
    (toString cfg.prioritizer.intervalSeconds)
    "--request-timeout-seconds"
    (toString cfg.prioritizer.requestTimeoutSeconds)
  ];
  mkTrackerService =
    {
      description,
      package,
      extraArgs ? [ ],
    }:
    {
      inherit description;
      wantedBy = [ "multi-user.target" ];
      after = serviceDeps;
      wants = serviceDeps;
      serviceConfig = {
        ExecStart = lib.concatStringsSep " " ([ (lib.getExe package) ] ++ commonExecStart ++ extraArgs);
        Restart = "always";
        RestartSec = "10s";
        # The daemon rereads the tracker file every iteration, so secret updates
        # are picked up without an activation-time systemd restart hook.
        User = "transmission";
        Group = "media";
      };
    };
in
{
  options.services.transmission = {
    prioritizer = {
      enable = lib.mkEnableOption "private-tracker Transmission priority enforcement" // {
        default = true;
      };

      nonPreferredLowPriorityRatio = lib.mkOption {
        type = lib.types.number;
        default = 3.0;
        description = "Ratio at which non-preferred torrents become low priority.";
      };

      nonPreferredPauseRatio = lib.mkOption {
        type = lib.types.number;
        default = 6.0;
        description = "Ratio at which non-preferred torrents are paused.";
      };

      intervalSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 30;
        description = "Seconds between tracker-policy passes.";
      };

      requestTimeoutSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 20;
        description = "Transmission RPC timeout in seconds.";
      };
    };

    collector.enable = lib.mkEnableOption "Transmission torrent metrics collection" // {
      default = true;
    };
  };

  config = lib.mkIf config.host.transmission.enable {
    assertions = [
      {
        assertion = cfg.prioritizer.nonPreferredLowPriorityRatio <= cfg.prioritizer.nonPreferredPauseRatio;
        message = "Transmission's non-preferred low-priority ratio must not exceed its pause ratio.";
      }
    ];

    systemd.tmpfiles.rules = lib.optional cfg.collector.enable (
      "z ${nodeExporterTextfileDir} 0775 root ${cfg.group} - -"
    );

    systemd.services.transmission-prioritizer = lib.mkIf cfg.prioritizer.enable (mkTrackerService {
      description = "Enforce Transmission torrent priorities for selected private trackers";
      package = packages.prioritizer;
    });

    systemd.services.transmission-collector = lib.mkIf cfg.collector.enable (mkTrackerService {
      description = "Collect Transmission torrent metrics";
      package = packages.collector;
      extraArgs = [
        "--metrics-file"
        metricsFile
      ];
    });
  };
}
