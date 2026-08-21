{
  backupConfigurations ? outputs.nixosConfigurations,
  config,
  lib,
  outputs,
  ...
}:
let
  backups = config.host.backups;
  topology = import ./model.nix {
    inherit backupConfigurations config lib;
  };
  inherit (topology) client server;

  qosEnabled = backups.server != null && backups.server.offsite != null && backups.server.offsite.qos;
in
{
  config = lib.mkMerge [
    {
      _module.args.backupTopology = topology;

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
