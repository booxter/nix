{
  config,
  lib,
  pkgs,
  ...
}:
let
  nodeExporterTextfileDir = "/var/lib/prometheus-node-exporter-textfile";
  metricsFile = "${nodeExporterTextfileDir}/transmission-tracker-prioritizer.prom";
  sabnzbdPublicGroupSuppressionEnabled = false;
  sabnzbdBaseUrl = "http://127.0.0.1:${toString config.nixarr.sabnzbd.guiPort}";
  sabnzbdExporterUrl = "http://127.0.0.1:${toString config.services.prometheus.exporters.sabnzbd.port}/metrics";
  # Conservative fallback when the adaptive policy state is unavailable.
  fallbackPublicGroupUploadLimitKBps = builtins.floor (
    config.nixarr.transmission.extraSettings."speed-limit-up" * 0.5
  );
  minimumPrivateHeadroomFraction = "0.1";
  preferredUploadHeadroomFraction = "0.3";
  publicGroupRelaxationHoldSeconds = "30";
  sabnzbdPublicGroupFraction = "0.25";
in
{
  systemd.tmpfiles.rules = [
    "z ${nodeExporterTextfileDir} 0775 root media - -"
  ];

  sops.secrets.transmissionTrackerHosts = {
    key = "transmission/private_tracker_hosts";
    owner = "transmission";
    group = "media";
    mode = "0400";
  };

  systemd.services.transmission-tracker-prioritizer = {
    description = "Prefer uploads for torrents on selected private trackers";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-online.target"
      "nginx.service"
      "transmission.service"
    ]
    ++ lib.optionals sabnzbdPublicGroupSuppressionEnabled [
      "prometheus-sabnzbd-exporter.service"
    ];
    wants = [
      "network-online.target"
      "nginx.service"
      "transmission.service"
    ]
    ++ lib.optionals sabnzbdPublicGroupSuppressionEnabled [
      "prometheus-sabnzbd-exporter.service"
    ];
    serviceConfig = {
      ExecStart = lib.concatStringsSep " " (
        [
          (lib.getExe pkgs.transmission-tracker-prioritizer)
          "--rpc-url"
          "http://127.0.0.1:${toString config.nixarr.transmission.uiPort}/transmission/rpc"
          "--trackers-file"
          config.sops.secrets.transmissionTrackerHosts.path
          "--public-group-name"
          "public-low-priority"
          "--public-group-upload-limit-kbps"
          (toString fallbackPublicGroupUploadLimitKBps)
          "--bandwidth-state-file"
          "/run/adaptive-upload-policy/state.json"
          "--minimum-private-headroom-fraction"
          minimumPrivateHeadroomFraction
          "--preferred-upload-headroom-fraction"
          preferredUploadHeadroomFraction
          "--public-group-relaxation-hold-seconds"
          publicGroupRelaxationHoldSeconds
          "--metrics-file"
          metricsFile
          "--interval-seconds"
          "30"
          "--request-timeout-seconds"
          "20"
        ]
        ++ lib.optionals sabnzbdPublicGroupSuppressionEnabled [
          "--sabnzbd-exporter-url"
          sabnzbdExporterUrl
          "--sabnzbd-exporter-instance"
          sabnzbdBaseUrl
          "--sabnzbd-exporter-timeout-seconds"
          "5"
          "--sabnzbd-public-group-fraction"
          sabnzbdPublicGroupFraction
        ]
      );
      Restart = "always";
      RestartSec = "10s";
      # The daemon rereads the tracker file every iteration, so secret updates
      # are picked up without an activation-time systemd restart hook.
      User = "transmission";
      Group = "media";
    };
  };
}
