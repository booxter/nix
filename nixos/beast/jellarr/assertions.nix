{
  facts,
  lib,
  ...
}:
let
  model = import ./model.nix { inherit facts lib; };
  registry = import ./plugin-registry.nix;
  unknownPlugins = builtins.filter (
    plugin: !builtins.hasAttr plugin registry.plugins
  ) model.requiredPlugins;
in
{
  assertions = [
    {
      assertion = unknownPlugins == [ ];
      message = "Jellarr library profiles require unknown plugins: ${lib.concatStringsSep ", " unknownPlugins}";
    }
  ];
}
