{
  config,
  lib,
  outputs,
}:
let
  backups = config.host.backups;
  hostName = config.networking.hostName;
  configurations = outputs.nixosConfigurations // {
    ${hostName}.config = config;
  };
in
{
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
}
