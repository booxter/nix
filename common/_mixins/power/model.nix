{
  config,
  lib,
  outputs,
}:
let
  hostName = config.networking.hostName;
  hostView = hostConfig: {
    before = hostConfig.host.power.shutdown.before;
    ups = {
      clientServer = hostConfig.host.ups.client.server;
      server = {
        inherit (hostConfig.host.ups.server)
          baseDelaySeconds
          enable
          separationSeconds
          ;
      };
    };
  };
  configurations = outputs.nixosConfigurations // outputs.darwinConfigurations;
  otherConfigurations = removeAttrs configurations [ hostName ];
  hosts = lib.mapAttrs (_: configuration: hostView configuration.config) otherConfigurations // {
    ${hostName} = hostView config;
  };
in
(import ./lib.nix { inherit lib; }).build hosts
