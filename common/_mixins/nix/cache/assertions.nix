{
  config,
  hostSpec,
  lib,
  outputs,
  ...
}:
let
  model = import ./model.nix {
    inherit
      config
      hostSpec
      lib
      outputs
      ;
  };
  contributions = builtins.attrValues config.host.nix.cacheContributions;
  validReachability =
    cache:
    if cache.reachability.kind == "internal" then
      cache.reachability.network != null
    else
      cache.reachability.network == null;
in
{
  assertions = [
    {
      assertion = model.duplicateNames == [ ];
      message = "Nix cache contributions collide in realm '${config.host.realm}': ${lib.concatStringsSep ", " model.duplicateNames}";
    }
    {
      assertion = lib.all validReachability contributions;
      message = "Internal Nix caches must name their required network; public caches must not name one";
    }
  ];
}
