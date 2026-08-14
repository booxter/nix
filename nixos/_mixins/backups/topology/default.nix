{
  config,
  lib,
  outputs,
  ...
}:
let
  backups = config.host.backups;
  hostName = config.networking.hostName;
  configurations = outputs.nixosConfigurations // {
    ${hostName}.config = config;
  };

  client = import ./client.nix {
    inherit
      backups
      configurations
      hostName
      lib
      ;
  };
  server = import ./server.nix {
    inherit
      backups
      config
      configurations
      hostName
      lib
      ;
  };

  qosEnabled = backups.server != null && backups.server.offsite != null && backups.server.offsite.qos;
in
{
  config = lib.mkMerge [
    {
      host.backups.internal.destination = client.destination;

      host.backups.internal.server = {
        inherit (server) localClient repositories;
      };

      host.qos.interfaces.wan = lib.mkIf qosEnabled {
        device = config.host.network.primaryInterface;
        limits.cloud-backup = {
          rateMbit = config.host.site.policies.backups.maxUploadMbit;
          match.users = server.offloadUsers;
        };
      };
    }

    (import ./assertions.nix {
      inherit
        backups
        client
        lib
        server
        ;
    })
  ];
}
