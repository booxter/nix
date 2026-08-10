{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  model = import ./model.nix { inherit config; };
  inherit (model)
    cfg
    maxStateAgeSeconds
    metricsFile
    mtls
    qosService
    stateDir
    transmissionRpcUrl
    ;
  controller = lib.getExe cfg.package;
  deciderUnit = "adaptive-upload-policy.service";
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
      bitrate_headroom_fraction = cfg.policy.bitrateHeadroomPercent / 100.0;
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
      controller
      action
      "--config"
      controllerConfig
    ];
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
in
{
  config = lib.mkIf cfg.enable {
    users.groups.${cfg.group} = { };
    users.users.${cfg.user} = {
      description = "Adaptive upload policy controller";
      isSystemUser = true;
      group = cfg.group;
    };

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0750 ${cfg.user} ${cfg.group} -"
    ]
    ++ lib.optional cfg.metrics.enable "z ${cfg.metrics.directory} 0775 root ${cfg.group} - -";

    systemd.services = {
      adaptive-upload-policy = {
        description = "Decide adaptive upload policy from Jellyfin playback";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ] ++ lib.optionals mtls.enable mtls.dependencyUnits;
        after = [ "network-online.target" ] ++ lib.optionals mtls.enable mtls.dependencyUnits;
        serviceConfig = commonServiceConfig // {
          ExecStart = command "decide";
          ReadWritePaths = [ stateDir ] ++ lib.optional cfg.metrics.enable cfg.metrics.directory;
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_INET"
            "AF_INET6"
          ];
        };
      };

      adaptive-upload-policy-transmission = lib.mkIf cfg.outputs.transmission.enable {
        description = "Apply adaptive upload policy to Transmission";
        wantedBy = [ "multi-user.target" ];
        wants = [
          "network-online.target"
          deciderUnit
          "transmission.service"
        ];
        after = [
          "network-online.target"
          deciderUnit
          "transmission.service"
        ];
        serviceConfig = commonServiceConfig // {
          ExecStart = command "apply-transmission";
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_INET"
            "AF_INET6"
          ];
        };
      };

      adaptive-upload-policy-qos = lib.mkIf cfg.outputs.qos.enable {
        description = "Apply adaptive upload policy to a host.qos limit";
        wantedBy = [ "multi-user.target" ];
        wants = [
          deciderUnit
          qosService
        ];
        after = [
          deciderUnit
          qosService
        ];
        partOf = [ qosService ];
        serviceConfig = commonServiceConfig // {
          ExecStart = command "apply-qos";
          AmbientCapabilities = [ "CAP_NET_ADMIN" ];
          CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_NETLINK"
          ];
        };
      };
    };
  };
}
