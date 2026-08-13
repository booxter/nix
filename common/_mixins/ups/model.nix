{
  config,
  lib,
  outputs,
}:
let
  hostName = config.networking.hostName;
  hostView = hostConfig: {
    inherit (hostConfig.host) isLinux realm;
    name = hostConfig.networking.hostName;
    ups = {
      inherit (hostConfig.host.ups) credentialMode;
      clientServer = hostConfig.host.ups.client.server;
      server = {
        inherit (hostConfig.host.ups.server)
          description
          enable
          name
          ;
      };
    };
  };
  configurations = outputs.nixosConfigurations // outputs.darwinConfigurations;
  otherConfigurations = removeAttrs configurations [ hostName ];
  hosts = lib.mapAttrs (_: configuration: hostView configuration.config) otherConfigurations // {
    ${hostName} = hostView config;
  };
  servers = lib.filterAttrs (_: host: host.ups.server.enable) hosts;
in
{
  inherit hosts servers;
}
