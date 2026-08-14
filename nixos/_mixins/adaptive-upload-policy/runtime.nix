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
    group
    intervalSeconds
    jellyfin
    maxStateAgeSeconds
    metricsFile
    mtls
    policy
    qosOutput
    stateFile
    transmissionOutput
    user
    ;
  transmissionCommon = pkgs.callPackage ../transmission/pkgs/common { };
  package = pkgs.callPackage ./pkgs/controller {
    atomicFileWrites = pkgs.atomic-file-writes;
    inherit transmissionCommon;
  };
  controllerConfig = (pkgs.formats.json { }).generate "adaptive-upload-policy.json" {
    state_file = stateFile;
    metrics_file = metricsFile;
    interval_seconds = intervalSeconds;
    max_state_age_seconds = maxStateAgeSeconds;
    fallback_rate_mbit = cfg.fallbackRateMbit;
    jellyfin = {
      exporter_url = jellyfin.exporterUrl;
      request_timeout_seconds = jellyfin.requestTimeoutSeconds;
      ca_file = if mtls == null then "" else "${mtls.caFile}";
      client_cert_file =
        if mtls == null || mtls.certificateFile == null then "" else mtls.certificateFile;
      client_key_file = if mtls == null || mtls.keyFile == null then "" else mtls.keyFile;
      media_types = jellyfin.mediaTypes;
      idle_rate_mbit = policy.idleRateMbit;
      minimum_rate_mbit = policy.minimumRateMbit;
      bitrate_headroom_fraction = 1.0;
      relaxation_hold_seconds = policy.relaxationHoldSeconds;
    };
    transmission =
      if transmissionOutput != null then
        {
          rpc_url = transmissionOutput.rpcUrl;
          request_timeout_seconds = transmissionOutput.requestTimeoutSeconds;
          headroom_fraction = transmissionOutput.headroomPercent / 100.0;
        }
      else
        null;
    qos =
      if qosOutput != null then
        {
          executable = lib.getExe config.host.qos.package;
          config_file = config.host.qos.configFiles.${qosOutput.profile};
          limit = qosOutput.limit;
        }
      else
        null;
  };
  command =
    action:
    utils.escapeSystemdExecArgs [
      (lib.getExe package)
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
    User = user;
    Group = group;
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
