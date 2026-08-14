{
  config,
  lib,
  options,
  outputs ? {
    nixosConfigurations = { };
  },
  ...
}:
let
  hasLanWanAccounting = options.host.observability.lanWan.wanEgressOverride or null != null;
  hasPkiClients = options.host.pki.clients or null != null;
  model = import ./model.nix { inherit config outputs; };
  inherit (model)
    cfg
    group
    metricsDirectory
    pkiClientName
    qosDestination
    qosProfileName
    stateDir
    user
    ;
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
      }
      (lib.optionalAttrs hasPkiClients {
        host.pki.clients.${pkiClientName} = {
          enable = cfg.source.jellyfin.host != null;
          category = "internal";
          secretPrefix = "prometheus/clients/${pkiClientName}";
          materializations.default = {
            owner = user;
            inherit group;
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
