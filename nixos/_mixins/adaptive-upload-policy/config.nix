{
  config,
  lib,
  options,
  ...
}:
let
  hasLanWanAccounting = options.host.observability.lanWan.wanEgressOverride or null != null;
  hasPkiClients = options.host.pki.clients or null != null;
  cfg = config.host.adaptiveUploadPolicy;
  pkiClientName = "jellyfin-upload-policy";
  qosDestination = if cfg == null then null else cfg.destinations.qos;
  qosProfileName = "adaptive_upload";
  stateDir = if cfg == null then null else dirOf cfg.stateFile;
in
{
  imports = [
    ./services/decider.nix
    ./services/qos.nix
    ./services/transmission.nix
  ];

  config = lib.mkIf (cfg != null) (
    lib.mkMerge [
      {
        host.qos.interfaces.${qosProfileName} = lib.mkIf (qosDestination != null) {
          device = qosDestination.interface;
          limits = {
            ${qosDestination.limit} = {
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

        users.groups.${cfg.group} = { };
        users.users.${cfg.user} = {
          description = "Adaptive upload policy controller";
          isSystemUser = true;
          group = cfg.group;
        };

        systemd.tmpfiles.rules = [
          "d ${stateDir} 0750 ${cfg.user} ${cfg.group} -"
          "z /var/lib/prometheus-node-exporter-textfile 0775 root ${cfg.group} - -"
        ];
      }
      (lib.optionalAttrs hasPkiClients {
        host.pki.clients.${pkiClientName} = {
          enable = cfg.source.jellyfin.host != null;
          category = "internal";
          secretPrefix = "prometheus/clients/${pkiClientName}";
          materializations.default = {
            owner = cfg.user;
            group = cfg.group;
            restartUnits = [ "adaptive-upload-policy.service" ];
          };
        };
      })
      (lib.optionalAttrs hasLanWanAccounting {
        host.observability.lanWan.wanEgressOverride =
          lib.mkIf (qosDestination != null && qosDestination.accountingName != null)
            {
              name = qosDestination.accountingName;
              udpDestinationPort = qosDestination.match.remotePort;
              tcClass = config.host.qos.classIds.${qosProfileName}.${qosDestination.limit};
            };
      })
    ]
  );
}
