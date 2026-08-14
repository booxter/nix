{
  config,
  lib,
  outputs,
}:
let
  hostName = config.networking.hostName;
  hostView = hostConfig: {
    inherit (hostConfig.host) realm;
    inherit (hostConfig.nixpkgs.hostPlatform) isLinux;
    name = hostConfig.networking.hostName;
    ups = {
      inherit (hostConfig.host.ups) credentialMode;
      clientServer = hostConfig.host.ups.client.server;
      server = hostConfig.host.ups.server;
    };
  };
  configurations = outputs.nixosConfigurations // outputs.darwinConfigurations;
  otherConfigurations = removeAttrs configurations [ hostName ];
  hosts = lib.mapAttrs (_: configuration: hostView configuration.config) otherConfigurations // {
    ${hostName} = hostView config;
  };
  servers = lib.filterAttrs (_: host: host.ups.server != null) hosts;
in
{
  inherit hosts servers;
}
