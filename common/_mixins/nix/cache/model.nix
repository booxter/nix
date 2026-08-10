{
  config,
  hostSpec,
  lib,
  outputs,
}:
let
  localHost = hostSpec.name;
  localCandidate = {
    inherit (config.host) realm;
    contributions = config.host.nix.cacheContributions;
  };
  otherConfigurations = builtins.removeAttrs (
    outputs.nixosConfigurations // outputs.darwinConfigurations
  ) [ localHost ];
  candidates =
    lib.mapAttrs (_: configuration: {
      inherit (configuration.config.host) realm;
      contributions = configuration.config.host.nix.cacheContributions;
    }) otherConfigurations
    // {
      ${localHost} = localCandidate;
    };
  entries = builtins.concatMap (
    hostName:
    let
      candidate = candidates.${hostName};
    in
    lib.mapAttrsToList
      (name: cache: {
        inherit name;
        value = removeAttrs cache [
          "enable"
          "scope"
        ];
      })
      (
        lib.filterAttrs (
          _: cache:
          cache.enable
          && (
            (cache.scope == "host" && hostName == localHost)
            || (cache.scope == "realm" && candidate.realm == config.host.realm)
          )
        ) candidate.contributions
      )
  ) (builtins.attrNames candidates);
  names = map (entry: entry.name) entries;
  duplicateNames = lib.unique (
    lib.filter (name: builtins.length (lib.filter (candidate: candidate == name) names) > 1) names
  );
in
{
  inherit duplicateNames;
  caches = builtins.listToAttrs entries;
}
