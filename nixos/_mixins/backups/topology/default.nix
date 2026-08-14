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

  qosEnabled =
    backups.server.enable && backups.server.offsite.enable && backups.server.offsite.qos.enable;
in
{
  config = lib.mkMerge [
    {
      host.backups.internal.destination = client.destination;

      host.backups.server = lib.mkIf backups.server.enable {
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
