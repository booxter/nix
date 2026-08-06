{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.services.adaptive-upload-policy;
  internalPkiRootCaPath = import ../../../lib/home-internal-pki-root-ca.nix;
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
  mtlsSecretName = "internal-https-client-${mtls.clientName}";
  clientCertificate = config.sops.secrets."${mtlsSecretName}-crt".path;
  clientKey = config.sops.secrets."${mtlsSecretName}-key".path;
  transmissionRpcUrl =
    if cfg.outputs.transmission.rpcUrl != null then
      cfg.outputs.transmission.rpcUrl
    else
      "http://127.0.0.1:${toString config.services.transmission.settings.rpc-port}/transmission/rpc";
  qosProfile = config.host.qos.interfaces.${cfg.outputs.qos.profile} or null;
  qosLimit = if qosProfile != null then qosProfile.limits.${cfg.outputs.qos.limit} or null else null;
  qosService = "qos-${cfg.outputs.qos.profile}.service";
  deciderCommand = utils.escapeSystemdExecArgs (
    [
      controller
      "decide"
      "--exporter-url"
      cfg.source.jellyfin.exporterUrl
      "--state-file"
      cfg.stateFile
      "--interval-seconds"
      (toString cfg.intervalSeconds)
      "--request-timeout-seconds"
      (toString cfg.source.jellyfin.requestTimeoutSeconds)
      "--no-streams-mbit"
      (toString cfg.policy.idleRateMbit)
      "--minimum-streams-mbit"
      (toString cfg.policy.minimumRateMbit)
      "--fallback-mbit"
      (toString cfg.fallbackRateMbit)
      "--stream-bitrate-headroom-fraction"
      (toString cfg.policy.bitrateHeadroomFraction)
      "--relaxation-hold-seconds"
      (toString cfg.policy.relaxationHoldSeconds)
      "--transmission-headroom-fraction"
      (toString cfg.outputs.transmission.headroomFraction)
    ]
    ++ lib.optionals cfg.metrics.enable [
      "--metrics-file"
      metricsFile
    ]
    ++ [ "--media-types" ]
    ++ cfg.source.jellyfin.mediaTypes
    ++ lib.optionals mtls.enable [
      "--ca-file"
      (toString mtls.caFile)
      "--client-cert-file"
      clientCertificate
      "--client-key-file"
      clientKey
    ]
  );
  transmissionCommand = utils.escapeSystemdExecArgs [
    controller
    "apply-transmission"
    "--rpc-url"
    transmissionRpcUrl
    "--state-file"
    cfg.stateFile
    "--interval-seconds"
    (toString cfg.intervalSeconds)
    "--request-timeout-seconds"
    (toString cfg.outputs.transmission.requestTimeoutSeconds)
    "--fallback-mbit"
    (toString cfg.fallbackRateMbit)
    "--transmission-headroom-fraction"
    (toString cfg.outputs.transmission.headroomFraction)
    "--max-state-age-seconds"
    (toString maxStateAgeSeconds)
  ];
  qosCommand = utils.escapeSystemdExecArgs [
    controller
    "apply-tc"
    "--state-file"
    cfg.stateFile
    "--interval-seconds"
    (toString cfg.intervalSeconds)
    "--fallback-mbit"
    (toString cfg.fallbackRateMbit)
    "--transmission-headroom-fraction"
    (toString cfg.outputs.transmission.headroomFraction)
    "--max-state-age-seconds"
    (toString maxStateAgeSeconds)
    "--qosctl"
    (lib.getExe config.host.qos.package)
    "--qos-config"
    config.host.qos.configFiles.${cfg.outputs.qos.profile}
    "--qos-limit"
    cfg.outputs.qos.limit
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

        clientName = lib.mkOption {
          type = lib.types.str;
          default = "adaptive-upload-policy";
          description = "Internal HTTPS client identity name.";
        };

        secretPrefix = lib.mkOption {
          type = lib.types.str;
          default = "internal_https/clients/${mtls.clientName}";
          description = "SOPS prefix containing the mTLS client certificate and key.";
        };

        caFile = lib.mkOption {
          type = lib.types.path;
          default = internalPkiRootCaPath;
          description = "CA certificate used to verify the Jellyfin exporter.";
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

    host.internalHttps.mtlsClients.${mtls.clientName} = lib.mkIf mtls.enable {
      enable = true;
      inherit (mtls) secretPrefix;
      owner = cfg.user;
      group = cfg.group;
      mode = "0400";
      restartUnits = [ deciderUnit ];
    };

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0750 ${cfg.user} ${cfg.group} -"
    ]
    ++ lib.optional cfg.metrics.enable "z ${cfg.metrics.directory} 0775 root ${cfg.group} - -";

    systemd.services = {
      adaptive-upload-policy = {
        description = "Decide adaptive upload policy from Jellyfin playback";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ] ++ lib.optional mtls.enable "sops-install-secrets.service";
        after = [ "network-online.target" ] ++ lib.optional mtls.enable "sops-install-secrets.service";
        serviceConfig = commonServiceConfig // {
          ExecStart = deciderCommand;
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
          ExecStart = transmissionCommand;
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
          ExecStart = qosCommand;
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
