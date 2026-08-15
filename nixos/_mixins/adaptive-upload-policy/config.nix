{
  config,
  lib,
  options,
  outputs ? {
    nixosConfigurations = { };
  },
  pkgs,
  utils,
  ...
}:
let
  hasLanWanAccounting = options.host.observability.lanWan.wanEgressOverride or null != null;
  hasPkiClients = options.host.pki.clients or null != null;
  model = import ./model.nix { inherit config outputs; };
  inherit (model)
    cfg
    exporterUrl
    group
    intervalSeconds
    jellyfin
    maxStateAgeSeconds
    metricsDirectory
    metricsFile
    mtls
    pkiClientName
    policy
    qosDestination
    qosOutput
    qosProfileName
    qosService
    stateDir
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
      exporter_url = exporterUrl;
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
      if transmissionOutput == null then
        null
      else
        {
          rpc_url = transmissionOutput.rpcUrl;
          request_timeout_seconds = transmissionOutput.requestTimeoutSeconds;
          headroom_fraction = transmissionOutput.headroomPercent / 100.0;
        };
    qos =
      if qosOutput == null then
        null
      else
        {
          executable = lib.getExe config.host.qos.package;
          config_file = config.host.qos.configFiles.${qosOutput.profile};
          limit = qosOutput.limit;
        };
  };
  command =
    action:
    utils.escapeSystemdExecArgs [
      (lib.getExe package)
      action
      "--config"
      controllerConfig
    ];
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
in
{
  config = lib.mkIf (cfg != null) (
    lib.mkMerge [
      {
        host.qos.interfaces.${qosProfileName} = lib.mkIf (qosDestination != null) {
          device = qosDestination.interface;
          limits = {
            ${qosDestination.limit} = {
              rateMbit = lib.mkDefault cfg.fallbackRateMbit;
              queue = qosDestination.queue;
              match = {
                inherit (qosDestination.match) protocol;
                destinationPort = qosDestination.match.remotePort;
              };
            };
          }
          // lib.optionalAttrs (qosDestination.maximumDownloadRateMbit != null) {
            "${qosDestination.limit}-download" = {
              direction = "ingress";
              rateMbit = qosDestination.maximumDownloadRateMbit;
              match = {
                inherit (qosDestination.match) protocol;
                sourcePort = qosDestination.match.remotePort;
              };
            };
          };
        };

        users.groups.${group} = { };
        users.users.${user} = {
          description = "Adaptive upload policy controller";
          isSystemUser = true;
          inherit group;
        };

        systemd.tmpfiles.rules = [
          "d ${stateDir} 0750 ${user} ${group} -"
          "z ${metricsDirectory} 0775 root ${group} - -"
        ];

        systemd.services = {
          adaptive-upload-policy = {
            description = "Decide adaptive upload policy from Jellyfin playback";
            wantedBy = [ "multi-user.target" ];
            wants = [ "network-online.target" ] ++ lib.optionals (mtls != null) mtls.dependencyUnits;
            after = [ "network-online.target" ] ++ lib.optionals (mtls != null) mtls.dependencyUnits;
            serviceConfig = commonServiceConfig // {
              ExecStart = command "decide";
              ReadWritePaths = [
                stateDir
                metricsDirectory
              ];
              RestrictAddressFamilies = [
                "AF_UNIX"
                "AF_INET"
                "AF_INET6"
              ];
            };
          };

          adaptive-upload-policy-qos = lib.mkIf (qosOutput != null) {
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

          adaptive-upload-policy-transmission = lib.mkIf (transmissionOutput != null) {
            description = "Apply adaptive upload policy to Transmission";
            wantedBy = [ "multi-user.target" ];
            wants = [
              "network-online.target"
              deciderUnit
            ]
            ++ lib.optional transmissionOutput.local "transmission.service";
            after = [
              "network-online.target"
              deciderUnit
            ]
            ++ lib.optional transmissionOutput.local "transmission.service";
            serviceConfig = commonServiceConfig // {
              ExecStart = command "apply-transmission";
              RestrictAddressFamilies = [
                "AF_UNIX"
                "AF_INET"
                "AF_INET6"
              ];
            };
          };
        };
      }
      (lib.mkIf (hasPkiClients && cfg.source.jellyfin.host != null) {
        host.pki.clients.${pkiClientName} = {
          category = "internal";
          secretPrefix = "prometheus/clients/${pkiClientName}";
          materializations.default = {
            owner = user;
            inherit group;
            restartUnits = [ deciderUnit ];
          };
        };
      })
      (lib.optionalAttrs hasLanWanAccounting {
        host.observability.lanWan.wanEgressOverride =
          lib.mkIf (qosDestination != null && qosDestination.accountingName != null)
            {
              interface = qosDestination.interface;
              name = qosDestination.accountingName;
              udpDestinationPort = qosDestination.match.remotePort;
              tcClass = config.host.qos.classIds.${qosProfileName}.${qosDestination.limit};
            };
      })
    ]
  );
}
