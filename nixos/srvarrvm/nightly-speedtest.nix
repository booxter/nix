{
  config,
  lib,
  pkgs,
  ...
}:
let
  textfileDir = "/var/lib/prometheus-node-exporter-textfile";
  metricsFile = "${textfileDir}/nightly-speedtest.prom";
  speedtestBin = lib.getExe pkgs.librespeed-cli;
  wgNamespaceName = "wg";
  # Pinned servers chosen for stable scheduled runs.
  # WAN: Grand Rapids, Michigan (RackGenius). WG: Chicago, USA (Sharktech).
  wanServerId = "100";
  wgServerId = "93";
  transmissionRpcUrl = "http://127.0.0.1:${toString config.nixarr.transmission.uiPort}/transmission/rpc";
  sabnzbdApiUrl = "http://127.0.0.1:${toString config.nixarr.sabnzbd.guiPort}/api";
  sabnzbdExporterUrl = "http://127.0.0.1:${toString config.services.prometheus.exporters.sabnzbd.port}/metrics";
  sabnzbdExporterInstance = "http://127.0.0.1:${toString config.nixarr.sabnzbd.guiPort}";
in
{
  systemd.services.nightly-speedtest-probe = {
    description = "Run nightly direct and WireGuard speedtests on srvarr";
    after = [
      "network-online.target"
      "wg.service"
      "sabnzbd.service"
      "transmission.service"
      "prometheus-sabnzbd-exporter.service"
    ];
    wants = [
      "network-online.target"
      "wg.service"
      "sabnzbd.service"
      "transmission.service"
      "prometheus-sabnzbd-exporter.service"
    ];
    unitConfig = {
      RequiresMountsFor = textfileDir;
    };
    serviceConfig = {
      Type = "oneshot";
      RuntimeDirectory = "nightly-speedtest-probe";
      TimeoutSec = "15m";
      ExecStart = lib.concatStringsSep " " [
        (lib.getExe pkgs.nightly-speedtest-probe)
        "run"
        "--metrics-file"
        metricsFile
        "--speedtest-command"
        speedtestBin
        "--wg-namespace-name"
        wgNamespaceName
        "--wan-server-id"
        wanServerId
        "--wg-server-id"
        wgServerId
        "--transmission-rpc-url"
        transmissionRpcUrl
        "--sabnzbd-api-url"
        sabnzbdApiUrl
        "--sabnzbd-api-key-file"
        "/run/prometheus-sabnzbd-exporter/apikey"
        "--sabnzbd-exporter-url"
        sabnzbdExporterUrl
        "--sabnzbd-exporter-instance"
        sabnzbdExporterInstance
        "--request-timeout-seconds"
        "20"
        "--speedtest-timeout-seconds"
        "180"
        "--drain-timeout-seconds"
        "60"
        "--drain-poll-seconds"
        "1"
        "--post-drain-settle-seconds"
        "5"
      ];
      ExecStopPost = lib.concatStringsSep " " [
        (lib.getExe pkgs.nightly-speedtest-probe)
        "restore"
        "--transmission-rpc-url"
        transmissionRpcUrl
        "--sabnzbd-api-url"
        sabnzbdApiUrl
        "--sabnzbd-api-key-file"
        "/run/prometheus-sabnzbd-exporter/apikey"
        "--request-timeout-seconds"
        "20"
      ];
    };
  };

  systemd.timers.nightly-speedtest-probe = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "04:00";
      AccuracySec = "1m";
      Unit = "nightly-speedtest-probe.service";
    };
  };
}
