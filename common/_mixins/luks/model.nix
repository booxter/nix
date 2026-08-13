{
  config,
  lib,
  outputs,
}:
let
  localHost = config.networking.hostName;
  localCandidate = {
    hostName = config.networking.hostName;
    inherit (config.host) realm;
    inherit (config.host.luks.remoteUnlock) enable publicKey;
  };
  otherConfigurations = builtins.removeAttrs (
    outputs.nixosConfigurations // outputs.darwinConfigurations
  ) [ localHost ];
  candidates =
    lib.mapAttrs (_: configuration: {
      hostName = configuration.config.networking.hostName;
      inherit (configuration.config.host) realm;
      inherit (configuration.config.host.luks.remoteUnlock) enable publicKey;
    }) otherConfigurations
    // {
      ${localHost} = localCandidate;
    };
  realmServers = lib.filterAttrs (
    _: candidate: candidate.enable && candidate.realm == config.host.realm
  ) candidates;
in
{
  servers = lib.mapAttrs' (
    _: server:
    let
      name = "${server.hostName}-luks";
    in
    lib.nameValuePair name {
      inherit (server) hostName;
      inherit (server) publicKey;
    }
  ) realmServers;
}
