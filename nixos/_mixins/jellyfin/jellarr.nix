{
  config,
  lib,
  outputs,
  ...
}:
let
  model = import ./model.nix { inherit config outputs; };
in
{
  config.host.jellyfinDeclarativeConfig = lib.mkMerge (
    map (contribution: contribution.config) model.targetedContributions
  );
}
