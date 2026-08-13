{
  config,
  lib,
  outputs,
  pkgs,
  utils,
}:
let
  model = import ./model.nix { inherit config outputs; };
  inherit (model)
    cfg
    maxStateAgeSeconds
    metricsFile
    mtls
    transmissionRpcUrl
    ;
  controllerConfig = (pkgs.formats.json { }).generate "adaptive-upload-policy.json" {
    state_file = cfg.stateFile;
    metrics_file = if cfg.metrics.enable then metricsFile else null;
    interval_seconds = cfg.intervalSeconds;
    max_state_age_seconds = maxStateAgeSeconds;
    fallback_rate_mbit = cfg.fallbackRateMbit;
    jellyfin = {
      exporter_url = cfg.source.jellyfin.exporterUrl;
      request_timeout_seconds = cfg.source.jellyfin.requestTimeoutSeconds;
      ca_file = if mtls.enable then "${mtls.caFile}" else "";
      client_cert_file = if mtls.enable && mtls.certificateFile != null then mtls.certificateFile else "";
      client_key_file = if mtls.enable && mtls.keyFile != null then mtls.keyFile else "";
      media_types = cfg.source.jellyfin.mediaTypes;
      idle_rate_mbit = cfg.policy.idleRateMbit;
      minimum_rate_mbit = cfg.policy.minimumRateMbit;
      bitrate_headroom_fraction = 1.0;
      relaxation_hold_seconds = cfg.policy.relaxationHoldSeconds;
    };
    transmission =
      if cfg.outputs.transmission.enable then
        {
          rpc_url = transmissionRpcUrl;
          request_timeout_seconds = cfg.outputs.transmission.requestTimeoutSeconds;
          headroom_fraction = cfg.outputs.transmission.headroomPercent / 100.0;
        }
      else
        null;
    qos =
      if cfg.outputs.qos.enable then
        {
          executable = lib.getExe config.host.qos.package;
          config_file = config.host.qos.configFiles.${cfg.outputs.qos.profile};
          limit = cfg.outputs.qos.limit;
        }
      else
        null;
  };
  command =
    action:
    utils.escapeSystemdExecArgs [
      (lib.getExe cfg.package)
      action
      "--config"
      controllerConfig
    ];
in
model
// {
  inherit command;
  deciderUnit = "adaptive-upload-policy.service";
  commonServiceConfig = {
    Restart = "always";
    RestartSec = "10s";
    User = cfg.user;
    Group = cfg.group;
    UMask = "0027";
    NoNewPrivileges = true;
    PrivateDevices = true;
    PrivateTmp = true;
    ProtectClock = true;
    ProtectControlGroups = true;
    ProtectHome = true;
    ProtectHostname = true;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectKernelTunables = true;
    ProtectProc = "invisible";
    ProtectSystem = "strict";
    ProcSubset = "pid";
    LockPersonality = true;
    RemoveIPC = true;
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    SystemCallArchitectures = "native";
  };
}
