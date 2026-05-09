{
  jellyfinExporterUrl,
  fallbackUploadRateMbit,
  networkOnlineUnitDeps,
  wgEndpointPort,
  wgOuterLinkRate,
  wgUnitDepsBase,
}:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  decisionIntervalSecondsInt = 5;
  decisionIntervalSeconds = toString decisionIntervalSecondsInt;
  applierIntervalSecondsInt = 5;
  applierIntervalSeconds = toString applierIntervalSecondsInt;
  idleUploadRateMbit = "25";
  minimumStreamUploadRateMbit = "0.5";
  relaxationHoldSeconds = "90";
  maxStateAgeSeconds = toString (decisionIntervalSecondsInt * 3);
  publicGroupFraction = "0.5";
  # Reserve some slack for stream startup and bitrate spikes.
  streamBitrateHeadroomFraction = "0.1";
  stateFile = "/run/adaptive-upload-policy/state.json";
  stateDir = dirOf stateFile;
  nodeExporterTextfileDir = "/var/lib/prometheus-node-exporter-textfile";
  metricsFile = "${nodeExporterTextfileDir}/adaptive-upload-policy.prom";
  transmissionRpcUrl = "http://127.0.0.1:${toString config.nixarr.transmission.uiPort}/transmission/rpc";
in
{
  systemd.tmpfiles.rules = [
    "d ${stateDir} 0755 transmission media -"
    "z ${nodeExporterTextfileDir} 0775 root media - -"
  ];

  systemd.services.jellyfin-upload-policy = {
    description = "Decide adaptive torrent upload policy from Jellyfin playback";
    wantedBy = [ "multi-user.target" ];
    unitConfig = networkOnlineUnitDeps;
    serviceConfig = {
      ExecStart = lib.concatStringsSep " " [
        (lib.getExe pkgs.adaptive-upload-controller)
        "decide"
        "--exporter-url"
        jellyfinExporterUrl
        "--state-file"
        stateFile
        "--metrics-file"
        metricsFile
        "--interval-seconds"
        decisionIntervalSeconds
        "--request-timeout-seconds"
        "10"
        "--no-streams-mbit"
        idleUploadRateMbit
        "--minimum-streams-mbit"
        minimumStreamUploadRateMbit
        "--fallback-mbit"
        (toString fallbackUploadRateMbit)
        "--stream-bitrate-headroom-fraction"
        streamBitrateHeadroomFraction
        "--relaxation-hold-seconds"
        relaxationHoldSeconds
        "--public-group-fraction"
        publicGroupFraction
      ];
      Restart = "always";
      RestartSec = "10s";
      User = "transmission";
      Group = "media";
    };
  };

  systemd.services.jellyfin-upload-policy-transmission = {
    description = "Apply adaptive upload policy to Transmission";
    wantedBy = [ "multi-user.target" ];
    unitConfig = networkOnlineUnitDeps // {
      Wants = (networkOnlineUnitDeps.Wants or [ ]) ++ [
        "jellyfin-upload-policy.service"
        "transmission.service"
      ];
      After = (networkOnlineUnitDeps.After or [ ]) ++ [
        "jellyfin-upload-policy.service"
        "transmission.service"
      ];
      BindsTo = [ "transmission.service" ];
      PartOf = [ "transmission.service" ];
    };
    serviceConfig = {
      ExecStart = lib.concatStringsSep " " [
        (lib.getExe pkgs.adaptive-upload-controller)
        "apply-transmission"
        "--rpc-url"
        transmissionRpcUrl
        "--state-file"
        stateFile
        "--interval-seconds"
        applierIntervalSeconds
        "--request-timeout-seconds"
        "20"
        "--fallback-mbit"
        (toString fallbackUploadRateMbit)
        "--public-group-fraction"
        publicGroupFraction
        "--max-state-age-seconds"
        maxStateAgeSeconds
      ];
      Restart = "always";
      RestartSec = "10s";
      User = "transmission";
      Group = "media";
    };
  };

  systemd.services.jellyfin-upload-policy-tc = {
    description = "Apply adaptive upload policy to WireGuard tc shaping";
    wantedBy = [ "multi-user.target" ];
    unitConfig = wgUnitDepsBase // {
      Wants = (wgUnitDepsBase.Wants or [ ]) ++ [
        "jellyfin-upload-policy.service"
        "wg-qos-upload.service"
      ];
      After = (wgUnitDepsBase.After or [ ]) ++ [
        "jellyfin-upload-policy.service"
        "wg-qos-upload.service"
      ];
    };
    serviceConfig = {
      ExecStart = lib.concatStringsSep " " [
        (lib.getExe pkgs.adaptive-upload-controller)
        "apply-tc"
        "--state-file"
        stateFile
        "--interval-seconds"
        applierIntervalSeconds
        "--fallback-mbit"
        (toString fallbackUploadRateMbit)
        "--public-group-fraction"
        publicGroupFraction
        "--max-state-age-seconds"
        maxStateAgeSeconds
        "--outer-link-rate"
        wgOuterLinkRate
        "--endpoint-port"
        (toString wgEndpointPort)
      ];
      Restart = "always";
      RestartSec = "10s";
    };
  };
}
