{
  config,
  lib,
  outputs,
}:
let
  localHost = config.networking.hostName;
  localCandidate = {
    hostName = localHost;
    inherit (config.host) realm;
    server = config.host.attic.server;
  };
  otherConfigurations = builtins.removeAttrs (
    outputs.nixosConfigurations // outputs.darwinConfigurations
  ) [ localHost ];
  otherCandidates = lib.mapAttrs (_: configuration: {
    hostName = configuration.config.networking.hostName;
    inherit (configuration.config.host) realm;
    server = configuration.config.host.attic.server;
  }) otherConfigurations;
  candidates = otherCandidates // {
    ${localHost} = localCandidate;
  };
  realmCandidates = lib.filterAttrs (
    _: candidate: candidate.realm == config.host.realm && candidate.server.enable
  ) candidates;
  realmServers = lib.mapAttrs (_: candidate: {
    inherit (candidate) hostName;
    inherit (candidate.server)
      cacheName
      endpoint
      trustedPublicKey
      ;
    substituter = "${candidate.server.endpoint}/${candidate.server.cacheName}";
  }) realmCandidates;
in
{
  inherit realmServers;
}
