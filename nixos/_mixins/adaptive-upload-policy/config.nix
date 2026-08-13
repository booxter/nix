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
  qosDestinationNames = builtins.attrNames cfg.destinations.qos;
  qosDestinationName =
    if builtins.length qosDestinationNames == 1 then builtins.head qosDestinationNames else null;
  qosDestination =
    if qosDestinationName == null then null else cfg.destinations.qos.${qosDestinationName};
  qosProfileName = "adaptive_upload";
  stateDir = dirOf cfg.stateFile;
in
{
  imports = [
    ./services/decider.nix
    ./services/qos.nix
    ./services/transmission.nix
  ];

  config = lib.mkMerge [
    {
      host.qos.interfaces = lib.mkIf cfg.enable (
        lib.mapAttrs' (
          name: destination:
          lib.nameValuePair qosProfileName {
            device = destination.interface;
            limits = {
              ${name} = {
                queue = destination.queue;
                match = {
                  inherit (destination.match) protocol;
                  destinationPort = destination.match.remotePort;
                };
              };
            }
            // lib.optionalAttrs (destination.maximumDownloadRateMbit != null) {
              "${name}-download" = {
                direction = "ingress";
                rateMbit = destination.maximumDownloadRateMbit;
                match = {
                  inherit (destination.match) protocol;
                  sourcePort = destination.match.remotePort;
                };
              };
            };
          }
        ) cfg.destinations.qos
      );

      users.groups.${cfg.group} = lib.mkIf cfg.enable { };
      users.users.${cfg.user} = lib.mkIf cfg.enable {
        description = "Adaptive upload policy controller";
        isSystemUser = true;
        group = cfg.group;
      };

      systemd.tmpfiles.rules = lib.optionals cfg.enable ([
        "d ${stateDir} 0750 ${cfg.user} ${cfg.group} -"
        "z /var/lib/prometheus-node-exporter-textfile 0775 root ${cfg.group} - -"
      ]);
    }
    (lib.optionalAttrs hasPkiClients {
      host.pki.clients.${pkiClientName} = {
        enable = cfg.enable && cfg.source.jellyfin.host != null;
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
        lib.mkIf (cfg.enable && qosDestination != null && qosDestination.accountingName != null)
          {
            name = qosDestination.accountingName;
            udpDestinationPort = qosDestination.match.remotePort;
            tcClass = config.host.qos.classIds.${qosProfileName}.${qosDestinationName};
          };
    })
  ];
}
