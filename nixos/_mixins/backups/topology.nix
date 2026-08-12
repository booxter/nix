{
  config,
  lib,
  outputs,
  ...
}:
let
  hostName = config.networking.hostName;
  cfg = config.host.backups;
  model = import ./topology/model.nix {
    inherit
      config
      lib
      outputs
      ;
  };
  clientRequests = model.requestsByClient.${hostName} or [ ];
  serverRequests = model.requestsByServer.${hostName} or [ ];
  cloudUploadRateMbit = config.host.site.policies.backups.maxUploadMbit;
  cloudQosEnabled = cfg.server.enable && cfg.server.offsite.enable;
  clients = builtins.listToAttrs (
    map (request: {
      name = request.clientName;
      value = {
        inherit (request) publicKey storageName;
        cloud = lib.optionalAttrs request.offsite.enable {
          inherit (request.offsite)
            backend
            prefix
            repository
            storageProvider
            ;
          enable = true;
          sourcePasswordFile =
            config.sops.secrets."backup/restic/${request.clientName}/cloud/localPassword".path;
          passwordFile = config.sops.secrets."backup/restic/${request.clientName}/cloud/password".path;
        };
      };
    }) serverRequests
  );
  localClients = map (request: request.clientName) (
    builtins.filter (request: request.transport == "local") serverRequests
  );
  localClient = if localClients == [ ] then null else builtins.head localClients;
in
{
  assertions = import ./topology/assertions.nix {
    inherit
      cloudQosEnabled
      config
      hostName
      lib
      localClients
      model
      ;
  };

  host.backups.resolvedDestinations = builtins.listToAttrs (
    map (request: {
      name = request.destinationName;
      value = {
        inherit (request)
          check
          ingestUser
          publicKey
          repositoryPath
          retention
          server
          storageName
          timerConfig
          transport
          user
          ;
      };
    }) clientRequests
  );

  host.backups.server = lib.mkIf cfg.server.enable {
    inherit clients localClient;
    cloud = {
      bucketName = cfg.server.offsite.bucketName;
      requiredUnits = lib.mkIf cloudQosEnabled [ "qos-wan.service" ];
    };
  };

  host.qos.interfaces.wan = lib.mkIf cloudQosEnabled {
    device = config.host.network.primaryInterface;
    limits.cloud-backup = {
      rateMbit = cloudUploadRateMbit;
      match.users = cfg.server.generated.offloadUsers;
    };
  };
}
