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
in
{
  config = lib.mkMerge [
    {
      _module.args.backupTopology = topology;
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
