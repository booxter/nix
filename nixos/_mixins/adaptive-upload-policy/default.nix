{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.services.adaptive-upload-policy;
  internalPkiRootCaPath = config.host.internalPki.rootCaCertificate;
  transmissionCommon = pkgs.callPackage ../../srvarr/pkgs/transmission-common { };
  defaultPackage = pkgs.callPackage ./pkgs/controller {
    atomicFileWrites = pkgs.atomic-file-writes;
    inherit transmissionCommon;
  };
  positiveNumber = lib.types.addCheck lib.types.number (value: value > 0);
  positiveInt = lib.types.addCheck lib.types.int (value: value > 0);
  fraction = lib.types.addCheck lib.types.number (value: value >= 0 && value <= 1);
  stateDir = dirOf cfg.stateFile;
  metricsFile = "${cfg.metrics.directory}/${cfg.metrics.fileName}";
  maxStateAgeSeconds =
    if cfg.maxStateAgeSeconds != null then cfg.maxStateAgeSeconds else cfg.intervalSeconds * 3;
  controller = lib.getExe cfg.package;
  deciderUnit = "adaptive-upload-policy.service";
  mtls = cfg.source.jellyfin.mtls;
  transmissionRpcUrl =
    if cfg.outputs.transmission.rpcUrl != null then
      cfg.outputs.transmission.rpcUrl
    else
      "http://127.0.0.1:${toString config.services.transmission.settings.rpc-port}/transmission/rpc";
  qosProfile = config.host.qos.interfaces.${cfg.outputs.qos.profile} or null;
  qosLimit = if qosProfile != null then qosProfile.limits.${cfg.outputs.qos.limit} or null else null;
  qosService = "qos-${cfg.outputs.qos.profile}.service";
  controllerConfig = (pkgs.formats.json { }).generate "adaptive-upload-policy.json" {
    state_file = cfg.stateFile;
    metrics_file = if cfg.metrics.enable then metricsFile else null;
    interval_seconds = cfg.intervalSeconds;
    max_state_age_seconds = maxStateAgeSeconds;
    fallback_rate_mbit = cfg.fallbackRateMbit;
    jellyfin = {
      exporter_url = cfg.source.jellyfin.exporterUrl;
      request_timeout_seconds = cfg.source.jellyfin.requestTimeoutSeconds;
      ca_file = if mtls.enable then toString mtls.caFile else "";
      client_cert_file = if mtls.enable && mtls.certificateFile != null then mtls.certificateFile else "";
      client_key_file = if mtls.enable && mtls.keyFile != null then mtls.keyFile else "";
      media_types = cfg.source.jellyfin.mediaTypes;
      idle_rate_mbit = cfg.policy.idleRateMbit;
      minimum_rate_mbit = cfg.policy.minimumRateMbit;
      bitrate_headroom_fraction = cfg.policy.bitrateHeadroomFraction;
      relaxation_hold_seconds = cfg.policy.relaxationHoldSeconds;
    };
    transmission =
      if cfg.outputs.transmission.enable then
        {
          rpc_url = transmissionRpcUrl;
          request_timeout_seconds = cfg.outputs.transmission.requestTimeoutSeconds;
          headroom_fraction = cfg.outputs.transmission.headroomFraction;
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
  options.services.adaptive-upload-policy = {
    enable = lib.mkEnableOption "Jellyfin-aware adaptive upload policy";

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      description = "Adaptive upload controller package.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "adaptive-upload-policy";
      description = "User account used by the adaptive upload services.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "adaptive-upload-policy";
      description = "Group used by the adaptive upload services.";
    };

    stateFile = lib.mkOption {
      type = lib.types.str;
      default = "/run/adaptive-upload-policy/state.json";
      description = "Shared policy state file.";
    };

    intervalSeconds = lib.mkOption {
      type = positiveInt;
      default = 5;
      description = "Polling interval used by the decider and appliers.";
    };

    maxStateAgeSeconds = lib.mkOption {
      type = with lib.types; nullOr positiveInt;
      default = null;
      description = "Maximum accepted state age, or null for three polling intervals.";
    };

    fallbackRateMbit = lib.mkOption {
      type = positiveNumber;
      description = "Conservative upload rate used when policy state is unavailable.";
    };

    policy = {
      idleRateMbit = lib.mkOption {
        type = positiveNumber;
        default = 25;
        description = "Upload rate allowed when no external streams are active.";
      };

      minimumRateMbit = lib.mkOption {
        type = positiveNumber;
        default = 0.5;
        description = "Minimum upload rate while external streams are active.";
      };

      bitrateHeadroomFraction = lib.mkOption {
        type = fraction;
        default = 0.1;
        description = "Extra bandwidth reserved above observed stream bitrates.";
      };

      relaxationHoldSeconds = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 90;
        description = "Stable period required before relaxing an upload limit.";
      };
    };

    source.jellyfin = {
      exporterUrl = lib.mkOption {
        type = lib.types.str;
        description = "Jellyfin exporter metrics URL.";
      };

      requestTimeoutSeconds = lib.mkOption {
        type = positiveInt;
        default = 10;
        description = "Jellyfin exporter request timeout.";
      };

      mediaTypes = lib.mkOption {
        type = with lib.types; nonEmptyListOf str;
        default = [
          "audio"
          "audiobook"
          "episode"
          "movie"
          "musicvideo"
          "trailer"
          "video"
        ];
        description = "Jellyfin media types included in upload budgeting.";
      };

      mtls = {
        enable = lib.mkEnableOption "mTLS authentication to the Jellyfin exporter";

        caFile = lib.mkOption {
          type = lib.types.path;
          default = internalPkiRootCaPath;
          description = "CA certificate used to verify the Jellyfin exporter.";
        };

        certificateFile = lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
          description = "Client certificate used to authenticate to the Jellyfin exporter.";
        };

        keyFile = lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
          description = "Client private key used to authenticate to the Jellyfin exporter.";
        };

        dependencyUnits = lib.mkOption {
          type = with lib.types; listOf str;
          default = [ ];
          description = "Units that must start before the mTLS credentials are available.";
        };
      };
    };

    outputs.transmission = {
      enable = lib.mkEnableOption "Transmission upload-limit application";

      rpcUrl = lib.mkOption {
        type = with lib.types; nullOr str;
        default = null;
        description = "Transmission RPC URL, or null to use the local NixOS service.";
      };

      requestTimeoutSeconds = lib.mkOption {
        type = positiveInt;
        default = 20;
        description = "Transmission RPC request timeout.";
      };

      headroomFraction = lib.mkOption {
        type = fraction;
        default = 0.95;
        description = "Fraction of the policy target assigned to Transmission.";
      };
    };

    outputs.qos = {
      enable = lib.mkEnableOption "host.qos runtime-rate application";

      profile = lib.mkOption {
        type = lib.types.str;
        default = "wan";
        description = "host.qos interface profile to update.";
      };

      limit = lib.mkOption {
        type = lib.types.str;
        description = "Egress limit within the selected host.qos profile.";
      };
    };

    metrics = {
      enable = lib.mkEnableOption "Prometheus node-exporter textfile metrics" // {
        default = true;
      };

      directory = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/prometheus-node-exporter-textfile";
        description = "Prometheus node-exporter textfile directory.";
      };

      fileName = lib.mkOption {
        type = lib.types.str;
        default = "adaptive-upload-policy.prom";
        description = "Prometheus textfile name.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.policy.minimumRateMbit <= cfg.policy.idleRateMbit;
        message = "services.adaptive-upload-policy.policy.minimumRateMbit must not exceed idleRateMbit";
      }
      {
        assertion = cfg.outputs.transmission.enable || cfg.outputs.qos.enable;
        message = "services.adaptive-upload-policy requires at least one enabled output";
      }
      {
        assertion = !mtls.enable || mtls.certificateFile != null;
        message = "services.adaptive-upload-policy requires an mTLS certificate file";
      }
      {
        assertion = !mtls.enable || mtls.keyFile != null;
        message = "services.adaptive-upload-policy requires an mTLS private key file";
      }
      {
        assertion = !cfg.outputs.qos.enable || qosProfile != null;
        message = "services.adaptive-upload-policy.outputs.qos.profile must reference a host.qos profile";
      }
      {
        assertion = !cfg.outputs.qos.enable || qosLimit != null;
        message = "services.adaptive-upload-policy.outputs.qos.limit must reference a host.qos limit";
      }
      {
        assertion = !cfg.outputs.qos.enable || qosLimit == null || qosLimit.direction == "egress";
        message = "services.adaptive-upload-policy can update only egress host.qos limits";
      }
      {
        assertion =
          !cfg.outputs.qos.enable || qosProfile == null || cfg.fallbackRateMbit <= qosProfile.linkRateMbit;
        message = "services.adaptive-upload-policy fallback rate must not exceed the QoS profile link rate";
      }
    ];

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
