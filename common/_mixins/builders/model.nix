{
  config,
  hostSpec,
  lib,
  outputs,
}:
let
  configurations = outputs.nixosConfigurations // outputs.darwinConfigurations;
  otherConfigurations = builtins.removeAttrs configurations [ hostSpec.name ];
  toBuilder =
    name: configuration:
    let
      host = configuration.config.host;
    in
    {
      inherit name;
      inherit (host) realm;
      inherit (host.nix.builder)
        enable
        hostName
        maxJobs
        speedFactor
        supportedFeatures
        ;
      systems = [ host.platform ];
    };
  candidates = lib.mapAttrsToList toBuilder otherConfigurations;
  realmBuilders = builtins.filter (
    builder: builder.enable && builder.realm == config.host.realm
  ) candidates;
  byName = a: b: a.name < b.name;
  builderPool = map (
    builder:
    removeAttrs builder [
      "enable"
      "realm"
    ]
  ) (lib.sort byName realmBuilders);
in
{
  inherit builderPool;
}
