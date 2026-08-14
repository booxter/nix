{
  config,
  lib,
  outputs,
}:
let
  localHost = config.networking.hostName;
  localServer = config.host.observability.loki.server or { enable = false; };
  otherConfigurations = removeAttrs outputs.nixosConfigurations [ localHost ];
  candidates =
    lib.mapAttrs (_: configuration: {
      inherit (configuration.config.host) realm;
      server = configuration.config.host.observability.loki.server or { enable = false; };
    }) otherConfigurations
    // {
      ${localHost} = {
        inherit (config.host) realm;
        server = localServer;
      };
    };
  realmServers =
    lib.mapAttrs
      (hostName: candidate: {
        inherit hostName;
        inherit (candidate.server) endpoint mtls writeUrl;
      })
      (
        lib.filterAttrs (
          _: candidate: candidate.realm == config.host.realm && candidate.server.enable
        ) candidates
      );
in
{
  inherit realmServers;
  server = if realmServers == { } then null else builtins.head (builtins.attrValues realmServers);
}
